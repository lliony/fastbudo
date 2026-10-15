import Foundation

enum NewItemTypes {
    static let key = "newFileTypes"
    static let changed = Notification.Name("local.fastbudo.newFileTypes.changed")
    static let requested = Notification.Name("local.fastbudo.newFileTypes.requested")
    static var defaults: UserDefaults { .standard }
    static func broadcast() {
        DistributedNotificationCenter.default().postNotificationName(changed,
            object: defaults.string(forKey: key) ?? "txt, md", userInfo: nil, deliverImmediately: true)
    }
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased().split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).compactMap { value in
            let item = String(value).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !item.isEmpty, item != "folder", item != "custom", item.count <= 16,
                  item.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) }),
                  seen.insert(item).inserted else { return nil }
            return item
        }.prefix(12).map { $0 }
    }
    static var current: [String] { parse(defaults.string(forKey: key) ?? "txt, md") }
}
