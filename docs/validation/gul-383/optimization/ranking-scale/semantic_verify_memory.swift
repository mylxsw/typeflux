import Foundation
import CryptoKit
let pooled = CommandLine.arguments[1] == "chunk"
func verify(_ path: String) throws -> String {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
    var hash = SHA256()
    if pooled {
        while true {
            let bytes = try autoreleasepool { () throws -> Int in
                guard let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return 0 }
                hash.update(data: data); return data.count
            }
            if bytes == 0 { break }
        }
    } else {
        while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
try autoreleasepool {
    for path in CommandLine.arguments.dropFirst(2) { print(try verify(path)) }
    // Keep the same synchronous job's outer pool alive while resident memory is sampled.
    Thread.sleep(forTimeInterval: 2)
}
