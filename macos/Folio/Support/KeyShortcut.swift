import AppKit
import SwiftUI

/// A key with modifiers, as the user records it in settings (划词翻译's shortcut).
struct KeyShortcut: Equatable {
    var keyCode: UInt16
    /// The key's character without modifiers, for display ("d").
    var characters: String
    var modifiers: NSEvent.ModifierFlags

    static let defaultSelectionTranslation = KeyShortcut(keyCode: 2, characters: "d", modifiers: [.option])

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let functionKey = (0x7A...0x7F).contains(event.keyCode) || [0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x67, 0x6D, 0x6F, 0x76, 0x78].contains(event.keyCode)
        // A plain letter would get in the way of typing and of PDFKit's own keys.
        guard !characters.isEmpty, !modifiers.isEmpty || functionKey else { return nil }
        self.init(keyCode: event.keyCode, characters: characters, modifiers: modifiers)
    }

    init?(storage: [String: Any]?) {
        guard let storage, let code = storage["keyCode"] as? Int, let characters = storage["characters"] as? String,
              let flags = storage["modifiers"] as? Int else { return nil }
        self.init(keyCode: UInt16(code), characters: characters, modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags)))
    }

    var storage: [String: Any] { ["keyCode": Int(keyCode), "characters": characters, "modifiers": Int(modifiers.rawValue)] }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.relevantModifiers) == modifiers
    }

    /// "⌥D"
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode: keyCode, characters: characters)
    }

    private static func keyName(keyCode: UInt16, characters: String) -> String {
        switch keyCode {
        case 0x31: return String(localized: "空格")
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default: return characters.uppercased()
        }
    }
}

/// A button that shows a shortcut and records a new one when clicked (Esc cancels, ⌫ restores the default).
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    var defaultShortcut: KeyShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "请按下快捷键…") : shortcut.display)
                .monospacedDigit()
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 96)
        }
        .help(String(localized: "点按后按下新的快捷键；⌫ 恢复默认"))
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 0x35: stop()                                   // Esc
            case 0x33 where event.modifierFlags.intersection(KeyShortcut.relevantModifiers).isEmpty:
                shortcut = defaultShortcut                      // ⌫
                stop()
            default:
                guard let recorded = KeyShortcut(event: event) else { NSSound.beep(); return nil }
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
