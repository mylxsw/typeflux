// Compile with the production AskDirectoryIterator.swift and -O. Uses temporary files only.
// This isolates enumeration/metadata costs; it does not measure Spotlight, AI inference or IPC.
import Darwin
import Foundation

enum AskFileRecord { enum Kind: UInt8 { case file, folder, package } }
enum AskFileCrawler {
    static func isPackage(_ path: String) -> Bool { (path as NSString).pathExtension == "app" }
    struct Entry: Equatable {
        var path: String
        var kind: AskFileRecord.Kind
        var modified: Date
    }
}
struct AskFileScope {}
enum AskFileWorkerCommand {
    // The pre-optimization scanner's per-entry metadata syscall, retained as the baseline.
    static func entry(_ name: String, parent: Int32, path: String, scope: AskFileScope) -> AskFileCrawler.Entry? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return .init(path: path, kind: info.st_mode & S_IFMT == S_IFDIR ? .folder : .file,
                     modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }
}

@main enum FileScanBenchmark {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-scan-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var directories: [String] = []
        for i in 0 ..< 50 {
            let directory = root.appendingPathComponent("folder-\(i)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories.append(directory.path)
            for j in 0 ..< 400 {
                let name = j.isMultiple(of: 5) ? "中文文档-\(j).txt" : "document-\(j).txt"
                try Data().write(to: directory.appendingPathComponent(name))
            }
        }
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func scan(_ strategy: AskDirectoryIterator.Strategy) throws -> [AskFileCrawler.Entry] {
            var entries: [AskFileCrawler.Entry] = []
            for path in directories {
                let openDirectory = { open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
                let iterator = try AskDirectoryIterator(descriptor: openDirectory(), strategy: strategy, reopen: openDirectory)
                while let item = try iterator.next() {
                    guard item.name != ".", item.name != ".." else { continue }
                    if let entry = item.entry(parent: iterator.descriptor, path: path + "/" + item.name, scope: .init()) {
                        entries.append(entry)
                    }
                }
            }
            return entries.sorted { $0.path < $1.path }
        }
        let baseline = try scan(.posix), bulk = try scan(.automatic)
        guard baseline == bulk, bulk.count == 20000 else {
            throw NSError(domain: "FileScanBenchmark.ResultMismatch", code: 1)
        }
        var results: [String: [(wall: Double, cpu: Double)]] = [:]
        for round in 0 ..< 6 {
            let order: [(String, AskDirectoryIterator.Strategy)] = round.isMultiple(of: 2)
                ? [("posix", .posix), ("bulk", .automatic)] : [("bulk", .automatic), ("posix", .posix)]
            for (name, strategy) in order {
                let start = ProcessInfo.processInfo.systemUptime, startCPU = cpu()
                _ = try scan(strategy)
                results[name, default: []].append((ProcessInfo.processInfo.systemUptime - start, cpu() - startCPU))
            }
        }
        for name in ["posix", "bulk"] {
            let samples = results[name]!
            let wall = samples.map(\.wall).sorted()[samples.count / 2]
            let cpu = samples.map(\.cpu).sorted()[samples.count / 2]
            let value: [String: Any] = ["strategy": name, "files": bulk.count, "rounds": samples.count,
                                       "median_wall_ms": wall * 1000, "median_cpu_ms": cpu * 1000]
            print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self))
        }
    }
}
