import SwiftUI

/// The editor owns the text. This panel shows its destination and a reviewable append.
struct AskNoteCaptureView: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var viewport: AskLauncherViewport
    var chrome: CGFloat
    var available: CGFloat?
    var natural: CGFloat
    var onSubmit: () -> Void
    var onOpen: (UUID) -> Void
    private var capture: AskNoteCaptureState {
        model.noteCapture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L(capture.choosingTarget ? "ask.noteCapture.choose" : "ask.noteCapture.destination"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(L("ask.noteCapture.characters", String(capture.body.count)))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if capture.choosingTarget {
                targetPicker
            } else {
                captureContent
            }
            footer
        }
        .padding(16)
        .frame(height: min(natural, viewport.resultsHeight(chrome: chrome, available: available, natural: natural)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.noteCapture.panel")
    }

    private var captureContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = capture.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                        .accessibilityIdentifier("ask.noteCapture.failure")
                }
                if !capture.hasContent, let saved = capture.saved {
                    receipt(saved)
                } else if capture.undone, !capture.hasContent {
                    Label(L("ask.noteCapture.undone"), systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 15, weight: .medium))
                } else {
                    destination
                    if let target = capture.target {
                        appendPreview(target)
                    } else if !capture.hasContent {
                        Text(L("ask.noteCapture.emptyDetail"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destination: some View {
        HStack(spacing: 12) {
            AskPluginItemIcon(icon: .feature("notes"), symbol: "note.text", filled: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.target?.title ?? (capture.hasContent ? AskNoteCaptureState.title(for: capture.body)
                        : L("ask.noteCapture.newNote")))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(L(capture.target == nil ? "ask.noteCapture.newDetail" : "ask.noteCapture.appendDetail"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(L(capture.target == nil ? "ask.noteCapture.append" : "ask.noteCapture.change")) {
                model.chooseNoteCaptureTarget()
            }
            .accessibilityIdentifier("ask.noteCapture.choose")
            if capture.target != nil {
                Button { model.selectNoteCaptureTarget(nil) } label: { Image(systemName: "xmark") }
                    .help(L("ask.noteCapture.newNote"))
                    .accessibilityLabel(L("ask.noteCapture.newNote"))
                    .accessibilityIdentifier("ask.noteCapture.new")
            }
        }
        .padding(12)
        .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 12))
        .disabled(capture.saving)
    }

    private func appendPreview(_ target: AskNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("ask.noteCapture.preview")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(target.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !target.body.isEmpty {
                Text((target.body.count > 160 ? "…" : "") + String(target.body.suffix(160)))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(capture.hasContent ? capture.body : L("ask.noteCapture.placeholder"))
                    .font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).foregroundStyle(AskTheme.accent)
            .background(AskTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityIdentifier("ask.noteCapture.preview")
    }

    private func receipt(_ note: AskNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 5) {
                Text(L(capture.savedWasAppend ? "ask.noteCapture.appended" : "ask.noteCapture.saved", note.title))
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .accessibilityIdentifier("ask.noteCapture.saved")
                Text(L("ask.noteCapture.continue")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private var targetPicker: some View {
        VStack(spacing: 8) {
            AskNoteCaptureSearchField(text: $model.noteCapture.targetQuery,
                                      onSelect: model.activateNoteCapture,
                                      onMove: model.moveNoteCaptureTarget,
                                      onCancel: model.cancelNoteCaptureTargetSearch)
                .frame(height: 26)
                .onChange(of: capture.targetQuery) { _ in model.searchNoteCaptureTargets() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if capture.searching {
                            ProgressView().controlSize(.small).padding(12)
                        } else if let failure = capture.searchFailure {
                            Text(failure).font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                            Button(L("ask.noteCapture.retry")) { model.searchNoteCaptureTargets() }
                                .accessibilityIdentifier("ask.noteCapture.retrySearch")
                        } else if capture.matches.isEmpty {
                            Text(L("ask.noteCapture.noTargets")).font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(Array(capture.matches.enumerated()), id: \.element.id) { index, note in
                            targetRow(note, index: index)
                        }
                    }
                }
                .onChange(of: capture.highlighted?.id) { id in
                    if let id {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .accessibilityIdentifier("ask.noteCapture.targets")
    }

    private func targetRow(_ note: AskNote, index: Int) -> some View {
        Button { model.selectNoteCaptureTarget(note) } label: {
            HStack(spacing: 10) {
                AskPluginItemIcon(icon: .symbol(note.pinned ? "pin.fill" : "note.text"),
                                  symbol: "note.text", filled: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(note.excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(index == capture.highlightedTarget ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).id(note.id)
        .accessibilityIdentifier("ask.noteCapture.target." + note.id.uuidString)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if capture.saving {
                ProgressView().controlSize(.small)
                Text(L("ask.noteCapture.working")).foregroundStyle(.secondary)
            } else if capture.choosingTarget {
                Button(L("common.cancel"), action: model.cancelNoteCaptureTargetSearch)
                    .accessibilityIdentifier("ask.noteCapture.cancel")
                Spacer()
                Button(L("ask.noteCapture.select"), action: model.activateNoteCapture)
                    .disabled(capture.searching || capture.highlighted == nil)
                    .accessibilityIdentifier("ask.noteCapture.select")
            } else {
                Button(L("ask.noteCapture.clear")) { model.clearNoteCapture() }
                    .disabled(!capture.hasContent && capture.saved == nil && capture.target == nil && !capture.undone)
                    .accessibilityIdentifier("ask.noteCapture.clear")
                if !capture.hasContent, let saved = capture.saved {
                    Button(L("ask.notes.openNote")) { onOpen(saved.id) }.accessibilityIdentifier("ask.noteCapture.open")
                    if capture.undo != nil {
                        Button(L("ask.noteCapture.undo")) { model.undoNoteCapture() }
                            .accessibilityIdentifier("ask.noteCapture.undo")
                    }
                }
                Spacer(minLength: 0)
                if capture.requiresReview {
                    Button(L("ask.noteCapture.reload")) { model.reloadNoteCaptureTarget() }
                        .accessibilityIdentifier("ask.noteCapture.reload")
                } else {
                    Button(L(capture.failure != nil ? "ask.noteCapture.retry"
                               : capture.target == nil ? "ask.noteCapture.save" : "ask.noteCapture.appendSave"),
                    action: onSubmit)
                        .disabled(!capture.canSave).accessibilityIdentifier("ask.noteCapture.save")
                }
            }
        }
        .font(.system(size: 12)).buttonStyle(.borderless)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(AskTheme.border).frame(height: 1) }
    }
}
