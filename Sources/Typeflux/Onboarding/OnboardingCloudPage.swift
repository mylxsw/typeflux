import SwiftUI

struct OnboardingCloudPage: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @ObservedObject var model: OnboardingCloudModel
    @Environment(\.colorScheme) private var colorScheme
    private func text(_ key: String) -> String {
        OnboardingStrings.text(key, table: "OnboardingCloud")
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            OnboardingEditorialHeader(eyebrow: text("eyebrow"), title: text("title"),
                                      subtitle: text("subtitle"), pill: OnboardingStep.cloud.pill, centered: true)
            VStack(spacing: 18) {
                account
                if model.signedIn {
                    capabilities
                } else {
                    loginActions
                }
                if let error = model.error {
                    HStack {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                        Button(L("auth.web.retry"), action: model.retry).buttonStyle(.plain)
                    }
                }
            }
            .padding(22).frame(width: 460)
            .background(colorScheme == .dark ? Color.white.opacity(0.045) : .white,
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .task { model.activate() }
        .onDisappear { model.deactivate() }
    }

    private var account: some View {
        HStack(spacing: 14) {
            if model.signedIn {
                Text(String((model.profile?.resolvedDisplayName ?? "").prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.369, green: 0.361, blue: 0.902), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Circle()
                    )
            } else {
                Image(nsImage: HelpAppIcon.image).resizable().frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(model.signedIn ? model.profile?.resolvedDisplayName ?? text("account") : text("account"))
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                if model.signedIn {
                    Text(model.profile?.email ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                } else if case let .failed(error) = model.phase {
                    Text(L(error.localizationKey)).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                } else {
                    Text(model.phase == .cancelled ? L("auth.web.cancelled") : text("providers"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.signedIn {
                Text(model.planName.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .foregroundStyle(viewModel.authState.subscription.paid ? Color.accentColor : .secondary)
                    .background(
                        viewModel.authState.subscription.paid ? Color.accentColor.opacity(0.1) : .primary.opacity(0.04),
                        in: Capsule()
                    )
            }
        }
    }

    @ViewBuilder private var loginActions: some View {
        if model.phase == .waiting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("auth.web.waiting")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(L("auth.web.reopen"), action: model.reopen).buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button(action: model.cancel) {
                    Text(L("auth.web.cancel")).padding(.horizontal, 13).frame(height: 26)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 40)
                .background(.primary.opacity(0.04), in: Capsule())
        } else if model.phase == .creating || model.phase == .exchanging {
            HStack {
                ProgressView().controlSize(.small)
                Text(L(model.phase == .exchanging ? "auth.web.exchanging" : "auth.web.waiting"))
            }.font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 40)
                .background(.primary.opacity(0.04), in: Capsule())
        } else {
            Button { Task { await model.start() } } label: {
                HStack {
                    Text(text(isFailed ? "retry" : "login"))
                    Image(systemName: "arrow.up.right")
                }.font(.system(size: 13.5, weight: .bold)).frame(maxWidth: .infinity).frame(height: 40)
                    .foregroundStyle(.white).background(Color.accentColor, in: Capsule())
            }.buttonStyle(.plain)
                .accessibilityLabel(text(isFailed ? "retry" : "login"))
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase {
            return true
        }; return false
    }

    private var checkingEntitlement: Bool {
        !model.entitlementReady || viewModel.authState.isLoadingSubscription
    }

    private var capabilities: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 6)
            HStack(spacing: 12) {
                capabilityLabel("speech", symbol: "waveform")
                Spacer()
                if let progress = model.downloadProgress {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                } else if checkingEntitlement {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                } else if model.cloudSpeech || model.localReady {
                    Label(text(model.cloudSpeech ? "available" : "local"), systemImage: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Text(text("notIncluded")).foregroundStyle(.orange)
                    Button(action: model.downloadLocalModel) {
                        Text(text("useLocal")).fontWeight(.semibold).padding(.horizontal, 13).frame(height: 30)
                            .background(.primary.opacity(0.04), in: Capsule())
                            .overlay(Capsule().stroke(.primary.opacity(0.14)))
                    }.buttonStyle(.plain).disabled(viewModel.localModelManager == nil)
                }
            }.frame(height: 44)
            HStack(spacing: 12) {
                capabilityLabel("ai", symbol: "sparkles")
                Spacer()
                if !checkingEntitlement {
                    Label(text("available"), systemImage: "checkmark").foregroundStyle(.green)
                } else if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }.frame(height: 44)
            Button(text("switchAccount")) { Task { await model.switchAccount() } }
                .buttonStyle(.plain).fontWeight(.medium).foregroundStyle(.secondary).padding(.top, 10)
        }.font(.system(size: 12))
    }

    private func capabilityLabel(_ key: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28, height: 28)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            Text(text(key)).font(.system(size: 13, weight: .semibold))
        }
    }
}
