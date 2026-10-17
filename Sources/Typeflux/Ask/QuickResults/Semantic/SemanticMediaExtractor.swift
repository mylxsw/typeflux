import AVFoundation
import Darwin
import Foundation
import ImageIO

/// Runs in the disposable filesystem worker. All decoders read a private descriptor-checked snapshot.
enum SemanticMediaExtractor {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func extract(_ request: AskFileReadRequest, mounts: AskFileMounts,
                        recognize: (CGImage) throws -> [String] = SemanticPDFText.recognize,
                        emit: (AskFileReadResponse) throws -> Void) throws -> AskFileReadResponse {
        guard let scope = request.scope, scope.includes(request.path, isDirectory: false),
              SemanticFilePolicy.allows(request.path), SemanticMediaPriority.of(request.path) != .document,
              let scratch = request.scratch else { return .init(error: EACCES) }
        if let mount = mounts.blocking(request.path) {
            return .init(skippedMounts: [mount])
        }
        let folder = AskFileWorkerCommand.openDirectory(scratch, blocked: [])
        guard folder >= 0 else { return .init(error: EACCES) }
        defer { close(folder) }
        guard flock(folder, LOCK_EX | LOCK_NB) == 0 else { return .init(error: EBUSY) }
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
        let marker = "snapshot-version"
        let version = AskFileWorkerCommand.contentVersion(before)
        let markerURL = URL(fileURLWithPath: scratch).appendingPathComponent(marker)
        var copied = false
        var snapshotInfo = stat()
        let savedVersion: String? = {
            let descriptor = openat(folder, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= 512,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            guard Darwin.read(descriptor, &bytes, bytes.count) == bytes.count else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }()
        let reuse = savedVersion == version
            && fstatat(folder, name, &snapshotInfo, AT_SYMLINK_NOFOLLOW) == 0
            && (snapshotInfo.st_mode & S_IFMT) == S_IFREG && snapshotInfo.st_uid == geteuid()
            && snapshotInfo.st_mode & 0o077 == 0 && snapshotInfo.st_size == before.st_size
        if !reuse {
            unlinkat(folder, name, 0); unlinkat(folder, marker, 0)
            let target = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { return .init(error: errno) }
            defer { close(target) }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                let count = Darwin.read(source, &buffer, buffer.count)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count >= 0 else { return .init(error: errno) }
                if count == 0 {
                    break
                }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(target, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR {
                            continue
                        }
                        guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        offset += written
                    }
                }
                // Paced ACK supplies backpressure during snapshot creation, including very large media.
                try emit(.init(more: true))
            }
            guard fsync(target) == 0 else { return .init(error: errno) }
            copied = true
        }
        var after = stat()
        guard fstat(source, &after) == 0, AskFileWorkerCommand.contentVersion(after) == version
        else { return .init(error: EAGAIN) }
        if copied {
            try version.write(to: markerURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        }
        let resume = request.mediaCursor ?? .init()
        var ordinal = resume.nextOrdinal
        func frame(_ response: AskFileReadResponse) throws {
            var response = response
            if response.media != nil {
                response.mediaOrdinal = ordinal; ordinal += 1
            }
            try emit(response)
        }
        let folderURL = URL(fileURLWithPath: scratch)
        do {
            switch SemanticMediaPriority.of(request.path) {
            case .document: return .init(error: EINVAL)
            case .image:
                if !resume.imageDone {
                    let output = folderURL.appendingPathComponent("image.jpg")
                    try image(snapshot, to: output)
                    try frame(.init(more: true, media: .init(kind: .image, path: output.path)))
                }
                do {
                    if ["png", "jpg", "jpeg"].contains((request.path as NSString).pathExtension.lowercased()) {
                        try SemanticImageText.extract(snapshot, recognize: recognize, emit: frame)
                    }
                } catch { return .init(error: EIO, fileSize: Int64(after.st_size),
                                       modified: Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec)
                                           + Double(after.st_mtimespec.tv_nsec) / 1e9), mediaSegments: ordinal) }
            case .audio: try audio(AVURLAsset(url: snapshot), folder: folderURL, start: resume.audioUntil,
                                   cursor: resume, emit: frame)
            case .video:
                let asset = AVURLAsset(url: snapshot)
                try SemanticVideoFrames.extract(asset, folder: folderURL, cursor: resume.videoProgress, emit: frame)
                try audio(asset, folder: folderURL, start: resume.audioUntil, emit: frame)
            }
        } catch { return .init(error: EILSEQ) }
        let modified = Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec)
            + Double(after.st_mtimespec.tv_nsec) / 1e9)
        return .init(fileSize: Int64(after.st_size), modified: modified, mediaSegments: ordinal)
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

    static func write(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, "public.jpeg" as CFString, 1, nil
        )
        else { throw AskFileReadError.unavailable }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AskFileReadError.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    private static func audio(_ asset: AVAsset, folder: URL, start: Double = 0,
                              cursor: SemanticMediaCursor? = nil, emit: (AskFileReadResponse) throws -> Void) throws {
        var windows = try cursor.map { try SemanticAudioWindows(cursor: $0) }
        guard let track = asset.tracks(withMediaType: .audio).first else { return }
        if windows != nil, start >= asset.duration.seconds {
            try windows!.finish(folder: folder, emit: emit); return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw AskFileReadError.unavailable }
        reader.add(output)
        if start > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 16000),
                end: .positiveInfinity
            )
        }
        guard reader.startReading() else { throw AskFileReadError.unavailable }
        defer { reader.cancelReading() }
        let windowBytes = 30 * 16000 * 4
        var pending = Data(), offset = cursor == nil ? Int(start * 64000) : 0
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
            if windows != nil {
                try windows!.append(bytes, folder: folder, emit: emit)
            } else {
                pending.append(bytes)
                while pending.count >= windowBytes { try flush(windowBytes) }
            }
        }
        guard reader.status != .failed else { throw AskFileReadError.unavailable }
        if windows != nil { try windows!.finish(folder: folder, emit: emit) }
        if !pending.isEmpty { try flush(pending.count) }
    }

    static func wave(_ samples: Data, to path: URL) throws {
        var data = Data("RIFF".utf8)
        func number(_ value: some FixedWidthInteger) {
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        number(UInt32(samples.count + 36)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(3)); number(UInt16(1)); number(UInt32(16000))
        number(UInt32(64000)); number(UInt16(4)); number(UInt16(32))
        data.append(Data("data".utf8)); number(UInt32(samples.count)); data.append(samples)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
