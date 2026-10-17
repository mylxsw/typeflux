import Foundation

/// Turns what the Mac says into the rows and cards `sys` shows, in the interface language.
extension SystemInfoSnapshot {
    static func make(_ facts: SystemInfoFacts, now: Date = Date()) -> SystemInfoSnapshot {
        let fields = processor(facts) + memory(facts) + storage(facts) + displays(facts) + network(facts)
            + battery(facts) + system(facts, now: now)
        let title = facts.productName ?? facts.modelIdentifier
        let subtitle = [facts.productName == nil ? nil : facts.modelIdentifier, facts.chip]
            .compactMap(\.self).joined(separator: " · ")
        return SystemInfoSnapshot(title: title, subtitle: subtitle, system: systemLine(facts),
                                  cards: cards(facts, now: now), fields: fields, hasBattery: facts.battery != nil)
    }

    /// "macOS Sequoia 15.1 (24B83)".
    static func systemLine(_ facts: SystemInfoFacts) -> String {
        macOSName(facts.osVersion) + " " + facts.osVersion + (facts.osBuild.map { " (" + $0 + ")" } ?? "")
    }

    /// The release's name for the major version, or plain "macOS" for one it does not know.
    static func macOSName(_ version: String) -> String {
        let names = ["13": "Ventura", "14": "Sonoma", "15": "Sequoia", "26": "Tahoe"]
        let major = version.split(separator: ".").first.map(String.init) ?? ""
        return names[major].map { "macOS " + $0 } ?? "macOS"
    }

    // MARK: Overview

    static func cards(_ facts: SystemInfoFacts, now: Date) -> [SystemInfoCard] {
        var cards = [
            SystemInfoCard(section: .processor, value: facts.chip, detail: coresLine(facts)),
            SystemInfoCard(section: .memory, value: SystemMonitorFormat.memory(facts.memory),
                           detail: facts.isAppleSilicon ? L("system.info.memory.unified") : "")
        ]
        if let root = facts.volumes.first(where: \.isRoot) ?? facts.volumes.first {
            let others = facts.volumes.count - 1
            let detail = [L("system.info.available", SystemMonitorFormat.storage(root.available)),
                          others > 0 ? L("system.info.volumes.more", others) : nil]
                .compactMap(\.self).joined(separator: " · ")
            cards.append(SystemInfoCard(section: .storage, value: SystemMonitorFormat.storage(root.total),
                                        detail: detail, fraction: usedFraction(root)))
        }
        if let display = facts.displays.first(where: \.isBuiltIn) ?? facts.displays.first {
            let detail = [display.refreshRate.map { L("system.info.display.hz", $0) },
                          facts.displays.count > 1 ? L("system.info.displays.more", facts.displays.count - 1) : nil]
                .compactMap(\.self).joined(separator: " · ")
            cards.append(SystemInfoCard(section: .display,
                                        value: pixels(display.pixelWidth, display.pixelHeight),
                                        detail: detail))
        }
        if let interface = primaryInterface(facts) {
            cards.append(SystemInfoCard(section: .network, value: interface.displayName,
                                        detail: interface.ipv4.first ?? interface.ipv6.first ?? ""))
        } else {
            cards.append(SystemInfoCard(section: .network, value: L("system.info.network.offline"), detail: ""))
        }
        if let battery = facts.battery {
            cards.append(SystemInfoCard(section: .battery, value: L("system.info.percent", battery.percent),
                                        detail: batteryState(battery), fraction: Double(battery.percent) / 100))
        } else {
            let uptime = facts.bootTime.map {
                L("system.monitor.uptime", SystemMonitorFormat.uptime(now.timeIntervalSince($0)))
            }
            let release = macOSName(facts.osVersion).replacingOccurrences(of: "macOS", with: "")
                .trimmingCharacters(in: .whitespaces)
            cards.append(SystemInfoCard(section: .system, value: "macOS " + facts.osVersion,
                                        detail: [release, uptime ?? ""].filter { !$0.isEmpty }
                                            .joined(separator: " · ")))
        }
        return cards
    }

    /// "10-core CPU · 10-core GPU".
    static func coresLine(_ facts: SystemInfoFacts) -> String {
        [L("system.info.cpu.cores.short", facts.cores), facts.gpuCores.map { L("system.info.gpu.cores", $0) }]
            .compactMap(\.self).joined(separator: " · ")
    }

    static func usedFraction(_ volume: SystemInfoFacts.Volume) -> Double {
        volume.total == 0 ? 0 : Double(volume.total - min(volume.available, volume.total)) / Double(volume.total)
    }

    static func primaryInterface(_ facts: SystemInfoFacts) -> SystemInfoFacts.Interface? {
        facts.interfaces.first { $0.name == facts.primaryInterface } ?? facts.interfaces.first
    }

    static func batteryState(_ battery: SystemInfoFacts.Battery) -> String {
        if battery.charging {
            return L("system.info.battery.charging")
        }
        return L(battery.onPower ? "system.info.battery.onPower" : "system.info.battery.onBattery")
    }

    /// "3024 × 1964": sizes are written without grouping separators.
    static func pixels(_ width: Int, _ height: Int) -> String {
        L("system.info.display.pixels", String(width), String(height))
    }

    static func onOff(_ value: Bool) -> String {
        L(value ? "system.info.on" : "system.info.off")
    }

    // MARK: Sections

    static func processor(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        let group = L("system.info.group.chip")
        let split: String? = if let performance = facts.performanceCores, let efficiency = facts.efficiencyCores {
            L("system.info.cpu.split", performance, efficiency)
        } else {
            nil
        }
        var fields = [
            SystemInfoField(id: "processor.chip", section: .processor, group: group, label: L("system.info.chip"),
                            value: facts.chip, keywords: ["chip", "cpu", "soc", "处理器", "芯片"]),
            SystemInfoField(id: "processor.cores", section: .processor, group: group, label: L("system.info.cpu.cores"),
                            value: L("system.info.cores", facts.cores), detail: split,
                            keywords: ["cores", "核心", "核数", "performance", "efficiency"]),
            SystemInfoField(id: "processor.architecture", section: .processor, group: group,
                            label: L("system.info.architecture"), value: facts.architecture,
                            detail: L(facts.isAppleSilicon ? "system.info.appleSilicon" : "system.info.intel"),
                            keywords: ["arch", "arm", "intel", "x86", "架构"])
        ]
        guard facts.isAppleSilicon else { return fields }
        let compatibility = L("system.info.group.compatibility")
        fields.append(SystemInfoField(
            id: "processor.rosetta", section: .processor, group: compatibility, label: "Rosetta 2",
            value: L(facts.rosettaInstalled ? "system.info.installed" : "system.info.notInstalled"),
            badge: facts.rosettaInstalled ? .good : .off, keywords: ["rosetta", "intel", "x86", "转译"]
        ))
        fields.append(SystemInfoField(
            id: "processor.translated", section: .processor, group: compatibility, label: L("system.info.process"),
            value: L(facts.translated ? "system.info.process.translated" : "system.info.process.native"),
            keywords: ["translated", "native", "转译", "原生"]
        ))
        return fields
    }

    static func memory(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        [SystemInfoField(id: "memory.capacity", section: .memory, group: L("system.info.section.memory"),
                         label: L("system.info.memory.capacity"), value: SystemMonitorFormat.memory(facts.memory),
                         detail: facts.isAppleSilicon ? L("system.info.memory.unified") : nil,
                         keywords: ["ram", "memory", "内存", "容量"])]
    }

    static func storage(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        facts.volumes.enumerated().flatMap { index, volume -> [SystemInfoField] in
            let base = "storage.\(index)."
            let group = L(volume.isInternal == false ? "system.info.volume.external" : "system.info.volume.internal",
                          volume.name)
            let keywords = ["disk", "ssd", "volume", "硬盘", "磁盘", "存储"]
                + (volume.isInternal == false ? ["external", "usb", "外接"] : [])
            var fields = [SystemInfoField(
                id: base + "capacity", section: .storage, group: group, label: L("system.info.volume.capacity"),
                value: L("system.info.volume.available", SystemMonitorFormat.storage(volume.available),
                         SystemMonitorFormat.storage(volume.total)),
                fraction: usedFraction(volume), keywords: keywords + ["free", "available", "剩余", "可用"]
            )]
            if let format = volume.format {
                fields.append(SystemInfoField(id: base + "format", section: .storage, group: group,
                                              label: L("system.info.volume.format"), value: format,
                                              keywords: ["apfs", "file system", "文件系统", "格式"]))
            }
            if let encrypted = volume.isEncrypted {
                fields.append(SystemInfoField(
                    id: base + "encryption", section: .storage, group: group, label: L("system.info.volume.encryption"),
                    value: onOff(encrypted), detail: volume.isRoot ? "FileVault" : nil,
                    badge: encrypted ? .good : .off, keywords: ["filevault", "encrypt", "加密"]
                ))
            }
            return fields
        }
    }

    static func displays(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        var fields = facts.displays.enumerated().flatMap { index, display -> [SystemInfoField] in
            let base = "display.\(index)."
            let name = display.name.isEmpty
                ? L(display.isBuiltIn ? "system.info.display.builtIn" : "system.info.display.numbered", index + 1)
                : display.name
            let looksLike = display.pointWidth != display.pixelWidth
                ? L("system.info.display.looksLike", String(display.pointWidth), String(display.pointHeight)) : nil
            var rows = [SystemInfoField(
                id: base + "resolution", section: .display, group: name, label: L("system.info.display.resolution"),
                value: pixels(display.pixelWidth, display.pixelHeight), detail: looksLike,
                keywords: ["resolution", "retina", "screen", "monitor", "分辨率", "屏幕", "显示器"]
            )]
            if let rate = display.refreshRate {
                rows.append(SystemInfoField(id: base + "refresh", section: .display, group: name,
                                            label: L("system.info.display.refresh"), value: L(
                                                "system.info.display.hz",
                                                rate
                                            ),
                                            keywords: ["hz", "refresh", "promotion", "刷新率"]))
            }
            if display.supportsHDR {
                rows.append(SystemInfoField(id: base + "hdr", section: .display, group: name, label: "HDR",
                                            value: L("system.info.supported"), badge: .good,
                                            keywords: ["hdr", "xdr", "edr"]))
            }
            return rows
        }
        let graphics = L("system.info.group.graphics")
        if let gpu = facts.gpuName {
            fields.append(SystemInfoField(
                id: "display.gpu",
                section: .display,
                group: graphics,
                label: "GPU",
                value: gpu,
                detail: facts.gpuCores.map { L("system.info.gpu.cores", $0) },
                keywords: ["gpu", "graphics", "显卡", "图形"]
            ))
        }
        fields.append(SystemInfoField(id: "display.metal", section: .display, group: graphics, label: "Metal",
                                      value: facts.supportsMetal3 ? "Metal 3" : L(facts.gpuName == nil
                                          ? "system.info.unavailable" : "system.info.supported"),
                                      keywords: ["metal", "gpu"]))
        return fields
    }

    static func network(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        let primary = primaryInterface(facts)
        return facts.interfaces.flatMap { interface($0, facts: facts, primary: $0 == primary) }
            + connection(facts)
    }

    /// One connected interface's addresses; the primary one also carries the router and DNS.
    static func interface(_ interface: SystemInfoFacts.Interface, facts: SystemInfoFacts,
                          primary: Bool) -> [SystemInfoField] {
        var fields: [SystemInfoField] = []
        let base = "network.\(interface.name)."
        let group = interface.displayName + " (" + interface.name + ")"
        let addressWords = ["ip", "address", "地址", "内网"]
        if !interface.ipv4.isEmpty {
            fields.append(SystemInfoField(
                id: base + "ipv4",
                section: .network,
                group: group,
                label: L("system.info.ipv4"),
                value: interface.ipv4.joined(separator: ", "),
                keywords: addressWords + ["ipv4"]
            ))
        }
        if !interface.ipv6.isEmpty {
            fields.append(SystemInfoField(
                id: base + "ipv6",
                section: .network,
                group: group,
                label: L("system.info.ipv6"),
                value: interface.ipv6.joined(separator: ", "),
                keywords: addressWords + ["ipv6"]
            ))
        }
        if let mac = interface.hardwareAddress {
            fields.append(SystemInfoField(
                id: base + "mac",
                section: .network,
                group: group,
                label: L("system.info.mac"),
                value: mac,
                sensitive: true,
                keywords: ["mac", "hardware", "物理地址", "mac地址"]
            ))
        }
        guard primary else { return fields }
        if let router = facts.router {
            fields.append(SystemInfoField(id: base + "router", section: .network, group: group,
                                          label: L("system.info.router"), value: router,
                                          keywords: ["ip", "router", "gateway", "网关", "路由"]))
        }
        if !facts.dnsServers.isEmpty {
            fields.append(SystemInfoField(id: base + "dns", section: .network, group: group, label: "DNS",
                                          value: facts.dnsServers.joined(separator: ", "), keywords: ["dns"]))
        }
        return fields
    }

    static func connection(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        var fields: [SystemInfoField] = []
        let other = L("system.info.group.connection")
        if facts.interfaces.isEmpty {
            fields.append(SystemInfoField(id: "network.offline", section: .network, group: other,
                                          label: L("system.info.network.status"),
                                          value: L("system.info.network.offline"),
                                          badge: .warning, keywords: ["offline", "离线", "断网"]))
        }
        fields.append(SystemInfoField(
            id: "network.proxy",
            section: .network,
            group: other,
            label: L("system.info.proxy"),
            value: facts.proxies.isEmpty ? L("system.info.off") : facts.proxies.joined(separator: ", "),
            badge: facts.proxies.isEmpty ? .off : nil,
            keywords: ["proxy", "代理", "pac"]
        ))
        if let host = facts.hostName {
            fields.append(SystemInfoField(id: "network.hostname", section: .network, group: other,
                                          label: L("system.info.hostName"), value: host, sensitive: true,
                                          keywords: ["hostname", "host", "主机", "电脑名"]))
        }
        return fields
    }

    static func battery(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        guard let battery = facts.battery else { return [] }
        let group = L("system.info.section.battery")
        var fields = [SystemInfoField(
            id: "battery.charge", section: .battery, group: group, label: L("system.info.battery.charge"),
            value: L("system.info.percent", battery.percent), detail: batteryState(battery),
            fraction: Double(battery.percent) / 100, keywords: ["battery", "charge", "电量", "电池", "充电"]
        )]
        if let health = battery.health {
            fields.append(SystemInfoField(id: "battery.health", section: .battery, group: group,
                                          label: L("system.info.battery.health"), value: L(
                                              "system.info.percent",
                                              health
                                          ),
                                          badge: health >= 80 ? .good : .warning,
                                          keywords: ["health", "capacity", "健康", "容量"]))
        }
        if let cycles = battery.cycleCount {
            fields.append(SystemInfoField(id: "battery.cycles", section: .battery, group: group,
                                          label: L("system.info.battery.cycles"), value: String(cycles),
                                          keywords: ["cycle", "循环"]))
        }
        let power = L("system.info.group.power")
        if let watts = battery.adapterWatts, battery.onPower {
            fields.append(SystemInfoField(id: "battery.adapter", section: .battery, group: power,
                                          label: L("system.info.battery.adapter"), value: L("system.info.watts", watts),
                                          keywords: ["charger", "adapter", "充电器", "功率"]))
        }
        fields.append(SystemInfoField(id: "battery.lowPower", section: .battery, group: power,
                                      label: L("system.info.battery.lowPower"), value: onOff(facts.lowPowerMode),
                                      badge: facts.lowPowerMode ? .warning : .off,
                                      keywords: ["low power", "低电量", "省电"]))
        return fields
    }

    static func system(_ facts: SystemInfoFacts, now: Date) -> [SystemInfoField] {
        let macOS = "macOS"
        var fields = [SystemInfoField(
            id: "system.version", section: .system, group: macOS, label: L("system.info.version"),
            value: macOSName(facts.osVersion) + " " + facts.osVersion,
            detail: facts.osBuild.map { L("system.info.build", $0) },
            keywords: ["os", "macos", "version", "build", "版本", "系统"]
        )]
        if let kernel = facts.kernel {
            fields.append(SystemInfoField(id: "system.kernel", section: .system, group: macOS,
                                          label: L("system.info.kernel"), value: kernel,
                                          keywords: ["kernel", "darwin", "xnu", "内核"]))
        }
        if let boot = facts.bootTime {
            fields.append(SystemInfoField(
                id: "system.uptime", section: .system, group: macOS, label: L("system.info.uptime"),
                value: SystemMonitorFormat.uptime(now.timeIntervalSince(boot)),
                detail: L("system.info.bootedAt", boot.formatted(date: .abbreviated, time: .shortened)),
                keywords: ["uptime", "boot", "运行时间", "开机"]
            ))
        }
        let locale = Locale(identifier: AppLocalization.shared.language.localeIdentifier)
        fields.append(SystemInfoField(id: "system.locale", section: .system, group: macOS,
                                      label: L("system.info.locale"),
                                      value: locale.localizedString(forIdentifier: facts.localeIdentifier)
                                          ?? facts.localeIdentifier,
                                      keywords: ["locale", "language", "region", "语言", "地区"]))
        return fields + thisMac(facts)
    }

    /// The model, its numbers and the Typeflux version.
    static func thisMac(_ facts: SystemInfoFacts) -> [SystemInfoField] {
        var fields: [SystemInfoField] = []
        let mac = L("system.info.group.thisMac")
        if let name = facts.productName {
            fields.append(SystemInfoField(
                id: "system.model",
                section: .system,
                group: mac,
                label: L("system.info.model"),
                value: name,
                keywords: ["model", "型号", "机型"]
            ))
        }
        fields.append(SystemInfoField(id: "system.identifier", section: .system, group: mac,
                                      label: L("system.info.identifier"), value: facts.modelIdentifier,
                                      keywords: ["model", "identifier", "型号"]))
        if let number = facts.modelNumber {
            fields.append(SystemInfoField(id: "system.number", section: .system, group: mac,
                                          label: L("system.info.modelNumber"), value: number,
                                          keywords: ["model", "part", "型号"]))
        }
        if let serial = facts.serialNumber {
            fields.append(SystemInfoField(id: "system.serial", section: .system, group: mac,
                                          label: L("system.info.serial"), value: serial, sensitive: true,
                                          keywords: ["serial", "sn", "序列号", "保修"]))
        }
        if let version = facts.appVersion {
            fields.append(SystemInfoField(id: "system.typeflux", section: .system, group: "Typeflux",
                                          label: L("system.info.version"), value: version,
                                          keywords: ["typeflux", "version", "版本"]))
        }
        return fields
    }
}
