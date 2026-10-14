import Foundation
import Testing
@testable import Typeflux

struct AskBrowserTabBatchTests {
    @Test func `property requests stay constant as tab count grows for every browser`() async throws {
        let runner = AskAutomationScriptRunner()
        for browser in AskSearchBrowser.allCases {
            var eventCounts: [Int] = []
            for count in [1, 200] {
                let script = """
                (function() {
                  var events = 0, rows = [];
                  for (var i = 0; i < \(count); i++) {
                    rows.push({id: i + 1, title: 'Tab ' + i, url: 'https://example.com/' + i});
                  }
                  var tabs = function() { throw new Error('Per-tab enumeration is forbidden'); };
                  function property(name) {
                    return function() { events++; return rows.map(function(row) { return row[name]; }); };
                  }
                  tabs.id = property('id'); tabs.title = property('title'); tabs.url = property('url');
                  Object.defineProperty(tabs, 'name', {value:property('title')});
                  var group = {name:function() { events++; return 'Personal'; },
                               title:function() { events++; return 'Work'; }, tabs:tabs};
                  var window = {id:function() { events++; return 7; }, tabs:tabs,
                                profiles:function() { events++; return [group]; },
                                spaces:function() { events++; return [group]; }};
                  var Application = function() {
                    return {running:function() { return true; },
                            windows:function() { events++; return [window]; }};
                  };
                  var output = \(AskBrowserTabScripts.list(browser))
                  return JSON.stringify({events:events, snapshot:JSON.parse(output)});
                })();
                """
                let result = try await runner.run(executablePath: "/usr/bin/osascript",
                                                  arguments: ["-l", "JavaScript", "-e", script], environment: nil,
                                                  currentDirectoryURL: nil)
                #expect(result.exitCode == 0)
                let object = try #require(try JSONSerialization
                    .jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
                let events = try #require(object["events"] as? Int)
                let snapshot = try #require(object["snapshot"] as? [String: Any])
                let data = try JSONSerialization.data(withJSONObject: snapshot)
                let entries = try AskBrowserTabScripts.parse(String(decoding: data, as: UTF8.self), browser: browser)
                    .entries
                #expect(entries.count == count, "Profile/space fallback must not duplicate tabs")
                #expect(entries.last?.title == "Tab \(count - 1)")
                #expect(entries.last?.target?.index == count)
                #expect(entries.first?.target?.windowID == "7")
                #expect(entries.first?.profile == (browser == .dia ? "Personal" : browser == .arc ? "Work" : ""))
                #expect(events <= 10)
                eventCounts.append(events)
            }
            #expect(eventCounts[0] == eventCounts[1], "Apple Events must scale with groups, not tabs")
        }
    }
}
