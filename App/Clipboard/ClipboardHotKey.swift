import AppKit
import Carbon

@MainActor final class ClipboardHotKey {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var binding: (UInt32, UInt32)?
    private let identifier: UInt32
    var action: () -> Void = {}

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    func matches(_ id: EventHotKeyID) -> Bool { id.signature == 0x46424350 && id.id == identifier }

    func register(key: UInt32, modifiers: UInt32) -> Bool {
        if let binding, binding == (key, modifiers), hotKey != nil { return true }
        guard Self.accepts(key: key, modifiers: modifiers) else { return false }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<ClipboardHotKey>.fromOpaque(context).takeUnretainedValue()
                    guard owner.matches(id) else { return OSStatus(eventNotHandledErr) }
                    owner.action()
                    return noErr
                }
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return false }
        }
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x46424350, id: identifier),
                                  GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        // 注册成功后才释放旧绑定，冲突不能让原快捷键失效。
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; binding = (key, modifiers)
        return true
    }
    nonisolated static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
        kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16,
        kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    nonisolated static func accepts(key: UInt32, modifiers: UInt32) -> Bool {
        guard key <= 127, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key),
              modifiers & ~UInt32(controlKey | cmdKey | optionKey | shiftKey) == 0 else { return false }
        return true
    }
    func stop() {
        binding = nil
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
