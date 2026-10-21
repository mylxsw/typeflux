import Testing
@testable import TypefluxIOS
import UIKit

@MainActor
@Suite("Mobile app icons")
struct ChatAppIconTests {
    @Test func `catalog matches built phone and pad icons`() throws {
        let bundle = Bundle.main
        // Read raw packaging metadata; Bundle's runtime dictionary resolves device-qualified keys.
        let data = try Data(contentsOf: bundle.bundleURL.appendingPathComponent("Info.plist"))
        let metadata = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(ChatAppIcon.allCases.count == 12)
        #expect(Set(ChatAppIcon.allCases.map(\.id)).count == 12)
        #expect(ChatAppIcon.current(named: nil) == .primary)
        #expect(ChatAppIcon.current(named: "removed-icon") == nil)
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let icons = try #require(metadata[key] as? [String: Any])
            let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
            #expect(Set(alternates.keys) == Set(ChatAppIcon.allCases.compactMap(\.alternateName)))
            for icon in ChatAppIcon.allCases {
                #expect(ChatAppIcon.current(named: icon.alternateName) == icon)
                #expect(icon.title != "appIcon." + icon.rawValue)
                #expect(UIImage(named: icon.previewName) != nil)
                if let name = icon.alternateName {
                    let entry = try #require(alternates[name] as? [String: Any])
                    #expect(entry["CFBundleIconName"] as? String == name)
                    // Modern asset catalogs use CFBundleIconName without legacy loose PNG files.
                    if let files = entry["CFBundleIconFiles"] as? [String] {
                        #expect(!files.isEmpty)
                        #expect(files.allSatisfy { UIImage(named: $0) != nil })
                    }
                }
            }
        }
        let system = SystemChatIconApplication()
        #expect(system.alternateIconName == UIApplication.shared.alternateIconName)
        #expect(system.supportsAlternateIcons == UIApplication.shared.supportsAlternateIcons)
    }

    @Test func `changes and restores primary using system state`() async {
        let app = IconApplicationStub()
        let controller = ChatAppIconController(application: app)
        #expect(controller.selected == .primary)
        await controller.select(.black)
        #expect(app.requests == [ChatAppIcon.black.alternateName])
        #expect(controller.selected == .black)
        #expect(!controller.isChanging && !controller.changeFailed)
        #expect(ChatAppIconController(application: app).selected == .black)
        await controller.select(.primary)
        #expect(app.requests.count == 2 && app.requests[1] == nil)
        #expect(controller.selected == .primary)
    }

    @Test func `ignores unsupported and already selected requests`() async {
        let app = IconApplicationStub()
        let controller = ChatAppIconController(application: app)
        await controller.select(.primary)
        app.supportsAlternateIcons = false
        controller.refresh()
        await controller.select(.black)
        #expect(!controller.supportsAlternateIcons)
        #expect(app.requests.isEmpty)
        #expect(!controller.changeFailed)
        app.alternateIconName = "unknown"
        controller.refresh()
        #expect(controller.selected == nil)
    }

    @Test func `failure keeps actual selection and can retry`() async {
        let app = IconApplicationStub()
        app.alternateIconName = ChatAppIcon.white.alternateName
        app.fail = true
        let controller = ChatAppIconController(application: app)
        await controller.select(.black)
        #expect(controller.changeFailed && !controller.isChanging)
        #expect(controller.selected == .white)
        app.fail = false
        await controller.select(.black)
        #expect(!controller.changeFailed)
        #expect(controller.selected == .black)
        app.alternateIconName = ChatAppIcon.colorful.alternateName
        controller.refresh()
        #expect(controller.selected == .colorful)
    }

    @Test func `concurrent changes are ignored until completion`() async {
        let app = IconApplicationStub()
        app.suspend = true
        let controller = ChatAppIconController(application: app)
        let change = Task { await controller.select(.black) }
        while app.continuation == nil {
            await Task.yield()
        }
        #expect(controller.isChanging)
        #expect(controller.selected == .primary)
        await controller.select(.white)
        controller.refresh()
        #expect(app.requests.count == 1)
        app.continuation?.resume()
        await change.value
        #expect(!controller.isChanging)
        #expect(controller.selected == .black)
    }
}

@MainActor
private final class IconApplicationStub: ChatIconApplication {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var requests: [String?] = []
    var fail = false
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?

    func setIcon(named name: String?) async throws {
        requests.append(name)
        if suspend {
            await withCheckedContinuation { continuation = $0 }
        }
        if fail {
            throw CocoaError(.featureUnsupported)
        }
        alternateIconName = name
    }
}
