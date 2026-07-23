import AppKit

extension AppController {

    static let hotkeyKeyCode: UInt16 = 9  // "V"
    static let hotkeyModifiers: NSEvent.ModifierFlags = [.command, .option]
    static let hotkeyLabel = "⌥⌘V"

    func enableGlobalHotkey() {
        guard globalHotkeyMonitor == nil else { return }
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isHotkeyEvent(event) else { return event }
            self.toggleWindowVisibility()
            return nil
        }
    }

    func disableGlobalHotkey() {
        if let globalHotkeyMonitor { NSEvent.removeMonitor(globalHotkeyMonitor) }
        if let localHotkeyMonitor  { NSEvent.removeMonitor(localHotkeyMonitor) }
        globalHotkeyMonitor = nil
        localHotkeyMonitor  = nil
    }

    private func isHotkeyEvent(_ event: NSEvent) -> Bool {
        event.keyCode == Self.hotkeyKeyCode &&
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == Self.hotkeyModifiers
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        guard isHotkeyEvent(event) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.toggleWindowVisibility() }
        }
    }

    private func toggleWindowVisibility() {
        guard let window = ourWindow else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if window.isVisible, window.isKeyWindow || NSApp.isActive {
            window.orderOut(nil)
        } else {
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
