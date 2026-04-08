import AppKit
import SwiftUI

@MainActor
final class AgentJobsWindowController: NSObject {
    fileprivate final class Model: ObservableObject {
        @Published private(set) var jobs: [AgentJob] = []
        @Published var selectedJobID: UUID?
        @Published private(set) var isLoading = false

        private let jobStore: AgentJobStore
        private let executionRegistry: AgentExecutionRegistry

        init(jobStore: AgentJobStore, executionRegistry: AgentExecutionRegistry) {
            self.jobStore = jobStore
            self.executionRegistry = executionRegistry
        }

        var selectedJob: AgentJob? {
            guard let selectedJobID else { return nil }
            return jobs.first { $0.id == selectedJobID }
        }

        var runningJobs: [AgentJob] {
            jobs.filter { $0.status == .running }
        }

        func showList() {
            selectedJobID = nil
            refresh()
        }

        func showJob(_ jobID: UUID) {
            selectedJobID = jobID
            refresh()
        }

        func refresh() {
            isLoading = true
            Task {
                let jobs = await (try? jobStore.list(limit: 200, offset: 0)) ?? []
                await MainActor.run {
                    self.jobs = jobs
                    self.isLoading = false
                    if let selectedJobID, jobs.contains(where: { $0.id == selectedJobID }) == false {
                        self.selectedJobID = nil
                    }
                }
            }
        }

        func cancel(jobID: UUID) {
            Task {
                await executionRegistry.cancel(jobID: jobID)
            }
        }
    }

    private let settingsStore: SettingsStore
    private let model: Model

    private var window: NSWindow?
    private var hostingView: NSHostingView<AgentJobsWindowView>?
    private var languageObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?

    init(
        settingsStore: SettingsStore,
        jobStore: AgentJobStore,
        executionRegistry: AgentExecutionRegistry,
    ) {
        self.settingsStore = settingsStore
        model = Model(jobStore: jobStore, executionRegistry: executionRegistry)
        super.init()

        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window?.title = L("agent.jobs.title")
                self?.reloadRootView()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: settingsStore,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window else { return }
                applyAppearance(to: window)
                reloadRootView()
            }
        }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .agentJobStoreDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.refresh()
            }
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    func showJobsList() {
        ensureWindow()
        model.showList()
        presentWindow()
    }

    func showJob(id: UUID) {
        ensureWindow()
        model.showJob(id)
        presentWindow()
    }

    private func presentWindow() {
        guard let window else { return }
        reloadRootView()
        applyAppearance(to: window)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let rootView = AgentJobsWindowView(model: model, appearanceMode: settingsStore.appearanceMode)
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = L("agent.jobs.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        window.contentView = hostingView
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
        window.delegate = self
        applyAppearance(to: window)

        self.hostingView = hostingView
        self.window = window
    }

    private func reloadRootView() {
        hostingView?.rootView = AgentJobsWindowView(model: model, appearanceMode: settingsStore.appearanceMode)
    }

    private func applyAppearance(to window: NSWindow) {
        window.appearance = AppAppearance.nsAppearance(for: settingsStore.appearanceMode)
        window.backgroundColor = NSColor(StudioTheme.windowBackground)
    }
}

extension AgentJobsWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        window?.orderOut(nil)
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }
}

private struct AgentJobsWindowView: View {
    @ObservedObject var model: AgentJobsWindowController.Model
    let appearanceMode: AppearanceMode

    var body: some View {
        ZStack {
            StudioTheme.windowBackground

            if let job = model.selectedJob {
                AgentJobDetailPane(
                    job: job,
                    appearanceMode: appearanceMode,
                    onBack: model.showList,
                    onCancel: { model.cancel(jobID: job.id) },
                )
            } else {
                AgentJobsListPane(
                    jobs: model.jobs,
                    isLoading: model.isLoading,
                    onOpenJob: { model.showJob($0.id) },
                )
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

private struct AgentJobsListPane: View {
    let jobs: [AgentJob]
    let isLoading: Bool
    let onOpenJob: (AgentJob) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("agent.jobs.title"))
                    .font(.studioDisplay(StudioTheme.Typography.subsectionTitle, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                if !jobs.isEmpty {
                    Text(L("menu.agentTasks.runningCount", jobs.count(where: { $0.status == .running })))
                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                        .foregroundStyle(StudioTheme.textSecondary)
                }
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.top, StudioTheme.Spacing.large)
            .padding(.bottom, StudioTheme.Spacing.medium)

            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

            if isLoading, jobs.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if jobs.isEmpty {
                Spacer()
                VStack(spacing: StudioTheme.Spacing.medium) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(StudioTheme.textTertiary)
                    Text(L("agent.jobs.empty"))
                        .font(.studioBody(StudioTheme.Typography.body))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, StudioTheme.Spacing.xLarge)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobs) { job in
                            Button {
                                onOpenJob(job)
                            } label: {
                                HStack(alignment: .top, spacing: StudioTheme.Spacing.medium) {
                                    Circle()
                                        .fill(jobStatusColor(job.status))
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 6)

                                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                                        Text(job.displayTitle)
                                            .font(.studioBody(StudioTheme.Typography.bodyLarge, weight: .medium))
                                            .foregroundStyle(StudioTheme.textPrimary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        HStack(spacing: StudioTheme.Spacing.small) {
                                            Text(jobTimeText(job.createdAt))
                                            if let duration = job.formattedDuration {
                                                Text("·")
                                                Text(duration)
                                            }
                                            if job.totalToolCalls > 0 {
                                                Text("·")
                                                Text(L("agent.jobs.toolCalls", job.totalToolCalls))
                                            }
                                        }
                                        .font(.studioBody(StudioTheme.Typography.bodySmall))
                                        .foregroundStyle(StudioTheme.textTertiary)
                                    }

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textTertiary)
                                }
                                .padding(.horizontal, StudioTheme.Spacing.large)
                                .padding(.vertical, StudioTheme.Spacing.medium)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if job.id != jobs.last?.id {
                                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AgentJobDetailPane: View {
    private enum ResultViewMode: String, Hashable {
        case plainText
        case markdown
    }

    let job: AgentJob
    let appearanceMode: AppearanceMode
    let onBack: () -> Void
    let onCancel: () -> Void

    @State private var resultViewMode: ResultViewMode = .plainText

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: StudioTheme.Spacing.xSmall) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: StudioTheme.Typography.iconSmall, weight: .semibold))
                            Text(L("agent.jobs.title"))
                                .font(.studioBody(StudioTheme.Typography.body))
                        }
                        .foregroundStyle(StudioTheme.accent)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if job.status == .running {
                        StudioButton(
                            title: L("agent.jobs.cancel"),
                            systemImage: "stop.circle",
                            variant: .secondary,
                            action: onCancel,
                        )
                    }
                }

                Text(job.displayTitle)
                    .font(.studioBody(StudioTheme.Typography.body, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 160)
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.top, StudioTheme.Spacing.large)
            .padding(.bottom, StudioTheme.Spacing.medium)

            HStack(spacing: StudioTheme.Spacing.small) {
                Circle()
                    .fill(jobStatusColor(job.status))
                    .frame(width: 10, height: 10)

                Text(jobDetailTimeText(job.createdAt))
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)

                StudioPill(title: agentStatusTitle(job.status))

                if let duration = job.formattedDuration {
                    StudioPill(title: duration)
                }

                if job.totalToolCalls > 0 {
                    StudioPill(title: L("agent.jobs.toolCalls", job.totalToolCalls))
                }
            }
            .padding(.horizontal, StudioTheme.Spacing.large)
            .padding(.bottom, StudioTheme.Spacing.medium)

            Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))

            ScrollView {
                VStack(alignment: .leading, spacing: StudioTheme.Spacing.pageGroup) {
                    AgentJobSection(title: L("agent.jobs.detail.prompt"), icon: "person.fill") {
                        Text(job.userPrompt)
                            .font(.studioBody(StudioTheme.Typography.body))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .textSelection(.enabled)
                    }

                    if let selectedText = job.selectedText, !selectedText.isEmpty {
                        AgentJobSection(title: L("agent.jobs.detail.context"), icon: "text.quote") {
                            Text(selectedText)
                                .font(.studioBody(StudioTheme.Typography.bodySmall))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }

                    if !job.steps.isEmpty {
                        AgentJobSection(title: L("agent.jobs.detail.steps"), icon: "list.number") {
                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.medium) {
                                ForEach(job.steps) { step in
                                    AgentJobStepView(step: step, isLast: step.id == job.steps.last?.id)
                                }
                            }
                        }
                    }

                    if let result = job.resultText, !result.isEmpty {
                        AgentJobSection(title: L("agent.jobs.detail.result"), icon: "sparkles") {
                            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                                StudioSegmentedPicker(
                                    options: [
                                        (L("agent.jobs.detail.result.view.plainText"), ResultViewMode.plainText),
                                        (L("agent.jobs.detail.result.view.markdown"), ResultViewMode.markdown),
                                    ],
                                    selection: $resultViewMode,
                                )

                                if resultViewMode == .plainText {
                                    Text(result)
                                        .font(.studioBody(StudioTheme.Typography.body))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    MarkdownWebView(markdown: result, appearanceMode: appearanceMode)
                                        .frame(minHeight: 220)
                                }
                            }
                        }
                    }

                    if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                        AgentJobSection(title: L("agent.jobs.detail.error"), icon: "exclamationmark.triangle.fill") {
                            Text(errorMessage)
                                .font(.studioBody(StudioTheme.Typography.body))
                                .foregroundStyle(StudioTheme.danger)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(StudioTheme.Spacing.large)
            }
        }
    }
}

private struct AgentJobSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.Typography.iconSmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(title)
                    .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }

            StudioCard(padding: 12) {
                content
            }
        }
    }
}

private struct AgentJobStepView: View {
    let step: AgentJobStep
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                Text(L("agent.jobs.detail.stepNumber", step.stepIndex + 1))
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)

                Text("·")
                    .foregroundStyle(StudioTheme.textTertiary)

                Text(step.stepDescription)
                    .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)

                Spacer()

                Text(step.formattedDuration)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textTertiary)
            }

            if let assistantText = step.assistantText, !assistantText.isEmpty {
                Text(assistantText)
                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            ForEach(step.toolCalls) { toolCall in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                        Image(systemName: toolCall.isError ? "xmark.circle.fill" : "wrench.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(toolCall.isError ? StudioTheme.danger : StudioTheme.accent)
                            .padding(.top, 3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(toolCall.name)
                                .font(.studioBody(StudioTheme.Typography.bodySmall, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)

                            if !toolCall.argumentsJSON.isEmpty, toolCall.argumentsJSON != "{}" {
                                AgentToolCallArgumentsView(argumentsJSON: toolCall.argumentsJSON)
                            }

                            if !toolCall.resultContent.isEmpty {
                                Text(toolCall.resultContent)
                                    .font(.studioBody(StudioTheme.Typography.bodySmall))
                                    .foregroundStyle(toolCall.isError ? StudioTheme.danger : StudioTheme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.surface.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !isLast {
                Divider().overlay(StudioTheme.border.opacity(StudioTheme.Opacity.divider))
            }
        }
    }
}

private struct AgentToolCallArgumentsView: View {
    let argumentsJSON: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("agent.jobs.detail.toolCall.arguments"))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                }
                .foregroundStyle(StudioTheme.textTertiary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(argumentsJSON)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(StudioTheme.surfaceMuted.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private func jobStatusColor(_ status: AgentJobStatus) -> Color {
    switch status {
    case .running:
        StudioTheme.warning
    case .completed:
        StudioTheme.success
    case .failed:
        StudioTheme.danger
    }
}

private func agentStatusTitle(_ status: AgentJobStatus) -> String {
    switch status {
    case .running:
        L("agent.jobs.status.running")
    case .completed:
        L("agent.jobs.status.completed")
    case .failed:
        L("agent.jobs.status.failed")
    }
}

private func jobTimeText(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func jobDetailTimeText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}
