import SwiftUI
import WebKit

struct AskTerminalAccess {
    var status: (AskProcessRef) throws -> AskProjectTerminalReceipt = { _ in throw AskProjectRuntimeError.unknownLease }
    var stop: (AskProcessRef) throws -> Void = { _ in throw AskProjectRuntimeError.unknownLease }
    var preview: (AskProcessRef, String, [String]) throws -> AskDevelopmentPreview = { _, _, _ in
        throw AskArtifactError.denied
    }
}

extension EnvironmentValues {
    @Entry var askTerminalAccess: AskTerminalAccess = .init()
}

struct AskProjectTerminalCard: View {
    let receipt: AskProjectTerminalReceipt
    @Environment(\.askTerminalAccess) private var access
    @State private var current: AskProjectTerminalReceipt?
    @State private var error: String?
    @State private var preview: AskDevelopmentPreview?

    private var value: AskProjectTerminalReceipt {
        current ?? receipt
    }

    private var active: Bool {
        [.starting, .running, .ready].contains(value.status.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("ask.terminal.title"), systemImage: "terminal")
                Spacer()
                Text(value.status.state.rawValue).font(.system(.caption, design: .monospaced))
                Button(L("ask.terminal.stop")) {
                    do {
                        try access.stop(receipt.process)
                        current = try access.status(receipt.process)
                    } catch { self.error = error.localizedDescription }
                }.disabled(!active)
            }
            if let exit = value.status.exitCode {
                Text(L("ask.terminal.exit", String(exit)))
            }
            if value.lostBytes > 0 {
                Text(L("ask.terminal.lost", String(value.lostBytes))).foregroundStyle(StudioTheme.danger)
            }
            if value.truncated {
                Text(L("ask.terminal.truncated"))
            }
            if value.status.persistenceFailed {
                Text(L("ask.terminal.logFailed")).foregroundStyle(StudioTheme.danger)
            }
            ScrollView { Text(value.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            if let entry = receipt.previewEntry, let resources = receipt.previewResources {
                Button(L("ask.preview")) {
                    do {
                        preview = try access.preview(receipt.process, entry, resources)
                    } catch { self.error = error.localizedDescription }
                }.disabled(value.status.state != .ready)
            }
            if let error {
                Text(error).foregroundStyle(StudioTheme.danger)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(AskTheme.monoSurface, in: RoundedRectangle(cornerRadius: 10))
        .task {
            do {
                repeat {
                    current = try access.status(receipt.process)
                    if !active, value.nextCursor >= value.status.outputBytes {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } while !Task.isCancelled
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: {
            if !$0 {
                preview?.close(); preview = nil
            }
        })) {
            if let preview {
                VStack {
                    HStack {
                        Text(L("ask.preview")); Spacer(); Button(L("ask.artifact.close")) {
                            preview.close(); self.preview = nil
                        }
                    }
                    AskDevelopmentWebView(preview: preview, error: $error)
                    if let error {
                        Text(error).foregroundStyle(StudioTheme.danger)
                    }
                }.padding(20).frame(width: 760, height: 560)
            }
        }
    }
}

private struct AskDevelopmentWebView: NSViewRepresentable {
    let preview: AskDevelopmentPreview
    @Binding var error: String?
    @MainActor final class Coordinator {
        let host = AskPreviewHost()
        var loading: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(), host = context.coordinator.host
        host.report = { error = $0 }
        context.coordinator.loading = Task { @MainActor in
            do {
                let view = try await host.open(.developmentService(
                    process: preview.lease.reference,
                    address: preview.address
                ),
                enabled: true,
                development: preview) { _ in throw AskArtifactError.denied }
                view.frame = container.bounds; view.autoresizingMask = [.width, .height]; container.addSubview(view)
            } catch { self.error = error.localizedDescription }
        }
        return container
    }

    func updateNSView(_: NSView, context _: Context) {}
    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.loading?.cancel(); coordinator.host.close()
    }
}
