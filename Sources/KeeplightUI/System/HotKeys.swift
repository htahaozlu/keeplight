import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon `RegisterEventHotKey`, which needs no Accessibility
/// permission [O§0 D5]. Delivers both press and release, so a chord can be held.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Key: UInt32, CaseIterable {
        /// ⌃⌥⌘D: toggle the panel.
        case panel = 1
        /// Hold ⌃⌥⌘R: rescue.
        case rescue = 2
        /// ⎋ while a change is pending: revert. Registered only for the pending window.
        case escape = 3

        var keyCode: UInt32 {
            switch self {
            case .panel: UInt32(kVK_ANSI_D)
            case .rescue: UInt32(kVK_ANSI_R)
            case .escape: UInt32(kVK_Escape)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .panel, .rescue: UInt32(cmdKey | optionKey | controlKey)
            case .escape: 0
            }
        }

        var display: String {
            switch self {
            case .panel: "⌃⌥⌘D"
            case .rescue: "⌃⌥⌘R"
            case .escape: "⎋"
            }
        }
    }

    private struct Handler {
        var onPress: @MainActor () -> Void
        var onRelease: (@MainActor () -> Void)?
    }

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handlers: [Key: Handler] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4B4C_6368  // 'KLch'

    private init() {}

    /// Registers `key`; false when macOS refused (e.g. another app holds the chord).
    @discardableResult
    func register(_ key: Key, onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)? = nil) -> Bool {
        installHandlerIfNeeded()
        unregister(key)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: key.rawValue)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[key] = ref
        handlers[key] = Handler(onPress: onPress, onRelease: onRelease)
        return true
    }

    func unregister(_ key: Key) {
        if let ref = refs.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
        handlers[key] = nil
    }

    fileprivate func dispatch(_ id: UInt32, pressed: Bool) {
        guard let key = Key(rawValue: id), let handler = handlers[key] else { return }
        if pressed { handler.onPress() } else { handler.onRelease?() }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, types.count, &types, nil, &eventHandler)
    }
}

private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let hotKeyID = id.id
    MainActor.assumeIsolated { HotKeys.shared.dispatch(hotKeyID, pressed: pressed) }
    return noErr
}
