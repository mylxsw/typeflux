import AVFoundation
@testable import Typeflux
import XCTest

final class AudioFileTranscoderTests: XCTestCase {
    func testWavFileURLTranscodesMP3ToReadableWAV() throws {
        let mp3URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-transcoder-test-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        defer { try? FileManager.default.removeItem(at: mp3URL) }

        try Self.tinyMP3Data.write(to: mp3URL)
        let audioFile = AudioFile(fileURL: mp3URL, duration: 1)

        let wavURL = try AudioFileTranscoder.wavFileURL(for: audioFile)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        XCTAssertEqual(wavURL.pathExtension.lowercased(), "wav")
        let transcoded = try AVAudioFile(forReading: wavURL)
        XCTAssertGreaterThan(transcoded.length, 0)
        XCTAssertEqual(transcoded.processingFormat.channelCount, 1)
    }

    private static var tinyMP3Data: Data {
        let base64 = """
        SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYyLjMuMTAwAAAAAAAAAAAAAAD/83DAAAAAAAAAAAAASW5mbwAAAA8AAAAMAAAFnAAyMjIyMjIyMkVFRUVFRUVFWFhYWFhYWFhqampqampqamp9fX19fX19fZCQkJCQkJCQoqKioqKioqKitbW1tbW1tbXIyMjIyMjIyNra2tra2tra2u3t7e3t7e3t//////////8AAAAATGF2YzYyLjExAAAAAAAAAAAAAAAAJAM3AAAAAAAABZyKQKSYAAAAAAAAAAAAAAAAAP/zQMQAEzBihD9PGAAL1tu2CHmmaZpmmh7mwIYQcQsB3AIwDsFWOM62d48ePHjwEATB8Hwf5zg/4YlPfynn+U8/ynv6OCAPg+8HwcBAMKDAPg/LgQEOD79HvSAJIIMMAAC8wCA2k/cm//NCxA4X8XJ81ZxoAOJjEYGCn21gygLigKGKpsadBhgsGCVqVAZJCDkg6QV0FZ/EmC9Bdvx2jCjCk7/GGGGJo9R6/+ZF4kjEul1L//LxeMS6XUi8Xjv+VCQNCUJA0JWAA//jb/f8f+P6//NAxAoN6EKJv9sAAqZhTcm2RmMJAjsS8wgBbNlTAUKuqr12Ws/kv/U2k96/6f6v06v13K6+t6af6UI3siqj/3rcFGMNKtFrSYRgCgAWakMNCBqkeBN7IqK2FmuYqi16Hu1NULvo/4v/80LELRHASiRU5/RAqf/KqYtr1eV8vbQ5i0sfYq3dYSopd+Ldr5v96uzS2TAiQzoKgAxf0wAoADMBDAODnIzi07kIDjVCJoMKlggIoqV30/R7Xpe6vv1yDiNZ+7fTrhqL8RXKCb4G9Kn/80DEQhVRVhAA/spkSyl5JddvYlTupJPQN/XbYMpvc+r9Y6mWFGQllhYA0TjABQAAwDYA3OIQNwjngcOKkzW+k0/mK9Tll3Moo2pmVelWNyeryMdY/qtpU6cuq/GhOE2bJzEH9XlKgP/zQsRHEWBOFADv9kABGljTcV0CpgaiaMqdlYpgEgGH7S2qG5KReadv4CtATFLt+/19P/rPbdlX//V+S1/ruV/VVI/0VYACVgJaOKaQOMqZVW1hyKxgCQA6aeYTPAoChQibWRTtvbKqL//zQMRdDghKLbQ/siTmfJbN//kv974oupX17f4tq+hm5dDvc3xbQoABGjESsaKcBpl3HKZMNRVMATAIDTkSlEDATyBrbRWevCtJ8CzOt1mraun+iPu/0Ns/3a3f9xD69X//cmpBI3Pu//NCxH8PaE4llEc+IAK2GAEAEIQFzBGE9HQwTExD9MZAiYyJAED/2foMi0J8w2A8DCOBYMFICgwCQIUYmMo1tcsUf//b72+l3/////21UYAAEsGo1Gw+GosAAAuodDMCoLEIqABgcs0x//NAxJ0PEEoltD8+IJgDIw8wFZCwKgJCLxp4dwhgGxRdxEDNwGtIGZHidg/YW8MQ8ApOBAEA0EFdFKiveGQBGoYnEenCBG5l8PXJgT+LMHYZjmkyVSHfxWhARO5ARxkUIUyLx1RiamP/80LEuxEYWigpXgAC/yKHicOk+dPlw2YyUkuiy//5pNEw9IETHndVAKwIkuZCUWyLbJ1NjBAzINtwYMyFLewIrcisoM40eXMmMuqjhlyXdlthUEQyzJEiawGj2oGjwlOgqCqgaUDX+Cv/80DE0iQSAopfm6ABUe//EUO1u//EqkxBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqv/zQsScEpiV1BXYSACqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqg==
        """
        return Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
    }
}
