import AppKit
import SwiftTerm
import SwiftUI

struct ShellTerminalView: NSViewRepresentable {
    let manager: AppController

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        if let terminal = manager.embeddedTerminal {
            terminal.processDelegate = context.coordinator
            return terminal
        }
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        context.coordinator.start(terminal)
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {}

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
                manager.embeddedTerminal = terminal
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
                manager.embeddedTerminal = nil
                manager.embeddedShellTerminated()
            }
        }
    }
}
