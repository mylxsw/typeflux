import Foundation

/// The file index on disk, so the next launch loads it instead of scanning again.
/// A small header (format, settings it was built for, the last FSEvents id) and the
/// tables as they are in memory. Anything unexpected reads as no snapshot.
enum AskFileSnapshot {
    static let magic: UInt32 = 0x5446_4658 // "TFFX"
    static let version: UInt32 = 1

    struct Contents {
        var state: AskFileIndexState
        var fingerprint: String
        var eventID: UInt64
    }

    static func encode(_ state: AskFileIndexState, fingerprint: String, eventID: UInt64) -> Data {
        let state = state.removed > 0 ? state.compacted() : state
        var data = Data()
        data.append(magic)
        data.append(version)
        data.append(UInt32(MemoryLayout<AskFileRecord>.stride))
        data.append(string: fingerprint)
        data.append(string: state.home)
        data.append(eventID)
        data.append(UInt32(state.directories.count))
        for directory in state.directories {
            data.append(string: directory.path)
            data.append(directory.parent)
            data.append(directory.record)
        }
        data.append(UInt32(state.records.count))
        state.records.withUnsafeBytes { data.append(contentsOf: $0) }
        for table in [state.keys, state.starts, state.names] {
            data.append(UInt32(table.count))
            data.append(contentsOf: table)
        }
        return data
    }

    static func decode(_ data: Data) -> Contents? {
        var reader = Reader(data: data)
        guard reader.read(UInt32.self) == magic, reader.read(UInt32.self) == version,
              reader.read(UInt32.self) == UInt32(MemoryLayout<AskFileRecord>.stride),
              let fingerprint = reader.readString(), let home = reader.readString(),
              let eventID = reader.read(UInt64.self), let directoryCount = reader.read(UInt32.self) else { return nil }
        var state = AskFileIndexState(home: home)
        for _ in 0 ..< directoryCount {
            guard let path = reader.readString(), let parent = reader.read(UInt32.self),
                  let record = reader.read(UInt32.self),
                  parent == AskFileDirectory.none || Int(parent) < state.directories.count else { return nil }
            state.directory(path, parent: parent, record: record)
        }
        guard state.directories.count == Int(directoryCount), let recordCount = reader.read(UInt32.self),
              let recordBytes = reader.bytes(Int(recordCount) * MemoryLayout<AskFileRecord>.stride) else { return nil }
        state.records = recordBytes.withUnsafeBytes { Array($0.bindMemory(to: AskFileRecord.self).prefix(Int(recordCount))) }
        var tables: [[UInt8]] = []
        for _ in 0 ..< 3 {
            guard let count = reader.read(UInt32.self), let bytes = reader.bytes(Int(count)) else { return nil }
            tables.append(Array(bytes))
        }
        state.keys = tables[0]
        state.starts = tables[1]
        state.names = tables[2]
        guard reader.atEnd, validate(state) else { return nil }
        for (index, record) in state.records.enumerated() {
            state.children[Int(record.directory)].append(UInt32(index))
            if record.hasPinyin { state.pinyin[UInt32(index)] = AskPinyinKey(state.name(of: record)) }
        }
        return Contents(state: state, fingerprint: fingerprint, eventID: eventID)
    }

    /// Every offset in range, so a damaged file cannot make the search read past a table.
    private static func validate(_ state: AskFileIndexState) -> Bool {
        state.records.allSatisfy { record in
            Int(record.keyOffset) + Int(record.keyLength) <= state.keys.count
                && Int(record.startsOffset) + Int(record.startsCount) <= state.starts.count
                && Int(record.nameOffset) + Int(record.nameLength) <= state.names.count
                && Int(record.directory) < state.directories.count
                && !record.isRemoved
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        var atEnd: Bool { offset == data.count }

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + count)
        }

        mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard let bytes = bytes(MemoryLayout<T>.size) else { return nil }
            return T(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }

        mutating func readString() -> String? {
            guard let count = read(UInt32.self), count < 1 << 20, let bytes = bytes(Int(count)) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(string: String) {
        let bytes = Array(string.utf8)
        append(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
}
