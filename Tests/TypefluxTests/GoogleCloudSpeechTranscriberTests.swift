import GRPC
import XCTest
@testable import Typeflux

final class GoogleCloudSpeechTranscriberTests: XCTestCase {
    func testConfigurationTrimsCredentialsAndBuildsUnderscoreRecognizer() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "  demo-project  ",
            apiKey: "  test-key  ",
            model: "  latest_long  ",
            appLanguage: .english,
        )

        XCTAssertEqual(configuration.projectID, "demo-project")
        XCTAssertEqual(configuration.credentialValue, "test-key")
        XCTAssertEqual(configuration.credential, .bearerToken("test-key"))
        XCTAssertEqual(configuration.model, "latest_long")
        XCTAssertEqual(configuration.location, "global")
        XCTAssertEqual(configuration.endpointHost, "speech.googleapis.com")
        XCTAssertEqual(configuration.languageCode, "en-US")
        XCTAssertEqual(configuration.recognizer, "projects/demo-project/locations/global/recognizers/_")
        XCTAssertEqual(
            configuration.routingMetadataValue,
            "recognizer=projects%2Fdemo-project%2Flocations%2Fglobal%2Frecognizers%2F_",
        )
    }

    func testConfigurationUsesDefaultModelWhenModelIsEmpty() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: " ",
            appLanguage: .simplifiedChinese,
        )

        XCTAssertEqual(configuration.model, GoogleCloudSpeechDefaults.model)
        XCTAssertEqual(configuration.location, "us")
        XCTAssertEqual(configuration.endpointHost, "us-speech.googleapis.com")
        XCTAssertEqual(configuration.recognizer, "projects/demo-project/locations/us/recognizers/_")
        XCTAssertEqual(configuration.languageCode, "cmn-Hans-CN")
    }

    func testConfigurationRoutesChirp3ToRegionalEndpoint() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: " chirp_3 ",
            appLanguage: .english,
        )

        XCTAssertEqual(configuration.model, "chirp_3")
        XCTAssertEqual(configuration.location, "us")
        XCTAssertEqual(configuration.endpointHost, "us-speech.googleapis.com")
        XCTAssertEqual(configuration.recognizer, "projects/demo-project/locations/us/recognizers/_")
        XCTAssertEqual(
            configuration.routingMetadataValue,
            "recognizer=projects%2Fdemo-project%2Flocations%2Fus%2Frecognizers%2F_",
        )
    }

    func testConfigurationRoutesOnlyChirp3ToRegionalEndpoint() throws {
        let chirp = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: "chirp",
            appLanguage: .simplifiedChinese,
        )
        let chirp2 = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: "chirp_2",
            appLanguage: .simplifiedChinese,
        )

        XCTAssertEqual(chirp.location, "global")
        XCTAssertEqual(chirp.endpointHost, "speech.googleapis.com")
        XCTAssertEqual(chirp2.location, "global")
        XCTAssertEqual(chirp2.endpointHost, "speech.googleapis.com")
    }

    func testSuggestedModelsExcludeUnavailableChirpModels() {
        XCTAssertEqual(
            GoogleCloudSpeechDefaults.suggestedModels,
            ["chirp_3", "long", "short", "latest_long", "latest_short"],
        )
        XCTAssertFalse(GoogleCloudSpeechDefaults.suggestedModels.contains("chirp"))
        XCTAssertFalse(GoogleCloudSpeechDefaults.suggestedModels.contains("chirp_2"))
    }

    func testConfigurationTreatsAIzaCredentialAsAPIKey() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "AIzaExampleCredential",
            model: "chirp_3",
            appLanguage: .english,
        )

        XCTAssertEqual(configuration.credential, .apiKey("AIzaExampleCredential"))
    }

    func testConfigurationTreatsBearerPrefixedCredentialAsBearerToken() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "  Bearer ya29.example-token  ",
            model: "chirp_3",
            appLanguage: .english,
        )

        XCTAssertEqual(configuration.credentialValue, "Bearer ya29.example-token")
        XCTAssertEqual(configuration.credential, .bearerToken("ya29.example-token"))
    }

    func testConfigurationMapsSupportedAppLanguagesToGoogleLocales() {
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .english), "en-US")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .simplifiedChinese), "cmn-Hans-CN")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .traditionalChinese), "cmn-Hant-TW")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .japanese), "ja-JP")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .korean), "ko-KR")
    }

    func testConfigurationMapsChineseToSupportedGoogleLocales() throws {
        let simplified = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: "chirp_3",
            appLanguage: .simplifiedChinese,
        )
        let traditional = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "test-key",
            model: "chirp_3",
            appLanguage: .traditionalChinese,
        )

        XCTAssertEqual(simplified.languageCode, "cmn-Hans-CN")
        XCTAssertEqual(traditional.languageCode, "cmn-Hant-TW")
        XCTAssertEqual(
            GoogleCloudSpeechConfiguration.googleLanguageCode(for: .simplifiedChinese, model: "long"),
            "cmn-Hans-CN",
        )
        XCTAssertEqual(
            GoogleCloudSpeechConfiguration.googleLanguageCode(for: .traditionalChinese, model: "short"),
            "cmn-Hant-TW",
        )
    }

    func testPermissionDeniedWithAPIKeyExplainsOAuthRequirement() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "AIzaExampleCredential",
            model: "chirp_3",
            appLanguage: .english,
        )

        let message = GoogleCloudSpeechStreamingSession.rpcErrorMessage(
            GRPCStatus(
                code: .permissionDenied,
                message: "Permission 'speech.recognizers.recognize' denied on resource.",
            ),
            configuration: configuration,
        )

        XCTAssertTrue(message.contains("OAuth access token"))
        XCTAssertTrue(message.contains("Application Default Credentials"))
        XCTAssertTrue(message.contains("projects/demo-project/locations/us/recognizers/_"))
    }

    func testPermissionDeniedWithBearerTokenFocusesOnIAM() throws {
        let configuration = try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "ya29.example-token",
            model: "chirp_3",
            appLanguage: .english,
        )

        let message = GoogleCloudSpeechStreamingSession.rpcErrorMessage(
            GRPCStatus(code: .permissionDenied, message: "principal missing permission"),
            configuration: configuration,
        )

        XCTAssertFalse(message.contains("Application Default Credentials instead of an API key"))
        XCTAssertTrue(message.contains("speech.recognizers.recognize"))
        XCTAssertTrue(message.contains("Backend message: principal missing permission"))
    }

    func testConfigurationRequiresProjectIDAndAPIKey() {
        XCTAssertThrowsError(try GoogleCloudSpeechConfiguration(
            projectID: "",
            apiKey: "test-key",
            model: "long",
            appLanguage: .english,
        )) { error in
            XCTAssertEqual(error.localizedDescription, GoogleCloudSpeechError.missingProjectID.localizedDescription)
        }

        XCTAssertThrowsError(try GoogleCloudSpeechConfiguration(
            projectID: "demo-project",
            apiKey: "",
            model: "long",
            appLanguage: .english,
        )) { error in
            XCTAssertEqual(error.localizedDescription, GoogleCloudSpeechError.missingAPIKey.localizedDescription)
        }
    }
}
