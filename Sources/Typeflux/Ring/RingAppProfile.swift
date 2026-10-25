import Foundation

/// Actions the ring shows first while one app is in front. Clicking the middle of the ring
/// switches between these and the global actions.
struct RingAppProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var bundleIdentifier: String
    /// The app's name when it was added, shown when the app is not installed any more.
    var appName: String
    var isEnabled: Bool
    var actions: [RingAction]

    init(id: UUID = UUID(), bundleIdentifier: String, appName: String, isEnabled: Bool = true,
         actions: [RingAction] = []) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.isEnabled = isEnabled
        self.actions = Array(actions.prefix(RingConfiguration.maxActions))
    }

    /// Only a switched-on profile with something to choose replaces the global actions.
    var isActive: Bool {
        isEnabled && !actions.isEmpty
    }

    var canAddAction: Bool {
        actions.count < RingConfiguration.maxActions
    }

    private enum CodingKeys: String, CodingKey { case id, bundleIdentifier, appName, isEnabled, actions }

    /// Like the global list, an action written by a newer version is skipped, not the whole profile.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        appName = try values.decodeIfPresent(String.self, forKey: .appName) ?? bundleIdentifier
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let decoded = try values.decodeIfPresent([RingLossyAction].self, forKey: .actions) ?? []
        actions = Array(decoded.compactMap(\.action).prefix(RingConfiguration.maxActions))
    }
}

/// Decodes an action, or nothing when it was written by a newer version.
struct RingLossyAction: Decodable {
    let action: RingAction?

    init(from decoder: any Decoder) throws {
        action = try? RingAction(from: decoder)
    }
}

/// Decodes a profile, or nothing when it is unreadable.
struct RingLossyProfile: Decodable {
    let profile: RingAppProfile?

    init(from decoder: any Decoder) throws {
        profile = try? RingAppProfile(from: decoder)
    }
}
