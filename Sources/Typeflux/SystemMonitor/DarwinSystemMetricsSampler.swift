import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

/// Reads the counters the monitor turns into rates. Calls block briefly and run
/// off the main thread.
protocol SystemMetricsSampling: Sendable {
    func machineInfo() -> SystemMachineInfo
    /// Processes are the expensive part (a few hundred system calls): only read them
    /// when a process list is on screen. Slow details are read when `slow` is set.
    func sample(processes: Bool, slow: Bool) -> SystemRawSample
}

/// Public Darwin interfaces only, so nothing needs an extra permission.
final class DarwinSystemMetricsSampler: SystemMetricsSampling, @unchecked Sendable {
    private let host: mach_port_t
    private let timebase: (numer: UInt64, denom: UInt64)
    private let pageSize: UInt64

    init() {
        host = mach_host_self()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(max(1, info.numer)), UInt64(max(1, info.denom)))
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : UInt64(getpagesize())
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func machineInfo() -> SystemMachineInfo {
        let chip = Self.sysctlString("machdep.cpu.brand_string") ?? Self.sysctlString("hw.model") ?? "Mac"
        return SystemMachineInfo(
            chip: chip.trimmingCharacters(in: .whitespaces),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: Self.sysctl("hw.perflevel0.logicalcpu", Int32.self).map(Int.init),
            efficiencyCores: Self.sysctl("hw.perflevel1.logicalcpu", Int32.self).map(Int.init),
            memory: ProcessInfo.processInfo.physicalMemory
        )
    }

    func sample(processes: Bool, slow: Bool) -> SystemRawSample {
        let disk = diskCounters()
        let network = networkCounters()
        let list = processes ? processCounters() : nil
        return SystemRawSample(
            time: ProcessInfo.processInfo.systemUptime,
            cores: cores(),
            memory: memory(),
            loadAverage: loadAverage(),
            diskRead: disk.read,
            diskWritten: disk.written,
            networkIn: network.input,
            networkOut: network.output,
            processes: list?.processes,
            processTotal: list?.total,
            slow: slow ? slowInfo() : nil,
            uptime: ProcessInfo.processInfo.systemUptime,
            thermal: ProcessInfo.processInfo.thermalState
        )
    }

    // MARK: CPU and memory

    func cores() -> [SystemCPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * stride + Int(state)])) }
            return SystemCPUTicks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                                  idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    func memory() -> SystemMemoryCounters {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        let pressure = Self.sysctl("kern.memorystatus_vm_pressure_level", Int32.self)
            .flatMap { SystemMonitorMemoryPressure(rawValue: Int($0)) } ?? .normal
        let available = Self.sysctl("kern.memorystatus_level", Int32.self).map(Double.init)
        let swap = Self.sysctl("vm.swapusage", xsw_usage.self)?.xsu_used ?? 0
        guard result == KERN_SUCCESS else {
            return SystemMemoryCounters(total: total, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: swap,
                                        pressure: pressure, availablePercent: available)
        }
        let page = pageSize
        let purgeable = UInt64(stats.purgeable_count)
        let anonymous = UInt64(stats.internal_page_count)
        return SystemMemoryCounters(
            total: total,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap,
            pressure: pressure,
            availablePercent: available
        )
    }

    func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    // MARK: Disk and network

    /// Bytes read and written by every block storage driver since boot.
    func diskCounters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let property = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0),
               let stats = property.takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return (read, written)
    }

    /// Bytes in and out of the physical interfaces since boot, as 64-bit counters.
    func networkCounters() -> (input: UInt64, output: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard Darwin.sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard Darwin.sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var input: UInt64 = 0, output: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if Self.countsTraffic(name: Self.interfaceName(index: info.ifm_index), flags: info.ifm_flags) {
                        input &+= info.ifm_data.ifi_ibytes
                        output &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += size
            }
        }
        return (input, output)
    }

    /// Ethernet, Wi-Fi and cellular only: tunnels and bridges carry the same bytes again.
    static func countsTraffic(name: String?, flags: Int32) -> Bool {
        guard let name, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { return false }
        return name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    private static func interfaceName(index: UInt16) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    // MARK: Processes

    func processCounters() -> (processes: [SystemProcessCounters], total: Int) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], 0) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let listed = pids.prefix(max(0, min(Int(found), pids.count)))
        return (listed.compactMap(process), listed.count)
    }

    /// A process's counters; nil when it cannot be read (it ended, or belongs to
    /// another user and the system will not say).
    func process(_ pid: pid_t) -> SystemProcessCounters? {
        guard pid >= 0 else { return nil }
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { return nil }
        var name = withUnsafeBytes(of: short.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // The short name stops at 16 bytes; the long one is kept elsewhere.
        if name.utf8.count >= Int(MAXCOMLEN) - 1 {
            var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { name = String(cString: buffer) }
        }
        var usage = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        if read == 0 {
            return SystemProcessCounters(pid: pid, name: name, uid: short.pbsi_uid,
                                         cpuTime: nanoseconds(usage.ri_user_time &+ usage.ri_system_time),
                                         memory: usage.ri_phys_footprint, diskRead: usage.ri_diskio_bytesread,
                                         diskWritten: usage.ri_diskio_byteswritten)
        }
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }
        return SystemProcessCounters(pid: pid, name: name, uid: short.pbsi_uid,
                                     cpuTime: nanoseconds(task.pti_total_user &+ task.pti_total_system),
                                     memory: task.pti_resident_size, diskRead: nil, diskWritten: nil)
    }

    /// CPU times come in Mach absolute time units, which are not nanoseconds on Apple silicon.
    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        timebase.numer == timebase.denom ? ticks : ticks / timebase.denom * timebase.numer
            + ticks % timebase.denom * timebase.numer / timebase.denom
    }

    // MARK: Slow details

    func slowInfo() -> SystemSlowInfo {
        SystemSlowInfo(volumes: volumes(), interface: primaryInterface(), battery: battery())
    }

    func volumes() -> [SystemVolume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> SystemVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false, values.volumeIsLocal != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
                ?? values.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? 0
            return SystemVolume(name: values.volumeLocalizedName ?? url.lastPathComponent, path: url.path,
                                total: UInt64(total), available: min(available, UInt64(total)), isRoot: url.path == "/")
        }
        return volumes.sorted { lhs, rhs in lhs.isRoot != rhs.isRoot ? lhs.isRoot : lhs.name < rhs.name }
    }

    func primaryInterface() -> SystemNetworkInterface? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String else { return nil }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let display = interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == name }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name
        return SystemNetworkInterface(name: name, displayName: display, address: Self.ipv4Address(of: name))
    }

    static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    func battery() -> SystemBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return SystemBattery(percent: min(100, current * 100 / maximum),
                                 charging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    // MARK: sysctl

    static func sysctl<T>(_ name: String, _: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.load(as: T.self)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
