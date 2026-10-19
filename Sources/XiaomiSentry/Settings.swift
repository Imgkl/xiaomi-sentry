import Foundation
import Security
import SentryCore

/// Non-secret settings live in UserDefaults. The API password lives in the Keychain.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    /// Xiaomi cloud regions that go2rtc v1.9.14 knows (internal/xiaomi/xiaomi.go, GetBaseURL).
    enum Region: String, CaseIterable, Identifiable {
        case cn, de, i2, ru, sg, us
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cn: return "China"
            case .de: return "Europe"
            case .i2: return "India"
            case .ru: return "Russia"
            case .sg: return "Singapore"
            case .us: return "United States"
            }
        }
    }

    static var region: Region {
        get { Region(rawValue: defaults.string(forKey: "region") ?? "") ?? .i2 }
        set { defaults.set(newValue.rawValue, forKey: "region") }
    }

    enum Appearance: String, CaseIterable {
        case light, dark, system
        var title: String { ["light": "Light", "dark": "Dark", "system": "Match System"][rawValue]! }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    static var lastStream: String? {
        get { defaults.string(forKey: "lastStream") }
        set { defaults.set(newValue, forKey: "lastStream") }
    }

    /// Display names for streams this app created from Xiaomi discovery, keyed by stream name.
    static var displayNames: [String: String] {
        get { defaults.dictionary(forKey: "displayNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "displayNames") }
    }

    static func load() -> ServerConfig? {
        guard let host = defaults.string(forKey: "host"), !host.isEmpty else { return nil }
        let port = defaults.integer(forKey: "port")
        let user = defaults.string(forKey: "username") ?? ""
        let password = Keychain.read(account: account(user: user, host: host, port: port)) ?? ""
        return ServerConfig(host: host, port: port == 0 ? 1984 : port, username: user, password: password)
    }

    static func save(_ c: ServerConfig) {
        defaults.set(c.host, forKey: "host")
        defaults.set(c.port, forKey: "port")
        defaults.set(c.username, forKey: "username")
        Keychain.write(c.password, account: account(user: c.username, host: c.host, port: c.port))
    }

    private static func account(user: String, host: String, port: Int) -> String { "\(user)@\(host):\(port)" }
}

enum Keychain {
    private static let service = "com.imgkl.xiaomisentry.go2rtc"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ password: String, account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard !password.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "go2rtc login"
        SecItemAdd(add as CFDictionary, nil)
    }
}
