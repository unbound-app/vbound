import SwiftUI

struct LevelFilter: View {
    let label: String
    @Binding var on: Bool
    let color: Color

    var body: some View {
        Button { on.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? color : .secondary.opacity(0.45))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? color.opacity(0.12) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    on ? color.opacity(0.4) : Color.secondary.opacity(0.2),
                                    lineWidth: 0.5
                                )
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
