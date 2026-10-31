import AppKit
import SwiftUI

struct OnboardingPermissionsPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingPermissionsModel
    @Environment(\.colorScheme) private var colorScheme

    static func text(_ key: String, arguments: [CVarArg] = []) -> String {
        OnboardingStrings.text(key, table: "OnboardingPermissions", arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingEditorialHeader(eyebrow: Self.text("eyebrow"), title: Self.text("title"),
                                      subtitle: Self.text("subtitle"), pill: OnboardingStep.permissions.pill)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(Self.text("required")).font(.system(size: 13, weight: .bold))
                        badge("\(model.requiredGranted) / \(model.required.count)", success: model.nextPending == nil)
                    }
                    VStack(spacing: 0) {
                        ForEach(model.required) { permission in
                            if permission != model.required.first {
                                Divider()
                            }
                            row(permission)
                        }
                    }.modifier(PermissionCard())
                    VStack(spacing: 0) {
                        Button { model.optionalExpanded.toggle() } label: {
                            HStack(spacing: 12) {
                                Text(Self.text("optional")).font(.system(size: 13, weight: .bold))
                                Text(Self.text("optionalHint")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                badge("\(model.optionalGranted) / \(model.optional.count)")
                                Image(systemName: "chevron.right").font(.system(size: 11))
                                    .rotationEffect(.degrees(model.optionalExpanded ? 90 : 0))
                                    .foregroundStyle(.tertiary)
                            }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("onboarding.permissions.optional")
                        if model.optionalExpanded {
                            ForEach(model.optional) { permission in
                                Divider()
                                row(permission, compact: true)
                            }
                        }
                    }.modifier(PermissionCard())
                }.padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 34).padding(.top, 6)
        .overlay(alignment: .bottomTrailing) {
            if let permission = model.guidePermission {
                guide(permission).padding(.trailing, 20).padding(.bottom, 4)
            }
        }
        .task(id: model.isBusy) { await model.refresh() }
        .task(id: model.guidePermission) { await model.monitorGuide() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: viewModel.serviceRoute) { _ in Task { await model.refresh() } }
        .onChange(of: viewModel.settingsStore.sttProvider) { _ in Task { await model.refresh() } }
        .onDisappear { model.stop() }
    }

    private func badge(_ text: String, success: Bool = false) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(success ? Color.green : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(success ? Color.green.opacity(0.1) : Color.primary.opacity(0.04), in: Capsule())
    }

    private func row(_ permission: SettingsPermission, compact: Bool = false) -> some View {
        let granted = model.status(permission) == .granted
        let waiting = model.permissions.requestingPermission == permission
            || (model.guidePermission == permission && !granted && permission != .automation)
        let opensSettings = model.settingsActions.contains(permission)
        let denied = !granted && ((opensSettings && [.microphone, .speechRecognition].contains(permission))
            || model.permissions.requestError == permission)
        return HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark" : symbol(permission))
                .font(.system(size: 16)).foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                .background(granted ? Color.green.opacity(0.1) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: compact ? 9 : 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.text("\(permission.rawValue).title")).font(.system(size: 13, weight: .semibold))
                Text(Self.text(denied ? "denied" : "\(permission.rawValue).summary"))
                    .font(.system(size: 11.5)).foregroundStyle(denied ? Color.orange : Color.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                badge(Self.text("granted"), success: true)
            } else if waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(Self.text("waiting")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if model.status(permission) == .systemManaged {
                        badge(Self.text("managed"))
                    }
                    Button { model.requestAccess(permission) } label: {
                        HStack(spacing: 6) {
                            if permission.isRequired {
                                Image(systemName: "lock").font(.system(size: 10))
                            }
                            Text(Self.text(opensSettings ? "openSettings" : "allow"))
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(permission == model.nextPending ? Color.white : Color.primary)
                    .background(permission == model.nextPending ? Color.accentColor : Color.primary.opacity(0.05),
                                in: Capsule())
                    .disabled(model.isBusy || model.permissions.isRefreshing)
                    .accessibilityIdentifier("onboarding.permissions.\(permission.rawValue)")
                    .accessibilityLabel(Self.text(opensSettings ? "openSettings" : "allow"))
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, compact ? 9 : 12)
    }

    private func guide(_ permission: SettingsPermission) -> some View {
        let granted = model.status(permission) == .granted
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                appIcon(size: 18)
                Text(Self.text("guideTitle", arguments: [Self.text("\(permission.rawValue).title")]))
                    .font(.system(size: 12.5, weight: .bold))
                Spacer(minLength: 0)
                Button { model.dismissGuide() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("×")
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(.gray).frame(width: 16, height: 16)
                    Text(Self.text("guideOtherApp"))
                    Spacer()
                    guideToggle(true)
                }.padding(.horizontal, 6).frame(height: 28)
                HStack(spacing: 8) {
                    appIcon(size: 16)
                    Text("Typeflux")
                    Spacer()
                    if model.status(permission) == .systemManaged {
                        Text(Self.text("managed")).font(.system(size: 10))
                    } else {
                        guideToggle(granted)
                    }
                }.padding(.horizontal, 6).frame(height: 28)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }.font(.system(size: 12)).padding(6)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            if model.status(permission) != .systemManaged {
                HStack(spacing: 6) {
                    if granted {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(Self.text(granted ? "completed" : "detecting")).font(.system(size: 11.5))
                }.foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 270)
        .background(colorScheme == .dark ? Color(white: 0.17) : .white,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    private func appIcon(size: CGFloat) -> some View {
        Image("TypefluxIcon", bundle: .appResources).resizable().interpolation(.high)
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func guideToggle(_ enabled: Bool) -> some View {
        Capsule().fill(enabled ? Color.green : Color.secondary.opacity(0.3))
            .frame(width: 28, height: 16)
            .overlay(alignment: enabled ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 12, height: 12).padding(2)
            }
    }

    private func symbol(_ permission: SettingsPermission) -> String {
        switch permission {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .speechRecognition: "waveform"
        case .screenRecording: "rectangle.on.rectangle"
        case .camera: "camera"
        case .calendar: "calendar"
        case .notifications: "bell"
        case .automation: "gearshape.2"
        case .fullDiskAccess: "internaldrive"
        }
    }
}

private struct PermissionCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background(colorScheme == .dark ? Color.white.opacity(0.045) : .white,
                           in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07)))
    }
}
