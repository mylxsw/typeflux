import Foundation
import Testing
@testable import Typeflux

@Suite("System info snapshot", .serialized, .exclusiveUIState)
@MainActor
struct SystemInfoSnapshotTests {
    typealias F = SystemInfoFixtures

    private func value(_ snapshot: SystemInfoSnapshot, _ id: String) -> String? {
        snapshot.field(id)?.value
    }

    @Test func `laptop header cards and sections`() {
        withSystemMonitorLanguage {
            let snapshot = SystemInfoSnapshot.make(F.laptop(), now: F.now)
            #expect(snapshot.title == "MacBook Pro (14-inch, Nov 2023)")
            #expect(snapshot.subtitle == "Mac15,6 · Apple M3 Pro")
            #expect(snapshot.system == "macOS Sequoia 15.1 (24B83)")
            #expect(snapshot.hasBattery && snapshot.sections == SystemInfoSection.allCases)
            #expect(snapshot.cards.map(\.section) == [.processor, .memory, .storage, .display, .network, .battery])
            let cards = Dictionary(uniqueKeysWithValues: snapshot.cards.map { ($0.section, $0) })
            #expect(cards[.processor]?.detail == "12-core CPU · 18-core GPU")
            #expect(cards[.memory]?.value == "18 GB" && cards[.memory]?.detail == "Unified memory")
            #expect(cards[.storage]?.value == "1 TB" && cards[.storage]?.detail == "382 GB available · +1 more")
            #expect(abs((cards[.storage]?.fraction ?? 0) - 0.618) < 0.001)
            #expect(cards[.display]?.value == "3024 × 1964" && cards[.display]?.detail == "120 Hz · +1 display")
            #expect(cards[.network]?.value == "Wi-Fi" && cards[.network]?.detail == "192.168.1.23")
            #expect(cards[.battery]?.value == "82%" && cards[.battery]?.detail == "Charging")
            #expect(SystemInfoReport.summary(snapshot)
                == "MacBook Pro (14-inch, Nov 2023) · Apple M3 Pro · 18 GB · 1 TB · macOS Sequoia 15.1 (24B83)")
        }
    }

    @Test func `laptop rows`() {
        withSystemMonitorLanguage {
            let snapshot = SystemInfoSnapshot.make(F.laptop(), now: F.now)
            #expect(snapshot.field("processor.cores")?.text == "12 cores (6 performance + 6 efficiency)")
            #expect(value(snapshot, "processor.rosetta") == "Installed")
            #expect(value(snapshot, "processor.translated") == "Natively")
            #expect(snapshot.field("processor.architecture")?.detail == "Apple silicon")
            #expect(value(snapshot, "storage.0.capacity") == "382 GB available of 1 TB")
            #expect(snapshot.field("storage.0.capacity")?.group == "Internal · Macintosh HD")
            #expect(snapshot.field("storage.1.capacity")?.group == "External · T7 Shield")
            #expect(snapshot.field("storage.0.encryption")?.text == "On (FileVault)")
            #expect(snapshot.field("storage.1.encryption")?.badge == .off)
            #expect(snapshot.field("display.0.resolution")?.text == "3024 × 1964 (Looks like 1512 × 982)")
            #expect(snapshot.field("display.0.hdr")?.value == "Supported")
            #expect(snapshot.field("display.1.resolution")?.group == "Display 2", "an unnamed screen gets a number")
            #expect(snapshot.field("display.1.hdr") == nil)
            #expect(snapshot.field("display.gpu")?.text == "Apple M3 Pro (18-core GPU)")
            #expect(value(snapshot, "display.metal") == "Metal 3")
            #expect(value(snapshot, "network.en0.router") == "192.168.1.1")
            #expect(value(snapshot, "network.en0.dns") == "223.5.5.5, 119.29.29.29")
            #expect(snapshot.field("network.en7.router") == nil, "only the primary connection has the router")
            #expect(snapshot.field("network.en7.ipv4")?.group == "USB 10/100/1000 LAN (en7)")
            #expect(value(snapshot, "network.proxy") == "HTTP 127.0.0.1:7890")
            #expect(snapshot.field("battery.health")?.badge == .good)
            #expect(value(snapshot, "battery.cycles") == "214")
            #expect(value(snapshot, "battery.adapter") == "96 W")
            #expect(value(snapshot, "battery.lowPower") == "Off")
            #expect(value(snapshot, "system.uptime") == "3 d 4 h")
            #expect(value(snapshot, "system.locale") == "English (United States)")
            #expect(value(snapshot, "system.typeflux") == "1.42.0")
            let sensitive = Set(snapshot.fields.filter(\.sensitive).map(\.id))
            #expect(sensitive == ["network.en0.mac", "network.hostname", "system.serial"])
        }
    }

    @Test func `desktop without optional facts`() {
        withSystemMonitorLanguage {
            let snapshot = SystemInfoSnapshot.make(F.desktop(), now: F.now)
            #expect(snapshot.title == "Macmini8,1" && snapshot.subtitle == "Intel(R) Core(TM) i7-8700B")
            #expect(snapshot.system == "macOS Ventura 13.6.9")
            #expect(!snapshot.hasBattery && !snapshot.sections.contains(.battery))
            #expect(snapshot.cards.map(\.section) == [.processor, .memory, .network, .system])
            #expect(snapshot.cards.first { $0.section == .memory }?.detail == "")
            #expect(snapshot.cards.first { $0.section == .network }?.value == "Not connected")
            #expect(snapshot.cards.last?.value == "macOS 13.6.9" && snapshot.cards.last?.detail == "Ventura")
            #expect(snapshot.field("processor.rosetta") == nil, "Intel Macs have no Rosetta row")
            #expect(snapshot.field("processor.architecture")?.detail == "Intel")
            #expect(snapshot.field("processor.cores")?.detail == nil)
            #expect(snapshot.fields(in: .storage).isEmpty && snapshot.fields(in: .battery).isEmpty)
            #expect(value(snapshot, "display.metal") == "Unavailable")
            #expect(value(snapshot, "network.offline") == "Not connected")
            #expect(value(snapshot, "network.proxy") == "Off")
            #expect(snapshot.field("network.hostname") == nil && snapshot.field("system.serial") == nil)
            #expect(snapshot.field("system.model") == nil && snapshot.field("system.uptime") == nil)
            let chinese = Locale(identifier: "en").localizedString(forIdentifier: "zh_CN")
            #expect(value(snapshot, "system.locale") == chinese && chinese?.hasPrefix("Chinese") == true)
        }
    }

    @Test func `battery states and health`() {
        withSystemMonitorLanguage {
            var facts = F.laptop()
            facts.battery = .init(percent: 40, charging: false, onPower: false, cycleCount: nil, health: 72,
                                  adapterWatts: 96)
            facts.lowPowerMode = true
            let snapshot = SystemInfoSnapshot.make(facts, now: F.now)
            #expect(snapshot.field("battery.charge")?.detail == "On battery")
            #expect(snapshot.field("battery.health")?.badge == .warning)
            #expect(snapshot.field("battery.cycles") == nil)
            #expect(snapshot.field("battery.adapter") == nil, "the adapter shows only while plugged in")
            #expect(snapshot.field("battery.lowPower")?.value == "On")
            facts.battery?.onPower = true
            #expect(SystemInfoSnapshot.make(facts, now: F.now).field("battery.charge")?.detail == "On power adapter")
        }
    }

    @Test func `mac OS names and other languages`() {
        #expect(SystemInfoSnapshot.macOSName("14.7") == "macOS Sonoma")
        #expect(SystemInfoSnapshot.macOSName("26.0") == "macOS Tahoe")
        #expect(SystemInfoSnapshot.macOSName("99.1") == "macOS")
        withSystemMonitorLanguage(.simplifiedChinese) {
            let snapshot = SystemInfoSnapshot.make(F.laptop(), now: F.now)
            #expect(SystemInfoSection.storage.title == "存储")
            #expect(snapshot.field("storage.0.capacity")?.value == "可用 382 GB，共 1 TB")
            #expect(snapshot.field("system.serial")?.label == "序列号")
        }
    }

    @Test func `search finds by label value and keyword prefix`() {
        withSystemMonitorLanguage {
            let fields = SystemInfoSnapshot.make(F.laptop(), now: F.now).fields
            let ip = SystemInfoSearch.filter(fields, query: "ip").map(\.id)
            #expect(ip == ["network.en0.ipv4", "network.en0.ipv6", "network.en0.router", "network.en7.ipv4"],
                    "keywords match from their start: \"ip\" does not reach \"chip\"")
            #expect(SystemInfoSearch.filter(fields, query: "序列号").map(\.id) == ["system.serial"])
            #expect(SystemInfoSearch.filter(fields, query: "HZ").map(\.id) == [
                "display.0.refresh",
                "display.1.refresh"
            ])
            #expect(SystemInfoSearch.filter(fields, query: "storage format").count == 2, "every word must match")
            #expect(SystemInfoSearch.filter(fields, query: "  ").count == fields.count)
            // Hidden values are not searched until shown.
            #expect(SystemInfoSearch.filter(fields, query: "C02XK4").isEmpty)
            #expect(SystemInfoSearch.filter(fields, query: "C02XK4", revealed: ["system.serial"])
                .map(\.id) == ["system.serial"])
            #expect(SystemInfoSearch.filter(fields, query: "zzz").isEmpty)
        }
    }

    @Test func `markdown report leaves sensitive values out`() {
        withSystemMonitorLanguage {
            let snapshot = SystemInfoSnapshot.make(F.laptop(), now: F.now)
            let report = SystemInfoReport.markdown(snapshot)
            #expect(report
                .hasPrefix(
                    "## MacBook Pro (14-inch, Nov 2023)\n\nMac15,6 · Apple M3 Pro · macOS Sequoia 15.1 (24B83)\n"
                ))
            #expect(report
                .contains("\n### Storage\n- **Internal · Macintosh HD**\n  - Capacity: 382 GB available of 1 TB\n"))
            #expect(report.contains("- CPU cores: 12 cores (6 performance + 6 efficiency)"))
            #expect(!report.contains("C02XK4M1Q6L4") && !report.contains("a4:83:e7") && !report.contains("oras-mbp"))
            #expect(!report.contains("### Overview"))
            let full = SystemInfoReport.markdown(snapshot, includeSensitive: true)
            #expect(full.contains("Serial number: C02XK4M1Q6L4") && full.contains("MAC address: a4:83:e7:2c:91:5f"))
            let desktop = SystemInfoReport.markdown(SystemInfoSnapshot.make(F.desktop(), now: F.now))
            #expect(!desktop.contains("### Battery") && !desktop.contains("### Storage"))
        }
    }
}
