import Foundation

struct TypefluxCloudClientInfo: Equatable, Sendable {
    let appName: String
    let appVersion: String
    let clientID: String
    let localeIdentifier: String
    let preferredLanguages: [String]
    let osName: String
    let osVersion: String
    let architecture: String

    var userAgent: String {
        "\(Self.sanitizeProductToken(appName))/\(Self.sanitizeProductToken(appVersion))"
    }

    var acceptLanguage: String {
        preferredLanguages.enumerated()
            .map { index, language in
                if index == 0 { return language }
                let quality = max(1.0 - (Double(index) * 0.1), 0.1)
                return "\(language);q=\(String(format: "%.1f", quality))"
            }
            .joined(separator: ", ")
    }

    private static func sanitizeProductToken(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Typeflux" : trimmed
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return fallback.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }.reduce(into: "") { $0.append($1) }
    }
}

struct TypefluxCloudClientInfoProvider: Sendable {
    var info: @Sendable () -> TypefluxCloudClientInfo

    static let live = TypefluxCloudClientInfoProvider {
        let appLanguage = SettingsStore().appLanguage
        return TypefluxCloudClientInfo(
            appName: bundleString("CFBundleName") ?? bundleString("CFBundleDisplayName") ?? "Typeflux",
            appVersion: bundleString("CFBundleShortVersionString") ?? "0.0.0",
            clientID: TypefluxCloudClientIdentityStore.shared.clientID(),
            localeIdentifier: clientLocaleIdentifier(appLanguage: appLanguage),
            preferredLanguages: clientPreferredLanguages(appLanguage: appLanguage),
            osName: "macOS",
            osVersion: operatingSystemVersion(),
            architecture: architecture()
        )
    }

    static func clientLocaleIdentifier(appLanguage: AppLanguage) -> String {
        appLanguage.localeIdentifier
    }

    static func clientPreferredLanguages(
        appLanguage: AppLanguage,
        systemPreferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        var languages = [appLanguage.localeIdentifier]
        languages.append(contentsOf: systemPreferredLanguages)

        return languages.reduce(into: []) { uniqueLanguages, language in
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !uniqueLanguages.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                return
            }
            uniqueLanguages.append(trimmed)
        }
    }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func architecture() -> String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }
}

final class TypefluxCloudClientIdentityStore: @unchecked Sendable {
    static let shared = TypefluxCloudClientIdentityStore()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "TypefluxCloudClientID"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func clientID() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = defaults.string(forKey: key),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }
}

enum TypefluxCloudScenario: String, CaseIterable, Hashable, Sendable {
    case voiceInput = "voice-input"
    case askAnything = "ask-anything"
    case textRewrite = "text-rewrite"
    case automaticVocabulary = "automatic-vocabulary"
    case modelSetup = "model-setup"
}

enum TypefluxCloudRequestHeaders {
    static let scenarioField = "x-scenario"
    static let clientIDField = "x-client-id"
    static let clientLocaleField = "x-client-locale"
    static let clientLanguagesField = "x-client-languages"
    static let clientOSField = "x-client-os"
    static let clientOSVersionField = "x-client-os-version"
    static let clientArchitectureField = "x-client-architecture"
    static let personaIDField = "x-persona-id"

    static func applyScenario(_ scenario: TypefluxCloudScenario, to request: inout URLRequest) {
        request.setValue(scenario.rawValue, forHTTPHeaderField: scenarioField)
    }

    static func applyClientInfo(
        to request: inout URLRequest,
        provider: TypefluxCloudClientInfoProvider = .live
    ) {
        let info = provider.info()
        request.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
        if !info.acceptLanguage.isEmpty {
            request.setValue(info.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
        request.setValue(info.clientID, forHTTPHeaderField: clientIDField)
        request.setValue(info.localeIdentifier, forHTTPHeaderField: clientLocaleField)
        request.setValue(info.preferredLanguages.joined(separator: ","), forHTTPHeaderField: clientLanguagesField)
        request.setValue(info.osName, forHTTPHeaderField: clientOSField)
        request.setValue(info.osVersion, forHTTPHeaderField: clientOSVersionField)
        request.setValue(info.architecture, forHTTPHeaderField: clientArchitectureField)
    }

    static func applyPersonaID(_ personaID: UUID?, to request: inout URLRequest) {
        guard let personaID else { return }
        request.setValue(personaID.uuidString, forHTTPHeaderField: personaIDField)
    }

    static func applyingPersonaID(
        _ personaID: UUID?,
        to headers: [String: String] = [:],
        provider: LLMRemoteProvider
    ) -> [String: String] {
        guard provider == .typefluxCloud, let personaID else { return headers }

        var merged = headers
        merged[personaIDField] = personaID.uuidString
        return merged
    }

    static func applyCloudHeaders(
        scenario: TypefluxCloudScenario,
        to request: inout URLRequest,
        provider: TypefluxCloudClientInfoProvider = .live
    ) {
        applyScenario(scenario, to: &request)
        applyClientInfo(to: &request, provider: provider)
    }

    static func applyingClientInfo(
        to headers: [String: String] = [:],
        provider: TypefluxCloudClientInfoProvider = .live
    ) -> [String: String] {
        let info = provider.info()
        var merged = headers
        merged["User-Agent"] = info.userAgent
        if !info.acceptLanguage.isEmpty {
            merged["Accept-Language"] = info.acceptLanguage
        }
        merged[clientIDField] = info.clientID
        merged[clientLocaleField] = info.localeIdentifier
        merged[clientLanguagesField] = info.preferredLanguages.joined(separator: ",")
        merged[clientOSField] = info.osName
        merged[clientOSVersionField] = info.osVersion
        merged[clientArchitectureField] = info.architecture
        return merged
    }

    static func applyingScenario(
        _ scenario: TypefluxCloudScenario,
        to headers: [String: String] = [:],
        provider: LLMRemoteProvider,
        clientInfoProvider: TypefluxCloudClientInfoProvider = .live
    ) -> [String: String] {
        guard provider == .typefluxCloud else { return headers }

        var merged = applyingClientInfo(to: headers, provider: clientInfoProvider)
        merged[scenarioField] = scenario.rawValue
        return merged
    }
}

extension ResolvedLLMConnection {
    func headers(for scenario: TypefluxCloudScenario, personaID: UUID? = nil) -> [String: String] {
        let scenarioHeaders = TypefluxCloudRequestHeaders.applyingScenario(
            scenario,
            to: additionalHeaders,
            provider: provider
        )
        return TypefluxCloudRequestHeaders.applyingPersonaID(
            personaID,
            to: scenarioHeaders,
            provider: provider
        )
    }
}
