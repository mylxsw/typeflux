import SwiftUI

struct OnboardingFileSearchPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func text(_ key: String, arguments: [CVarArg] = []) -> String {
        OnboardingStrings.text(key, table: OnboardingStep.fileSearch.table, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                OnboardingEditorialHeader(
                    eyebrow: Self.text("eyebrow"), title: Self.text("title"), pill: OnboardingStep.fileSearch.pill
                )
                privacy
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    choices
                    if viewModel.fileSearchChoice != .off { folderScope }
                }
            }
        }
        .padding(.horizontal, 34).padding(.top, 6)
    }

    private var privacy: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color(red: 0.38, green: 0.81, blue: 0.56)
                                                      : Color(red: 0.13, green: 0.44, blue: 0.28))
                .accessibilityHidden(true)
            Text(Self.text("subtitle")).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choices: some View {
        VStack(spacing: 10) {
            ForEach(OnboardingFileSearchChoice.allCases, id: \.self) { choice in
                if choice != .contents || OnboardingFileSearchChoice.supportsContents {
                    OnboardingSelectableCard(
                        selected: viewModel.fileSearchChoice == choice,
                        action: { viewModel.fileSearchChoice = choice },
                        insets: .init(top: 14, leading: 16, bottom: 14, trailing: 16),
                        content: {
                            HStack(spacing: 14) {
                                symbol(choice.icon)
                                Text(Self.text(choice.rawValue)).font(.system(size: 14, weight: .semibold))
                            }
                        }
                    )
                    .accessibilityIdentifier("onboarding.fileSearch.\(choice.rawValue)")
                }
            }
        }
    }

    private var folderScope: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.text("scope")).font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                if viewModel.fileSearchFolders.isEmpty {
                    folderRow(nil, showsAdd: true)
                } else {
                    ForEach(viewModel.fileSearchFolders, id: \.self) { path in
                        if path != viewModel.fileSearchFolders.first { Divider() }
                        folderRow(path, showsAdd: path == viewModel.fileSearchFolders.last)
                    }
                }
            }
            .modifier(OnboardingSelectionSurface(selected: false))
        }
    }

    private func folderRow(_ path: String?, showsAdd: Bool) -> some View {
        HStack(spacing: 14) {
            symbol("folder")
            if let path {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AskFileLabels.folder(path)).font(.system(size: 13, weight: .semibold))
                    Text(path).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(Self.text("empty")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let path {
                Button {
                    viewModel.fileSearchFolders.removeAll { $0 == path }
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.text("remove", arguments: [AskFileLabels.folder(path)]))
                .accessibilityIdentifier("onboarding.fileSearch.removeFolder")
            }
            if showsAdd {
                TFButton(title: Self.text("add"), systemImage: "plus", size: .small) {
                    if let paths = LauncherSearchSettingsView.pickFolders(allowApps: false) {
                        viewModel.fileSearchFolders = LauncherSearchSettingsView.adding(
                            paths, to: viewModel.fileSearchFolders
                        )
                    }
                }
                .accessibilityIdentifier("onboarding.fileSearch.addFolder")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(width: 38, height: 38)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}
