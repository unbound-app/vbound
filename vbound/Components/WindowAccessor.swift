import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window.map(self.callback) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
