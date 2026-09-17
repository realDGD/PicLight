import AppKit

/// A single customizable shortcut: a character plus modifiers.
public struct ShortcutDefinition: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: ModifierSet

    public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let command = ModifierSet(rawValue: 1 << 0)
        public static let shift = ModifierSet(rawValue: 1 << 1)
        public static let option = ModifierSet(rawValue: 1 << 2)
        public static let control = ModifierSet(rawValue: 1 << 3)

        public init(eventFlags: NSEvent.ModifierFlags) {
            var value: UInt = 0
            if eventFlags.contains(.command) { value |= Self.command.rawValue }
            if eventFlags.contains(.shift) { value |= Self.shift.rawValue }
            if eventFlags.contains(.option) { value |= Self.option.rawValue }
            if eventFlags.contains(.control) { value |= Self.control.rawValue }
            self.init(rawValue: value)
        }

        public var eventFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }

        public var displayString: String {
            var parts = ""
            if contains(.control) { parts += "⌃" }
            if contains(.option) { parts += "⌥" }
            if contains(.shift) { parts += "⇧" }
            if contains(.command) { parts += "⌘" }
            return parts
        }
    }

    public init(key: String, modifiers: ModifierSet) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              !characters.isEmpty else { return nil }
        self.key = characters
        self.modifiers = ModifierSet(eventFlags: event.modifierFlags)
    }

    public var displayString: String {
        modifiers.displayString + Self.displayName(for: key)
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "\u{1b}": return "⎋"
        case "\r": return "↩"
        case "\u{7f}": return "⌫"
        case " ": return "Space"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): return "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): return "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }

    /// Characters usable through the menu key-equivalent machinery.
    public static func arrowKeyCharacter(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default: return nil
        }
    }
}

/// Stores the customizable viewer shortcuts and refuses conflicting bindings
/// rather than silently overriding another command.
@MainActor
public final class ShortcutStore {
    public static let shared = ShortcutStore()

    public static let didChangeNotification = Notification.Name("com.picviewmac.shortcuts.changed")

    private let defaults: UserDefaults
    private var bindings: [ViewerCommand: ShortcutDefinition] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.defaultBindings
        load()
    }

    public static let defaultBindings: [ViewerCommand: ShortcutDefinition] = [
        .nextImage: ShortcutDefinition(key: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: []),
        .previousImage: ShortcutDefinition(key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: []),
        .firstImage: ShortcutDefinition(key: String(UnicodeScalar(NSHomeFunctionKey)!), modifiers: []),
        .lastImage: ShortcutDefinition(key: String(UnicodeScalar(NSEndFunctionKey)!), modifiers: []),
        .zoomToFit: ShortcutDefinition(key: "0", modifiers: [.command]),
        .zoomActualPixels: ShortcutDefinition(key: "1", modifiers: [.command]),
        .zoomDoubleFit: ShortcutDefinition(key: "2", modifiers: [.command]),
        .rotateClockwise: ShortcutDefinition(key: "r", modifiers: [.command]),
        .rotateCounterClockwise: ShortcutDefinition(key: "r", modifiers: [.command, .shift]),
        .toggleMirror: ShortcutDefinition(key: "m", modifiers: [.command]),
        .moveToTrash: ShortcutDefinition(key: "\u{7f}", modifiers: [.command]),
        .togglePlayback: ShortcutDefinition(key: " ", modifiers: []),
        .nextPage: ShortcutDefinition(key: String(UnicodeScalar(NSPageDownFunctionKey)!), modifiers: []),
        .previousPage: ShortcutDefinition(key: String(UnicodeScalar(NSPageUpFunctionKey)!), modifiers: []),
        .toggleImmersive: ShortcutDefinition(key: "i", modifiers: [.command, .shift]),
        .toggleThumbnailDrawer: ShortcutDefinition(key: "t", modifiers: [.command, .shift]),
        .showImageInfo: ShortcutDefinition(key: "i", modifiers: [.command]),
        .toggleSortDirection: ShortcutDefinition(key: "s", modifiers: [.command, .shift]),
    ]

    private static let storageKey = "customShortcuts"

    public func shortcut(for command: ViewerCommand) -> ShortcutDefinition? {
        bindings[command]
    }

    /// Returns `false` and changes nothing when the shortcut is already taken.
    @discardableResult
    public func setShortcut(_ shortcut: ShortcutDefinition?, for command: ViewerCommand) -> Bool {
        if let shortcut, let conflict = conflictingCommand(for: shortcut, excluding: command) {
            _ = conflict
            return false
        }
        bindings[command] = shortcut
        save()
        return true
    }

    public func conflictingCommand(for shortcut: ShortcutDefinition,
                                   excluding command: ViewerCommand) -> ViewerCommand? {
        bindings.first { $0.key != command && $0.value == shortcut }?.key
    }

    public func command(matching event: NSEvent) -> ViewerCommand? {
        guard let definition = ShortcutDefinition(event: event) else { return nil }
        return bindings.first { $0.value == definition }?.key
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: ShortcutDefinition].self, from: data) else { return }
        for (rawCommand, shortcut) in stored {
            guard let command = ViewerCommand(rawValue: rawCommand) else { continue }
            bindings[command] = shortcut
        }
    }

    private func save() {
        var encodable: [String: ShortcutDefinition] = [:]
        for (command, shortcut) in bindings { encodable[command.rawValue] = shortcut }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
