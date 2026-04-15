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
        XCTAssertEqual(configuration.apiKey, "test-key")
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
        XCTAssertEqual(configuration.languageCode, "zh-CN")
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

    func testConfigurationMapsSupportedAppLanguagesToGoogleLocales() {
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .english), "en-US")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .simplifiedChinese), "zh-CN")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .traditionalChinese), "zh-TW")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .japanese), "ja-JP")
        XCTAssertEqual(GoogleCloudSpeechConfiguration.googleLanguageCode(for: .korean), "ko-KR")
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
