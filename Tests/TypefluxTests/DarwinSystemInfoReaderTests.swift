import Foundation
import Testing
@testable import Typeflux

@Suite("System info reader")
struct DarwinSystemInfoReaderTests {
    @Test func `proxies list only what is enabled`() {
        let settings: [String: Any] = [
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 7890),
            "HTTPSEnable": NSNumber(value: 0), "HTTPSProxy": "127.0.0.1", "HTTPSPort": NSNumber(value: 7890),
            "SOCKSEnable": NSNumber(value: 1), "SOCKSProxy": "proxy.local",
            "ProxyAutoConfigEnable": NSNumber(value: 1), "ProxyAutoConfigURLString": "http://wpad/proxy.pac"
        ]
        #expect(DarwinSystemInfoReader.proxyList(settings)
            == ["HTTP 127.0.0.1:7890", "SOCKS proxy.local", "PAC http://wpad/proxy.pac"])
        #expect(DarwinSystemInfoReader.proxyList(["HTTPEnable": NSNumber(value: 1), "HTTPProxy": ""]).isEmpty)
        #expect(DarwinSystemInfoReader.proxyList([:]).isEmpty)
    }

    @Test func `battery health and registry strings`() {
        #expect(DarwinSystemInfoReader.health(raw: 4550, design: 5000) == 91)
        #expect(DarwinSystemInfoReader.health(raw: 5200, design: 5000) == 100, "a new battery reads at most 100%")
        #expect(DarwinSystemInfoReader.health(raw: nil, design: 5000) == nil)
        #expect(DarwinSystemInfoReader.health(raw: 0, design: 5000) == nil)
        #expect(DarwinSystemInfoReader.string(Data("Mac mini (2024)\0\0".utf8)) == "Mac mini (2024)")
        #expect(DarwinSystemInfoReader.string(" C02XK4 ") == "C02XK4")
        #expect(DarwinSystemInfoReader.string(Data([0, 0])) == nil)
        #expect(DarwinSystemInfoReader.string(42) == nil)
    }

    /// Reads this Mac for real: whatever it is, the basics are there and the rows build.
    @Test @MainActor func `reads this mac`() async {
        let facts = await DarwinSystemInfoReader().read()
        #expect(!facts.chip.isEmpty && facts.cores > 0 && facts.memory > 0)
        #expect(!facts.modelIdentifier.isEmpty && !facts.osVersion.isEmpty)
        #expect(["arm64", "x86_64"].contains(facts.architecture))
        let hasRoot = facts.volumes.contains { $0.isRoot }
        #expect(hasRoot)
        #expect(facts.volumes.allSatisfy { $0.available <= $0.total })
        #expect(facts.interfaces
            .allSatisfy { !$0.ipv4.isEmpty || $0.ipv6.contains { !DarwinSystemInfoReader.isLinkLocal($0) } })
        #expect(DarwinSystemInfoReader.isLinkLocal("FE80::1") && !DarwinSystemInfoReader.isLinkLocal("2408::1"))
        #expect(facts.interfaces.allSatisfy { $0.hardwareAddress.map { $0.count == 17 } ?? true })
        #expect(facts.bootTime.map { $0 < Date() } ?? true)
        let snapshot = SystemInfoSnapshot.make(facts)
        #expect(!snapshot.fields.isEmpty && !snapshot.cards.isEmpty)
        #expect(Set(snapshot.fields.map(\.id)).count == snapshot.fields.count, "row ids are unique")
    }
}

@Suite("System info localization")
struct SystemInfoLocalizationTests {
    /// Every `system.info` string exists in every language with the same placeholders.
    @Test func `every language has every string`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Typeflux/Resources")
        func strings(_ language: String) throws -> [String: String] {
            let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            let all = try #require(NSDictionary(contentsOf: url) as? [String: String])
            return all.filter { $0.key.hasPrefix("system.info.") }
        }
        let pattern = try NSRegularExpression(pattern: "%(?:\\d\\$)?[@d]")
        func placeholders(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range).replacingOccurrences(of: #"\d\$"#, with: "",
                                                                                         options: .regularExpression) }
                .sorted()
        }
        let english = try strings("en")
        #expect(english.count > 90)
        for language in ["zh-Hans", "zh-Hant", "ja", "ko"] {
            let other = try strings(language)
            #expect(Set(other.keys) == Set(english.keys), "\(language) misses or adds keys")
            for (key, value) in english {
                #expect(placeholders(other[key] ?? "") == placeholders(value), "\(language) \(key)")
            }
        }
    }
}
