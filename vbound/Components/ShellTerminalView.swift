import AppKit
import SwiftTerm
import SwiftUI

struct ShellTerminalView: NSViewRepresentable {
    let manager: AppController
    let shouldConnect: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let terminal = manager.embeddedTerminal {
            terminal.processDelegate = context.coordinator
            if shouldConnect { context.coordinator.start(terminal) }
            return terminal
        }
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        terminal.nativeForegroundColor = NSColor(calibratedRed: 0.9, green: 0.92, blue: 0.96, alpha: 1)
        terminal.useBrightColors = true
        terminal.processDelegate = context.coordinator
        manager.embeddedTerminal = terminal
        if shouldConnect { context.coordinator.start(terminal) }
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        if shouldConnect { context.coordinator.start(terminal) }
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let manager: AppController

        init(manager: AppController) {
            self.manager = manager
        }

        func start(_ terminal: LocalProcessTerminalView) {
            Task { @MainActor [manager] in
                guard await manager.prepareEmbeddedShell() else { return }
                terminal.startProcess(
                    executable: "/usr/bin/env",
                    args: manager.embeddedShellArguments,
                    environment: manager.embeddedShellEnvironment
                )
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [manager] in
                guard source === manager.embeddedTerminal else { return }
                manager.embeddedTerminal = nil
                manager.embeddedShellTerminated()
            }
        }
    }
}
