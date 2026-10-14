import AppKit

extension ScreenRecordingWindowController {
    func windowShouldClose(_: NSWindow) -> Bool {
        requestClose(); return false
    }

    func requestClose() {
        guard let model, ![.starting, .stopping].contains(model.state) else { return }
        if model.state == .exporting {
            model.cancelExport(); return
        }
        if [.recording, .paused, .preview].contains(model.state) {
            let alert = NSAlert()
            alert.messageText = L("recording.discardQuestion"); alert.informativeText = L("recording.discardHint")
            alert.addButton(withTitle: L(model.state == .preview ? "recording.continueEditing" : "recording.keep"))
            alert.addButton(withTitle: L("recording.discard"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.cancel()
    }

    func chooseDirectory() {
        guard let model, [.setup, .preview].contains(model.state) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = model.destinationDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
        }
    }

    func saveAs() {
        guard let model, model.canExport else { return }
        let panel = NSSavePanel()
        panel.directoryURL = model.destinationDirectory
        panel.nameFieldStringValue = ScreenRecordingLayout.fileName(model.fileName) + "." + model.options.format
            .rawValue
        panel.allowedContentTypes = model.options.format == .gif ? [.gif] : [.mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url {
            model.export(
                directory: url.deletingLastPathComponent(),
                destinationURL: url
            )
        }
    }

    func indicator(_ title: String?) {
        guard let title else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil; return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self; item.button?.action = #selector(stop)
            statusItem = item
        }
        statusItem?.button?.window?.identifier = Self.identifier
        let color = title.hasPrefix("Ⅱ") ? NSColor.systemOrange : .systemRed
        statusItem?.button?.wantsLayer = true
        statusItem?.button?.layer?.cornerRadius = 5
        statusItem?.button?.layer?.backgroundColor = color.cgColor
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: " ■ " + title.replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "Ⅱ ", with: ""),
            attributes: [
                .foregroundColor: title.hasPrefix("Ⅱ") ? NSColor.black : NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: 12,
                    weight: .semibold
                )
            ]
        )
    }

    @objc func stop() {
        model?.stop()
    }

    func offerRecovery(_ model: ScreenRecordingCoordinator) {
        guard let source = model.findRecoverableSources().first else { return }
        toast.showRecovery(
            source,
            open: { [weak self] in self?.show(model); model.recover(source) },
            discard: { [weak self] in
                model.discardRecovered(source); self?.offerRecovery(model)
            }
        )
    }
}
