import AVFoundation
import Darwin
import Foundation
import ImageIO

/// Runs in the disposable filesystem worker. All decoders read a private descriptor-checked snapshot.
enum SemanticMediaExtractor {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func extract(_ request: AskFileReadRequest, mounts: AskFileMounts,
                        emit: (AskFileReadResponse) throws -> Void) throws -> AskFileReadResponse {
        guard let scope = request.scope, scope.includes(request.path, isDirectory: false),
              SemanticFilePolicy.allows(request.path), SemanticMediaPriority.of(request.path) != .document,
              let scratch = request.scratch else { return .init(error: EACCES) }
        if let mount = mounts.blocking(request.path) { return .init(skippedMounts: [mount]) }
        let folder = AskFileWorkerCommand.openDirectory(scratch, blocked: [])
        guard folder >= 0 else { return .init(error: EACCES) }
        defer { close(folder) }
        var directory = stat()
        guard fstat(folder, &directory) == 0, directory.st_uid == geteuid(), directory.st_mode & 0o077 == 0
        else { return .init(error: EACCES) }
        let parent = AskFileWorkerCommand.openDirectory((request.path as NSString).deletingLastPathComponent,
                                                        blocked: scope.blocked + mounts.excluded)
        guard parent >= 0 else { return .init(error: errno) }
        defer { close(parent) }
        var metadata = stat()
        guard fstatat(parent, (request.path as NSString).lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              AskFilePreviewPolicy.isResidentRegularFile(mode: metadata.st_mode, flags: metadata.st_flags)
        else { return .init(error: EINVAL) }
        let source = openat(parent, (request.path as NSString).lastPathComponent,
                            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { return .init(error: errno) }
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0,
              before.st_ino == metadata.st_ino, before.st_dev == metadata.st_dev,
              AskFilePreviewPolicy.isResidentRegularFile(mode: before.st_mode, flags: before.st_flags)
        else { return .init(error: EINVAL) }
        let name = "source." + (request.path as NSString).pathExtension.lowercased()
        let snapshot = URL(fileURLWithPath: scratch).appendingPathComponent(name)
        let target = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard target >= 0 else { return .init(error: errno) }
        defer { close(target) }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var heartbeat = ProcessInfo.processInfo.systemUptime
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .init(error: errno) }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(target, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            if ProcessInfo.processInfo.systemUptime - heartbeat >= 0.1 {
                try emit(.init(more: true)); heartbeat = ProcessInfo.processInfo.systemUptime
            }
        }
        var after = stat()
        guard fstat(source, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return .init(error: EAGAIN) }
        let folderURL = URL(fileURLWithPath: scratch)
        do {
            switch SemanticMediaPriority.of(request.path) {
            case .document: return .init(error: EINVAL)
            case .image:
                let output = folderURL.appendingPathComponent("image.jpg")
                try image(snapshot, to: output)
                try emit(.init(more: true, media: .init(kind: .image, path: output.path)))
            case .audio: try audio(AVURLAsset(url: snapshot), folder: folderURL, emit: emit)
            case .video:
                let asset = AVURLAsset(url: snapshot)
                try video(asset, folder: folderURL, emit: emit)
                try audio(asset, folder: folderURL, emit: emit)
            }
        } catch { return .init(error: EILSEQ) }
        let modified = Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec)
            + Double(after.st_mtimespec.tv_nsec) / 1e9)
        return .init(fileSize: Int64(after.st_size), modified: modified)
    }

    static func image(_ url: URL, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1008
              ] as CFDictionary) else { throw AskFileReadError.unavailable }
        try write(raster, to: output)
    }

    private static func write(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, "public.jpeg" as CFString, 1, nil
        )
        else { throw AskFileReadError.unavailable }
        CGImageDestinationAddImage(destination, image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AskFileReadError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    private static func audio(_ asset: AVAsset, folder: URL,
                              emit: (AskFileReadResponse) throws -> Void) throws {
        guard let track = asset.tracks(withMediaType: .audio).first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw AskFileReadError.unavailable }
        reader.add(output)
        guard reader.startReading() else { throw AskFileReadError.unavailable }
        defer { reader.cancelReading() }
        let windowBytes = 30 * 16000 * 4
        var pending = Data(), offset = 0
        func flush(_ count: Int) throws {
            let path = folder.appendingPathComponent("audio-\(offset).wav")
            try wave(Data(pending.prefix(count)), to: path)
            try emit(.init(more: true, media: .init(kind: .audio, path: path.path,
                                                  time: Double(offset) / 64000,
                                                  endTime: Double(offset + count) / 64000)))
            offset += count; pending.removeFirst(count)
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw AskFileReadError.unavailable }
            pending.append(bytes)
            while pending.count >= windowBytes { try flush(windowBytes) }
        }
        guard reader.status != .failed else { throw AskFileReadError.unavailable }
        if !pending.isEmpty { try flush(pending.count) }
    }

    static func wave(_ samples: Data, to path: URL) throws {
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        number(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(3)); number(UInt16(1)); number(UInt32(16000))
        number(UInt32(64000)); number(UInt16(4)); number(UInt16(32))
        data.append(Data("data".utf8)); number(UInt32(samples.count)); data.append(samples)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func video(_ asset: AVAsset, folder: URL,
                              emit: (AskFileReadResponse) throws -> Void) throws {
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, duration < Double(Int.max),
              !asset.tracks(withMediaType: .video).isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1008, height: 1008)
        defer { generator.cancelAllCGImageGeneration() }
        for time in stride(from: 0.0, to: duration, by: 10) {
            try emit(.init(more: true))
            let frame = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let path = folder.appendingPathComponent("frame-\(Int(time)).jpg")
            try write(frame, to: path)
            try emit(.init(more: true, media: .init(kind: .image, path: path.path, time: time, endTime: time)))
        }
    }
}
