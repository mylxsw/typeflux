// swiftlint:disable line_length
import Foundation

/// JXA uses the browser's scripting dictionary without evaluating anything in a web page.
enum AskBrowserTabScripts {
    static func list(_ browser: AskSearchBrowser) -> String {
        let title = browser == .safari ? "tab.name()" : "tab.title()"
        let identifier = browser == .safari ? "String(index + 1)" : "String(tab.id())"
        let groups = switch browser {
        case .dia:
            "window.profiles().map(function(profile) { return {name:profile.name(), tabs:profile.tabs()}; }).concat([{name:'', tabs:window.tabs()}])"
        case .arc:
            "window.spaces().map(function(space) { return {name:space.title(), tabs:space.tabs()}; }).concat([{name:'', tabs:window.tabs()}])"
        default: "[{name:'', tabs:window.tabs()}]"
        }
        return """
        (function() {
          var app = Application(\(literal(browser.bundleID)));
          if (!app.running()) return JSON.stringify({tabs:[]});
          try {
            var result = [], seen = {};
            app.windows().forEach(function(window) {
              var windowID = String(window.id());
              var groups = \(groups);
              groups.forEach(function(group) {
                group.tabs.forEach(function(tab, index) {
                  var tabID = \(identifier), key = windowID + ':' + tabID;
                  if (seen[key]) return;
                  seen[key] = true;
                  result.push({windowID:windowID, tabID:tabID, index:index+1,
                               title:\(title) || '', url:tab.url() || '', profile:group.name || ''});
                });
              });
            });
            return JSON.stringify({tabs:result});
          } catch (error) { return JSON.stringify({error:Number(error.errorNumber || error.number || 0)}); }
        })();
        """
    }

    static func focus(_ target: AskBrowserTabTarget) -> String {
        let find: String
        let select: String
        switch target.browser {
        case .safari:
            find = "var tab = window.tabs()[\(max(0, target.index - 1))];"
            select = "window.currentTab = tab; window.index = 1;"
        case .chrome, .edge:
            find = "var tabs = window.tabs(), tab = tabs.filter(function(t) { return String(t.id()) === tabID; })[0];"
            select = "window.activeTabIndex = tabs.findIndex(function(t) { return String(t.id()) === tabID; }) + 1; window.index = 1;"
        case .dia:
            find = "var tabs = window.tabs(); window.profiles().forEach(function(p) { tabs = tabs.concat(p.tabs()); }); var tab = tabs.filter(function(t) { return String(t.id()) === tabID; })[0];"
            select = "app.focus(tab);"
        case .arc:
            find = "var tabs = window.tabs(); window.spaces().forEach(function(s) { tabs = tabs.concat(s.tabs()); }); var tab = tabs.filter(function(t) { return String(t.id()) === tabID; })[0];"
            select = "app.select(tab); window.index = 1;"
        }
        return """
        (function() {
          var app = Application(\(literal(target.browser.bundleID)));
          if (!app.running()) return 'missing';
          var tabID = \(literal(target.tabID));
          var window = app.windows().filter(function(w) { return String(w.id()) === \(literal(target.windowID)); })[0];
          if (!window) return 'missing';
          \(find)
          if (!tab || tab.url() !== \(literal(target.url))) return 'missing';
          try { window.minimized = false; } catch (_) {}
          \(select)
          app.activate();
          return 'focused';
        })();
        """
    }

    static func literal(_ text: String) -> String {
        AskLocalTools.javascriptLiteral(text)
    }

    static func parse(_ text: String, browser: AskSearchBrowser) throws -> AskBrowserSearchSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let error = object["error"] as? Int {
            return .init(issues: [.init(browser: browser, reason: error == -1743 ? .automation : .unreadable)])
        }
        guard let tabs = object["tabs"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let entries = tabs.compactMap { tab -> AskBrowserSearchEntry? in
            guard let windowID = tab["windowID"] as? String, let tabID = tab["tabID"] as? String,
                  let index = tab["index"] as? Int, index > 0, let url = tab["url"] as? String,
                  !url.isEmpty else { return nil }
            return .init(id: "tab:" + browser.id + ":" + windowID + ":" + tabID, kind: .tab, browser: browser,
                         title: tab["title"] as? String ?? url, url: url, profile: tab["profile"] as? String ?? "",
                         target: .init(browser: browser, windowID: windowID, tabID: tabID, index: index, url: url))
        }
        return .init(entries: entries)
    }
}
// swiftlint:enable line_length
