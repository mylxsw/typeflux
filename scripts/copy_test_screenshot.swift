import AppKit

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
exit(pasteboard.setData(data, forType: .png) ? 0 : 1)
