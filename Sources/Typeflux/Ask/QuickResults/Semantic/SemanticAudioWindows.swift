import Foundation

/// Bounded 16 kHz mono Float32 windows. Only near-digital silence is skipped; this is not a VAD.
struct SemanticAudioWindows {
    static let rate = 16000
    static let width = 30 * rate
    static let stride = 25 * rate
    static let recipe = "audio30-stride25-pcm16k-f32-peak1e-7-v1"

    private var pending = Data()
    private var start: Int
    private var covered: Int

    init(cursor: SemanticMediaCursor) throws {
        let next = cursor.audioUntil * Double(Self.rate)
        let end = cursor.audioCoveredUntil * Double(Self.rate)
        guard next.isFinite, end.isFinite, next >= 0, end >= 0,
              next < Double(Int.max - Self.width), end < Double(Int.max - Self.width) else {
            throw AskFileReadError.protocolError
        }
        start = Int(next.rounded()); covered = Int(end.rounded())
    }

    mutating func append(_ bytes: Data, folder: URL,
                         emit: (AskFileReadResponse) throws -> Void) throws {
        guard bytes.count.isMultiple(of: 4) else { throw AskFileReadError.protocolError }
        pending.append(bytes)
        while pending.count >= Self.width * 4 {
            try flush(Self.width, advance: Self.stride, folder: folder, emit: emit)
        }
    }

    mutating func finish(folder: URL, emit: (AskFileReadResponse) throws -> Void) throws {
        let end = start + pending.count / 4
        if end > covered {
            try flush(pending.count / 4, advance: pending.count / 4, folder: folder, emit: emit)
        }
        // EOF may contain only the overlap already covered by the last full window.
        try emit(.init(more: true, audioProgress: .init(next: max(end, covered), covered: max(end, covered))))
        pending.removeAll()
    }

    private mutating func flush(_ frames: Int, advance: Int, folder: URL,
                                emit: (AskFileReadResponse) throws -> Void) throws {
        let samples = Data(pending.prefix(frames * 4))
        let end = start + frames
        let progress = SemanticAudioProgress(next: Double(start + advance) / Double(Self.rate),
                                             covered: Double(end) / Double(Self.rate))
        if Self.isSilent(samples) {
            try emit(.init(more: true, audioProgress: progress))
        } else {
            let file = folder.appendingPathComponent("audio-\(start).wav")
            try SemanticMediaExtractor.wave(samples, to: file)
            try emit(.init(more: true, media: .init(kind: .audio, path: file.path,
                                                    time: Double(start) / Double(Self.rate),
                                                    endTime: Double(end) / Double(Self.rate)), audioProgress: progress))
        }
        covered = max(covered, end); start += advance; pending.removeFirst(advance * 4)
    }

    static func isSilent(_ samples: Data) -> Bool {
        samples.withUnsafeBytes { bytes in
            for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
                let bits = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let value = Float(bitPattern: UInt32(littleEndian: bits))
                if !value.isFinite || abs(value) > 1e-7 { return false }
            }
            return true
        }
    }
}

struct SemanticAudioProgress: Codable, Equatable {
    var next: Double
    var covered: Double

    init(next: Int, covered: Int) {
        self.next = Double(next) / Double(SemanticAudioWindows.rate)
        self.covered = Double(covered) / Double(SemanticAudioWindows.rate)
    }

    init(next: Double, covered: Double) {
        self.next = next; self.covered = covered
    }
}
