import Foundation

protocol AppleProductivityCreating: Sendable {
    func create(kind: AskAppleProductivityPlugin.Kind, title: String, body: String, due: Date?) async throws -> String
}

/// Arguments are passed as data, never interpolated into AppleScript source or a shell command.
actor AppleProductivityService: AppleProductivityCreating {
    private let runner: any ProcessCommandRunning

    init(runner: any ProcessCommandRunning = ProcessCommandRunner(timeout: 65, outputLimit: 16000)) {
        self.runner = runner
    }

    func create(kind: AskAppleProductivityPlugin.Kind, title: String, body: String, due: Date?) async throws -> String {
        try Task.checkCancellation()
        var arguments = [title, kind == .notes ? Self.html(title: title, body: body) : body]
        if let due {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
            arguments += [parts.year!, parts.month!, parts.day!, parts.hour! * 3600 + parts.minute! * 60 + parts.second!]
                .map(String.init)
        }
        let result = try await runner.run(executablePath: "/usr/bin/osascript",
                                          arguments: ["-e", Self.script(for: kind), "--"] + arguments)
        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !id.isEmpty else { throw Failure.noReceipt }
        return id
    }

    static func html(title: String, body: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        return "<div><b>\(escape(title))</b></div>" + (body.isEmpty ? "" : "<div>\(escape(body))</div>")
    }

    static func script(for kind: AskAppleProductivityPlugin.Kind) -> String {
        let create: String
        switch kind {
        case .notes:
            create = """
            tell application id "com.apple.Notes"
                set targetAccount to default account
                set targetFolder to default folder of targetAccount
                set createdItem to make new note at targetFolder with properties {name:itemTitle, body:itemBody}
                return id of createdItem
            end tell
            """
        case .reminders:
            create = """
            tell application id "com.apple.reminders"
                set targetList to default list
                if (count of argv) is 6 then
                    set alarmDate to current date
                    set day of alarmDate to 1
                    set year of alarmDate to (item 3 of argv as integer)
                    set month of alarmDate to (item 4 of argv as integer)
                    set day of alarmDate to (item 5 of argv as integer)
                    set time of alarmDate to (item 6 of argv as integer)
                    set createdItem to make new reminder at targetList with properties {name:itemTitle, body:itemBody, due date:alarmDate, remind me date:alarmDate}
                else
                    set createdItem to make new reminder at targetList with properties {name:itemTitle, body:itemBody}
                end if
                return id of createdItem
            end tell
            """
        }
        return """
        on run argv
            set itemTitle to item 1 of argv
            set itemBody to item 2 of argv
            with timeout of 60 seconds
                \(create)
            end timeout
        end run
        """
    }

    enum Failure: Error { case noReceipt }
}
