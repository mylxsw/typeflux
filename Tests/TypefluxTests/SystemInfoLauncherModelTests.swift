import Foundation
import Testing
@testable import Typeflux

@Suite("System info launcher model", .serialized, .exclusiveUIState)
@MainActor
struct SystemInfoLauncherModelTests {
    typealias F = SystemInfoFixtures

    private func fixture(_ facts: SystemInfoFacts = F.laptop()) -> (SystemInfoLauncherModel, SystemInfoSnapshot) {
        (SystemInfoLauncherModel(), SystemInfoSnapshot.make(facts, now: F.now))
    }

    @Test func `sections by number tab and escape`() {
        withSystemMonitorLanguage {
            let (model, snapshot) = fixture()
            #expect(model.section == .overview && model.rows(snapshot, filter: "").isEmpty)
            #expect(model.handle(.number(4), snapshot: snapshot, filter: "") == .handled)
            #expect(model.section == .storage)
            #expect(model.rows(snapshot, filter: "") == snapshot.fields(in: .storage))
            _ = model.handle(.number(9), snapshot: snapshot, filter: "")
            #expect(model.section == .storage, "a number past the last section does nothing")
            _ = model.handle(.tab, snapshot: snapshot, filter: "")
            #expect(model.section == .display)
            _ = model.handle(.shiftTab, snapshot: snapshot, filter: "")
            _ = model.handle(.shiftTab, snapshot: snapshot, filter: "")
            #expect(model.section == .memory)
            _ = model.handle(.tab, snapshot: snapshot, filter: "ip")
            #expect(model.section == .memory, "⇥ stays put while searching")
            #expect(model.handle(.escape, snapshot: snapshot, filter: "") == .handled)
            #expect(model.section == .overview)
            #expect(model.handle(.escape, snapshot: snapshot, filter: "") == .unhandled, "then the launcher leaves")
            // A Mac without a battery has one section less; ⇥ wraps around it.
            let (desktop, plain) = fixture(F.desktop())
            _ = desktop.handle(.number(7), snapshot: plain, filter: "")
            #expect(desktop.section == .system)
            _ = desktop.handle(.tab, snapshot: plain, filter: "")
            #expect(desktop.section == .overview)
            #expect(desktop.handle(.number(1), snapshot: nil, filter: "") == .handled)
        }
    }

    @Test func `arrows choose and return copies`() {
        withSystemMonitorLanguage {
            let (model, snapshot) = fixture()
            model.show(.network)
            #expect(model.handle(.enter, snapshot: snapshot, filter: "") == .handled, "nothing chosen yet")
            #expect(model.handle(.copy, snapshot: snapshot, filter: "") == .unhandled, "⌘C stays the editor's")
            _ = model.handle(.up, snapshot: snapshot, filter: "")
            #expect(model.selection == snapshot.fields(in: .network).last?.id)
            _ = model.handle(.down, snapshot: snapshot, filter: "")
            #expect(model.selection == snapshot.fields(in: .network).last?.id, "the last row stays chosen")
            model.select(nil)
            _ = model.handle(.down, snapshot: snapshot, filter: "")
            _ = model.handle(.down, snapshot: snapshot, filter: "")
            #expect(model.selection == "network.en0.ipv6")
            #expect(model.handle(.enter, snapshot: snapshot, filter: "") == .copy("fe80::1c2b:9aff:fe31:7d10"))
            #expect(model.handle(.copy, snapshot: snapshot, filter: "") == .copy("fe80::1c2b:9aff:fe31:7d10"))
            #expect(model.handle(.escape, snapshot: snapshot, filter: "") == .handled)
            #expect(model.selection == nil && model.section == .network)
            // Return while searching copies the first match and chooses it.
            #expect(model.handle(.enter, snapshot: snapshot, filter: "router") == .copy("192.168.1.1"))
            #expect(model.selection == "network.en0.router")
            #expect(model.handle(.escape, snapshot: snapshot, filter: "router") == .handled)
            #expect(model.handle(.escape, snapshot: snapshot, filter: "router") == .unhandled,
                    "the launcher clears the filter")
            #expect(model.handle(.enter, snapshot: snapshot, filter: "zzz") == .handled)
            _ = model.handle(.down, snapshot: snapshot, filter: "zzz")
            #expect(model.selection == nil)
        }
    }

    @Test func `hidden values reports and the app`() {
        withSystemMonitorLanguage {
            let (model, snapshot) = fixture()
            let serial = snapshot.field("system.serial")!
            #expect(!model.isRevealed(serial))
            #expect(model.rows(snapshot, filter: "C02XK4").isEmpty)
            model.toggleReveal(serial.id)
            #expect(model.isRevealed(serial) && model.rows(snapshot, filter: "C02XK4") == [serial])
            model.toggleReveal(serial.id)
            #expect(!model.isRevealed(serial))
            // Copying a hidden row hands over the value itself.
            model.show(.system)
            model.select(serial.id)
            #expect(model.handle(.copy, snapshot: snapshot, filter: "") == .copy("C02XK4M1Q6L4"))
            #expect(model
                .handle(.copyReport, snapshot: snapshot, filter: "") ==
                .copyReport(SystemInfoReport.markdown(snapshot)))
            #expect(model.handle(.copyReport, snapshot: nil, filter: "") == .handled)
            model.toggleReveal(serial.id)
            model.reset()
            #expect(model.section == .overview && model.selection == nil && model.revealed.isEmpty)
            #expect(model.rows(nil, filter: "ip").isEmpty)
        }
    }

    @Test func `groups keep their first order`() {
        withSystemMonitorLanguage {
            let snapshot = SystemInfoSnapshot.make(F.laptop(), now: F.now)
            let groups = SystemInfoLauncherView.groups(snapshot.fields(in: .network))
            #expect(groups.map(\.title) == ["Wi-Fi (en0)", "USB 10/100/1000 LAN (en7)", "Connection"])
            #expect(groups[0].fields.map(\.id) == ["network.en0.ipv4", "network.en0.ipv6", "network.en0.mac",
                                                   "network.en0.router", "network.en0.dns"])
        }
    }

    @Test func `store reads once at A time`() async {
        let reader = FakeSystemInfoReader()
        var clock = F.now
        let store = SystemInfoStore(reader: reader, now: { clock })
        #expect(store.snapshot == nil && !store.isReading)
        store.refresh()
        store.refresh()
        #expect(store.isReading)
        await store.settle()
        #expect(reader.reads == 1 && !store.isReading)
        #expect(store.snapshot?.title == "MacBook Pro (14-inch, Nov 2023)")
        reader.facts = F.desktop()
        store.refresh()
        await store.settle()
        #expect(reader.reads == 1, "a read seconds old is kept")
        clock = F.now.addingTimeInterval(SystemInfoStore.freshness)
        store.refresh()
        await store.settle()
        #expect(reader.reads == 2 && store.snapshot?.title == "Macmini8,1")
    }
}
