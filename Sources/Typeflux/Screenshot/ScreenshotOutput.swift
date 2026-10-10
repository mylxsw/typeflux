import AppKit
import Foundation

/// Where a finished screenshot goes.
protocol ScreenshotOutputting {
    /// Puts the PNG on the clipboard. It is not marked as Typeflux's own, so the
    /// clipboard history keeps it like any other copied image.
    func copy(_ png: Data) -> Bool
    /// Puts text on the clipboard, such as a color picked with the loupe.
    func copy(text: String)
    /// Writes the PNG into `directory` under a new name and returns where it went.
    func save(_ png: Data, in directory: URL, date: Date) throws -> URL
}

struct ScreenshotOutput: ScreenshotOutputting {
    var pasteboard: () -> NSPasteboard = { .general }
    var fileManager: FileManager = .default

    func copy(_ png: Data) -> Bool {
        let board = pasteboard()
        board.clearContents()
        return board.setData(png, forType: .png)
    }

    func copy(text: String) {
        let board = pasteboard()
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func save(_ png: Data, in directory: URL, date: Date) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Self.availableURL(in: directory, baseName: Self.baseName(for: date)) {
            fileManager.fileExists(atPath: $0.path)
        }
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// "Typeflux Screenshot 2026-10-10 16.32.41" in the interface language.
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return L("screenshot.fileName", formatter.string(from: date))
    }

    /// `name.png`, or `name (2).png` and so on when that is taken.
    static func availableURL(in directory: URL, baseName: String, exists: (URL) -> Bool) -> URL {
        var url = directory.appendingPathComponent(baseName + ".png")
        var index = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(baseName) (\(index)).png")
            index += 1
        }
        return url
    }
}
