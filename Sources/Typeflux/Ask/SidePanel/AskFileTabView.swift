import AppKit
import PDFKit
import SwiftUI
import WebKit

/// A file previewed in the side panel, with its toolbar: preview or source, reload, and
/// the menu for opening it outside Typeflux.
struct AskFileTabView: View {
    @ObservedObject var tab: AskFileTab
    var roots: () -> [String]
    var onError: (String) -> Void
    /// Scrolls the conversation to the message the file came with; nil when unknown.
    var onLocate: (() -> Void)?
    /// Adds the file to the composer as context for the next message; nil hides it.
    var onReference: (() -> Void)?
    var actions = AskFileExternalActions()
    @State private var content: AskSidePanelFileContent?
    @State private var htmlError: String?
    @State private var menuHovered = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { shortcuts }
        .task(id: tab.revision) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.sidePanel.fileTab")
    }

    private func load() async {
        let target = tab.target, kind = tab.kind, roots = roots()
        htmlError = nil
        let loaded = await Task.detached(priority: .userInitiated) {
            AskSidePanelFileLoader.load(target, kind: kind, roots: roots)
        }.value
        guard !Task.isCancelled else { return }
        content = loaded
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: AskFileIcon.symbol(for: tab.kind))
                    .foregroundStyle(TFColors.textTertiary)
                Text(tab.target.relativePath)
                    .font(.system(size: 11.5))
                    .foregroundStyle(TFColors.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(tab.target.relativePath)
            }
            HStack(spacing: 4) {
                if tab.kind.hasSource {
                    TFSegmentedControl(options: [
                        TFOption(false, L("ask.sidePanel.file.preview")),
                        TFOption(true, L("ask.sidePanel.file.source"))
                    ], selection: $tab.showsSource, size: .regular)
                    .accessibilityIdentifier("ask.sidePanel.file.mode")
                }
                Spacer(minLength: 8)
                if let onLocate {
                    toolbarButton("ask.sidePanel.locateMessage", symbol: "text.bubble", action: onLocate)
                        .accessibilityIdentifier("ask.sidePanel.file.locate")
                }
                if let onReference {
                    toolbarButton("ask.sidePanel.reference", symbol: "text.badge.plus", action: onReference)
                        .accessibilityIdentifier("ask.sidePanel.file.reference")
                }
                toolbarButton("ask.sidePanel.file.reload", symbol: "arrow.clockwise") { tab.reload() }
                Menu {
                    AskFileOpenMenuItems(file: tab.target.url, actions: actions, onReference: onReference,
                                         onError: onError)
                } label: {
                    TFButtonChrome(kind: .plain, destructive: false, size: .regular, iconOnly: true,
                                   isPressed: false, hoverOverride: menuHovered) {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { menuHovered = $0 }
                .help(L("ask.sidePanel.open.menu"))
                .accessibilityLabel(L("ask.sidePanel.open.menu"))
                .accessibilityIdentifier("ask.sidePanel.file.more")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toolbarButton(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        TFButton(title: L(key), systemImage: symbol, kind: .plain, size: .regular,
                 iconOnly: true, action: action)
    }

    /// Reveal in Finder works while the tab shows.
    private var shortcuts: some View {
        ZStack {
            Button("") { actions.revealInFinder(tab.target.url) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Preview

    @ViewBuilder private var preview: some View {
        switch content {
        case nil:
            ProgressView().controlSize(.small)
        case let .failure(message):
            messageView(symbol: "exclamationmark.triangle", text: message)
        case .unsupported:
            unsupported
        case let .text(text, truncated):
            AskLineNumberedText(text: text, truncated: truncated)
        case let .markdown(text, truncated):
            if tab.showsSource {
                AskLineNumberedText(text: text, truncated: truncated)
            } else {
                AskTopLeadingScroll(axes: .vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if truncated { truncationNote }
                        AskMermaidTranscript(text: text, isStreaming: false, onAsk: nil, onSaveNote: nil)
                    }
                    .padding(16)
                }
            }
        case let .csv(table, source):
            if tab.showsSource {
                AskLineNumberedText(text: source, truncated: false)
            } else {
                AskCSVTableView(table: table)
            }
        case let .html(bundle, source):
            if tab.showsSource {
                AskLineNumberedText(text: source, truncated: false)
            } else {
                VStack(spacing: 0) {
                    if let htmlError {
                        AskFilePreviewNotice(message: htmlError)
                            .padding(8)
                    }
                    AskFileHTMLView(bundle: bundle, validate: { [target = tab.target, roots] in
                        try AskSidePanelFileAccess.check(target, roots: roots())
                    }, error: $htmlError)
                        .id(bundle.manifest.ref.id)
                }
            }
        case let .image(image):
            AskTopLeadingScroll(axes: [.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(16)
            }
            .accessibilityLabel(tab.name)
        case let .pdf(data):
            AskPDFView(data: data)
        }
    }

    private var truncationNote: some View {
        Text(L("ask.sidePanel.file.truncated")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
    }

    @ViewBuilder private var unsupported: some View {
        if AskSidePanelQuickLook.previews((tab.target.relativePath as NSString).pathExtension) {
            VStack(spacing: 0) {
                AskSidePanelQuickLookView(url: tab.target.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("ask.sidePanel.file.quickLook")
                Rectangle().fill(AskTheme.separator).frame(height: 1)
                HStack(spacing: 8) {
                    Text(L("ask.sidePanel.file.quickLook")).font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    openButtons
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
            }
        } else {
            VStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: tab.target.path))
                    .resizable().frame(width: 64, height: 64)
                Text(L("ask.sidePanel.file.unsupported")).font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                openButtons
            }
            .padding(24)
        }
    }

    private var openButtons: some View {
        let app = actions.defaultApplication(for: tab.target.url)
        return HStack(spacing: 8) {
            Button(app.map { L("ask.sidePanel.open.withApp", $0.name) } ?? L("ask.sidePanel.open.default")) {
                actions.openWithDefaultApplication(tab.target.url)
            }
            .buttonStyle(.borderedProminent)
            Button(L("ask.sidePanel.revealInFinder")) { actions.revealInFinder(tab.target.url) }
        }
        .controlSize(.small)
    }

    private func messageView(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
            Text(text).font(.system(size: 12.5)).multilineTextAlignment(.center)
        }
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(24)
    }
}

/// Code and plain text with line numbers.
struct AskLineNumberedText: View {
    static let lineLimit = 20000
    let text: String
    let truncated: Bool

    var body: some View {
        let lines = Self.lines(text)
        let width = CGFloat(String(lines.count).count) * 7.5 + 10
        AskTopLeadingScroll(axes: [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if truncated || lines.count >= Self.lineLimit {
                    Text(L("ask.sidePanel.file.truncated"))
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .padding(.bottom, 6)
                }
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .foregroundStyle(StudioTheme.textTertiary)
                            .frame(width: width, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(lines[index].isEmpty ? " " : lines[index])
                            .foregroundStyle(StudioTheme.textPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 1)
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("ask.sidePanel.file.text")
    }

    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, stop in
            lines.append(line)
            if lines.count >= lineLimit { stop = true }
        }
        return lines
    }
}

/// The parsed rows of a CSV file; the first row is the header.
struct AskCSVTableView: View {
    let table: AskCSVTable

    var body: some View {
        let columns = table.columnCount
        AskTopLeadingScroll(axes: [.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if table.truncated {
                    Text(L("ask.sidePanel.file.csvTruncated", table.rows.count))
                        .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                        .padding(.bottom, 6)
                }
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(table.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(0 ..< columns, id: \.self) { column in
                                let cells = table.rows[row]
                                Text(column < cells.count ? cells[column] : "")
                                    .font(.system(size: 12, weight: row == 0 ? .semibold : .regular))
                                    .lineLimit(3)
                                    .frame(minWidth: 60, maxWidth: 260, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(row == 0 ? AskTheme.controlSurface : .clear)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(AskTheme.separator).frame(height: 0.5)
                                    }
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("ask.sidePanel.file.csv")
    }
}

/// Content pinned to the top-leading corner: a scroll view centres content smaller than itself.
struct AskTopLeadingScroll<Content: View>: View {
    var axes: Axis.Set
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(axes) {
                content.frame(minWidth: axes.contains(.horizontal) ? geometry.size.width : nil,
                              maxWidth: axes.contains(.horizontal) ? nil : .infinity,
                              minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }
}

/// A PDF read into memory, so the view never reopens the path.
private struct AskPDFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context _: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_: PDFView, context _: Context) {}
}

/// A local HTML file in the artifact preview sandbox: no network, bounded local web assets, and
/// the page closes when the file stops being allowed.
struct AskFileHTMLView: NSViewRepresentable {
    let bundle: AskArtifactBundle
    let validate: () throws -> Void
    @Binding var error: String?

    @MainActor final class Coordinator {
        let host = AskPreviewHost()
        var loading: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let host = context.coordinator.host
        let bundle = bundle, validate = validate
        host.report = { error = $0 }
        context.coordinator.loading = Task { @MainActor in
            do {
                let view = try await host.open(.artifact(bundle.manifest.ref), enabled: true,
                                               validateAccess: { _ in try validate() },
                                               load: { _ in bundle })
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
        return container
    }

    func updateNSView(_: NSView, context _: Context) {}

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
        coordinator.host.close()
    }
}
