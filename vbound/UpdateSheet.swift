import SwiftUI
import AppUpdater
import Version

struct UpdateSheet: View {
    @EnvironmentObject private var appUpdater: AppUpdater
    @Environment(\.dismiss) private var dismiss

    @State private var changelog: String? = nil
    @State private var checkCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440)
        .onReceive(appUpdater.$state) { state in
            if case .none = state { return }
            checkCompleted = true
        }
        .onReceive(appUpdater.$lastError) { error in
            if error != nil { checkCompleted = true }
        }
        .task(id: appUpdater.state.release?.tagName.description) {
            guard let release = appUpdater.state.release else { changelog = nil; return }
            changelog = await appUpdater.localizedChangelog(for: release)
        }
    }

    private var header: some View {
        HStack {
            Text("Software Update")
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch appUpdater.state {
        case .none:
            if checkCompleted {
                Label("You're up to date.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").foregroundStyle(.secondary)
                }
            }

        case .newVersionDetected(let release, _):
            updateContent(release: release) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .imageScale(.large)
                    Text("Version \(release.tagName.description) available")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }

        case .downloading(let release, _, let fraction):
            updateContent(release: release) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading version \(release.tagName.description)…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(fraction * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: fraction)
                }
            }

        case .downloaded(let release, _, let bundle):
            updateContent(release: release) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.large)
                    Text("Version \(release.tagName.description) ready to install")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Update Now") { appUpdater.install(bundle) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private func updateContent(release: Release, @ViewBuilder statusRow: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow()
            if let changelog, !changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(changelog)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
            }
            if let url = URL(string: release.htmlUrl) {
                Link("Release Notes ↗", destination: url)
                    .font(.footnote)
            }
        }
    }
}
