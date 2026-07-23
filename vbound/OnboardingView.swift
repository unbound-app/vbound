import SwiftUI

private struct RequirementCheck: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let optional: Bool
    var status: Status = .checking

    enum Status { case checking, found, missing }
}

struct OnboardingView: View {
    @Environment(AppController.self) private var manager
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"

    @State private var checks: [RequirementCheck] = [
        RequirementCheck(title: "vphone-cli", detail: "The configured vphone-cli path exists", optional: false),
        RequirementCheck(title: "pymobiledevice3", detail: "Required for device discovery, log streaming, and shell", optional: false),
        RequirementCheck(title: "sshpass", detail: "Required for build, Discord launch, and shell", optional: false),
        RequirementCheck(title: "sshfs", detail: "Only needed for the Finder mount feature", optional: true),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            card
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .task { await runChecks() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Welcome to vbound")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Checking for the tools vbound needs on this Mac:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks) { check in
                        HStack(alignment: .top, spacing: 8) {
                            statusIcon(check.status)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(check.title).font(.system(size: 12, weight: .medium))
                                    if check.optional {
                                        Text("optional")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                                Text(check.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Get Started") {
                        hasCompletedOnboarding = true
                        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }

    @ViewBuilder
    private func statusIcon(_ status: RequirementCheck.Status) -> some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .found:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func runChecks() async {
        checks[0].status = AppController.pathValid(vphoneCliPath) ? .found : .missing

        let pymobiledevice3 = await manager.runCapture(args: ["which", "pymobiledevice3"], timeout: 5)
        checks[1].status = pymobiledevice3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .found

        let sshpass = await manager.runCapture(args: ["which", "sshpass"], timeout: 5)
        checks[2].status = sshpass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .found

        checks[3].status = manager.sshfsAvailable ? .found : .missing
    }
}
