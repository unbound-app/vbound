import SwiftUI
import AppUpdater
import Version
import Textual

struct UpdateOverlay: View {
    @EnvironmentObject private var appUpdater: AppUpdater
    @Binding var isPresented: Bool
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""

    @State private var changelog: String? = nil
    @State private var checkCompleted = false

    private enum Phase {
        case checking
        case upToDate
        case failed(String)
        case available(Release)
        case downloading(Release, Double)
        case readyToInstall(Release, Bundle)

        var release: Release? {
            switch self {
            case .available(let release), .downloading(let release, _), .readyToInstall(let release, _):
                return release
            case .checking, .upToDate, .failed:
                return nil
            }
        }
    }

    private var phase: Phase {
        switch appUpdater.state {
        case .newVersionDetected(let release, _):
            return .available(release)
        case .downloading(let release, _, let fraction):
            return .downloading(release, fraction)
        case .downloaded(let release, _, let bundle):
            return .readyToInstall(release, bundle)
        case .none:
            // Absence of an update surfaces as AUError.cancelled (or .noValidUpdate) from
            // the library, not as a nil error — only treat *other* errors as real failures.
            if let error = appUpdater.lastError, !error.isCancelled {
                return .failed(error.localizedDescription)
            }
            return checkCompleted ? .upToDate : .checking
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            card
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onReceive(appUpdater.$state) { state in
            if case .none = state { return }
            checkCompleted = true
        }
        .onReceive(appUpdater.$lastError) { error in
            if error != nil { checkCompleted = true }
        }
        .task(id: phase.release?.tagName.description) {
            guard let release = phase.release else { changelog = nil; return }
            changelog = await appUpdater.localizedChangelog(for: release)
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusAndChangelog
                .padding(20)
        }
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }

    private var header: some View {
        HStack {
            Text("Software Update")
                .font(.headline)
            Spacer()
            Button(action: close) {
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

    // Fixed height regardless of phase: the changelog scrolls in place and the status
    // row swaps content without ever resizing the card.
    private var statusAndChangelog: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow
            changelogView
            HStack {
                if let release = phase.release, let url = URL(string: release.htmlUrl) {
                    Link("Release Notes ↗", destination: url)
                        .font(.footnote)
                }
                Spacer()
                if let release = phase.release {
                    Button("Skip This Version") {
                        skippedUpdateVersion = release.tagName.description
                        close()
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 210, alignment: .top)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch phase {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }

        case .upToDate:
            Label("You're up to date.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't check for updates", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    checkCompleted = false
                    appUpdater.check()
                }
                .buttonStyle(.link)
            }

        case .available(let release):
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .imageScale(.large)
                Text("Version \(release.tagName.description) available")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView().controlSize(.small)
            }

        case .downloading(let release, let fraction):
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

        case .readyToInstall(let release, let bundle):
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

    @ViewBuilder
    private var changelogView: some View {
        if let changelog, !changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                // Release notes come from `generate_release_notes: true`, which is GitHub-
                // flavored Markdown (bullet lists of PR titles, bold, links) — rendering it
                // as plain Text left the literal "- "/"**" markup visible instead of formatted.
                StructuredText(markdown: changelog)
                    .textual.structuredTextStyle(.gitHub)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
        }
    }
}
