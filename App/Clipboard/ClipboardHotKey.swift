import AppKit
import Carbon

@MainActor final class ClipboardHotKey {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var action: () -> Void = {}

    func register(key: UInt32, modifiers: UInt32) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard modifiers & UInt32(controlKey | cmdKey) != 0 else { return false }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<ClipboardHotKey>.fromOpaque(context).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return false }
        }
        return RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x46424350, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
