import Foundation
import Testing
import TypefluxChat
@testable import TypefluxIOS
import UIKit

@MainActor
@Suite("Mobile platform adapters")
struct PlatformTests {
    @Test func `device identifier survives relaunch`() throws {
        let name = "typeflux-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = DeviceIdentity.persistentID(defaults: defaults)
        let second = DeviceIdentity.persistentID(defaults: defaults)
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.lowercased())
        defaults.set("ios-invalid", forKey: "typeflux.ios.device-id")
        #expect(UUID(uuidString: DeviceIdentity.persistentID(defaults: defaults)) != nil)
    }

    @Test func `account round trips through secure storage and deletes`() throws {
        let endpoint = try #require(URL(string: "https://" + UUID().uuidString + ".example.invalid"))
        let store = KeychainCredentialStore(endpoint: endpoint)
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let account = SavedAccount(
            email: "test@example.invalid",
            session: ChatSession(accessToken: "test", expiresAt: 42, refreshToken: "refresh")
        )
        try store.save(account)
        #expect(try store.load()?.accessToken == "test")
        #expect(try store.load()?.email == account.email)
        try store.save(SavedAccount(
            email: account.email,
            session: ChatSession(accessToken: "rotated", expiresAt: 43, refreshToken: "new")
        ))
        #expect(try store.load()?.session.accessToken == "rotated")
        try store.clear()
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func `endpoints use distinct credential namespaces`() throws {
        let first = try KeychainCredentialStore(endpoint: #require(URL(string: "https://api.typeflux.app")))
        let second = try KeychainCredentialStore(endpoint: #require(URL(string: "https://staging.example.invalid")))
        #expect(first.service != second.service)
    }

    @Test(arguments: [
        nil,
        "http://example.com",
        "https://user:password@example.com",
        "https://example.com?secret=1",
        "https://example.com/#fragment",
        "broken"
    ])
    func `invalid endpoints use production default`(value: String?) {
        #expect(AppConfiguration.resolve(value).absoluteString == "https://api.typeflux.app")
    }

    @Test func `secure build endpoint is accepted`() {
        #expect(AppConfiguration.resolve("https://staging.example.com").host == "staging.example.com")
    }

    @Test(arguments: ["mac-pro.local", "mac-mini.local", "localhost", "127.0.0.1", "192.168.1.20", "[::1]", "[fd12::1]"])
    func `local HTTP requires an explicit Debug override`(host: String) {
        let endpoint = "http://\(host):8080"
        #expect(AppConfiguration.resolve(endpoint).absoluteString == "https://api.typeflux.app")
        #if DEBUG
            #expect(AppConfiguration.resolve(endpoint, allowLocalHTTP: true).absoluteString == endpoint)
        #else
            #expect(AppConfiguration.resolve(endpoint, allowLocalHTTP: true).absoluteString == "https://api.typeflux.app")
        #endif
    }

    @Test(arguments: ["example.com", "mac-pro.local.example.com", "8.8.8.8", "172.15.1.1", "172.32.1.1", "192.169.1.1", "[2001:4860::1]"])
    func `development override rejects public HTTP hosts`(host: String) {
        #expect(AppConfiguration.resolve("http://\(host):8080", allowLocalHTTP: true).absoluteString == "https://api.typeflux.app")
    }

    @Test(arguments: ["http://user:secret@mac-pro.local:8080", "http://mac-mini.local:8080?token=fixture", "http://mac-pro.local:8080#fragment", "http://mac-pro.local:0"])
    func `development override rejects unsafe URLs`(endpoint: String) {
        #expect(AppConfiguration.resolve(endpoint, allowLocalHTTP: true).absoluteString == "https://api.typeflux.app")
    }

    @Test func `model selection shows server price multiplier`() {
        #expect(ChatModel(id: "priced", name: "Pro", pricing: ["multiplier": "2.5", "unit": "credit"])
            .mobileDisplayName == "Pro · 2.5× credits")
        #expect(ChatModel(id: "legacy", name: "Legacy").mobileDisplayName == "Legacy")
        #expect(ChatModel(id: "invalid", name: "Invalid", pricing: ["multiplier": "invalid"])
            .mobileDisplayName == "Invalid")
    }

    @Test func `large photo becomes bounded JPEG`() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1000)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1000))
        }
        let data = try #require(source.pngData())
        let value = try ImageAttachment.dataURL(data)
        #expect(value.hasPrefix("data:image/jpeg;base64,"))
        #expect(value.utf8.count <= 2_800_000)
        let result = try #require(ImageAttachment.decode(value))
        #expect(result.size.width <= 1600)
        #expect(result.size.height <= 1600)
    }

    @Test func `corrupt image is rejected`() {
        #expect(throws: (any Error).self) { try ImageAttachment.dataURL(Data("invalid".utf8)) }
        #expect(ImageAttachment.decode("https://example.com/private.jpg") == nil)
        #expect(ImageAttachment.decode("data:image/jpeg;base64,?") == nil)
    }

    @Test func `explicit synthetic preview is network free and labelled`() async {
        let store = SyntheticPreview.makeStore()
        await store.restore()
        #expect(store.isSynthetic)
        #expect(store.email == "preview@example.invalid")
        await store.select("preview")
        #expect(store.conversation?.messages.count == 2)
        store.newConversation()
        store.draft = "A preview question"
        await store.send()
        #expect(store.conversation?.messages.last?.text.contains("synthetic preview") == true)
        await store.signOut()
        #expect(!store.isAuthenticated)
    }
}
