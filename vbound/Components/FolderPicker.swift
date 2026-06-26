import SwiftUI
import AppKit

struct FolderPicker: View {
    let label: String
    @Binding var path: String

    private var isGitRepo: Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(
            atPath: (expanded as NSString).appendingPathComponent(".git")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(isGitRepo ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                    .help(isGitRepo ? "Valid git repository" : "Not a git repository")
            }
            Button { browse() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }
}
