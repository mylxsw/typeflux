import Foundation
import Testing
@testable import Typeflux

@Suite("Semantic file change planning")
struct SemanticFileChangePlanTests {
    private let root = "/Users/test/Files"

    private func scope(includeLibrary: Bool = false) -> AskFileScope {
        var settings = AskLauncherSearchSettings()
        settings.fileRoots = [root]
        settings.excludedPaths = includeLibrary ? [] : [root + "/Library"]
        return AskFileScope(settings: settings, fullDiskAccess: true)
    }

    @Test func ignoredEventsCannotTriggerAnotherHomeScan() {
        let index = root + "/Library/Application Support/Typeflux/SemanticSearch"
        let events = [
            AskFileChange(path: index + "/semantic-files.sqlite-wal", rescan: false, isDirectory: false),
            AskFileChange(path: root + "/Library/report.pdf", rescan: false, isDirectory: false),
            AskFileChange(path: root + "/notes.json", rescan: false, isDirectory: false),
            AskFileChange(path: root + "/Documents", rescan: false, isDirectory: true),
            AskFileChange(path: root + "/.hidden.md", rescan: false, isDirectory: false)
        ]
        #expect(SemanticFileChangePlan.make(events, scope: scope(), indexDirectory: index) == .init())
        let excludedFolder = AskFileChange(path: root + "/node_modules", rescan: true,
                                           isDirectory: true, structureChanged: true)
        #expect(SemanticFileChangePlan.make([excludedFolder], scope: scope(), indexDirectory: index) == .init())
        let included = scope(includeLibrary: true)
        let ownDirectory = AskFileChange(path: index, rescan: false, isDirectory: true, structureChanged: true)
        #expect(SemanticFileChangePlan.make([ownDirectory], scope: included, indexDirectory: index) == .init())
    }

    @Test func supportedFilesAreTargetedAndStructuralChangesRequireFullScan() {
        let index = root + "/Library/Application Support/Typeflux/SemanticSearch"
        let document = root + "/Documents/report.md"
        let image = root + "/Pictures/photo.png"
        let files = [AskFileChange(path: document, rescan: false, isDirectory: false),
                     AskFileChange(path: image, rescan: false, isDirectory: false),
                     AskFileChange(path: image, rescan: false, isDirectory: false)]
        let plan = SemanticFileChangePlan.make(files, scope: scope(), indexDirectory: index)
        #expect(plan.files == [document, image] && !plan.fullScan)

        let folder = AskFileChange(path: root + "/New Folder", rescan: false,
                                   isDirectory: true, structureChanged: true)
        let structural = SemanticFileChangePlan.make(files + [folder], scope: scope(), indexDirectory: index)
        #expect(structural.fullScan && structural.files.isEmpty)
        let dropped = AskFileChange(path: root, rescan: true, isDirectory: true)
        #expect(SemanticFileChangePlan.make([dropped], scope: scope(), indexDirectory: index).fullScan)
    }
}
