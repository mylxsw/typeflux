import Foundation

/// A new process owner inherits the strongest previous recovery restriction.
/// The marker prevents a later explicit user reset from importing stale state again.
enum FeatureHealthMigration {
    static func migrate(root: URL, owner: FeatureRole, files: FileManager = .default) throws {
        let destination = owner == .host ? root : root.appendingPathComponent("features/" + owner.rawValue)
        let marker = destination.appendingPathComponent("process-merge-v1.json")
        guard !files.fileExists(atPath: marker.path) else { return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        for module in owner.modules {
            let target = destination.appendingPathComponent(module.rawValue + ".json")
            let sources = [root.appendingPathComponent(module.rawValue + ".json")] + FeatureRole.allCases.map {
                root.appendingPathComponent("features/" + $0.rawValue + "/" + module.rawValue + ".json")
            }
            var merged: ModuleHealthStore.Record?
            for source in sources where files.fileExists(atPath: source.path) {
                let value: ModuleHealthStore.Record = if let attributes = try? files
                    .attributesOfItem(atPath: source.path),
                    attributes[.type] as? FileAttributeType == .typeRegular,
                    (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096,
                    let data = try? Data(contentsOf: source), let record = try? JSONDecoder().decode(
                        ModuleHealthStore.Record.self,
                        from: data
                    ),
                    record.version == 1, (0 ... 4).contains(record.attempts),
                    record.attempts < 4 || record.quarantined {
                    record
                } else {
                    .init(attempts: 4, quarantined: true)
                }
                merged = combine(merged, value)
            }
            if let merged {
                try JSONEncoder().encode(merged).write(to: target, options: .atomic)
            }
        }
        try Data("{\"version\":1}".utf8).write(to: marker, options: .atomic)
    }

    static func combine(_ previous: ModuleHealthStore.Record?, _ next: ModuleHealthStore.Record) -> ModuleHealthStore
        .Record {
        guard let previous else { return next }
        return .init(attempts: max(previous.attempts, next.attempts),
                     quarantined: previous.quarantined || next.quarantined,
                     automaticRecoveryUsed: previous.automaticRecoveryUsed == true || next
                         .automaticRecoveryUsed == true)
    }
}
