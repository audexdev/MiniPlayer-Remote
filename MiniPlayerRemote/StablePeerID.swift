import Foundation
import Security

final class StablePeerID {
    static let shared = StablePeerID()
    private let service = "com.miniplayerremote.peerid"
    private let account = "peerDisplayName"

    func loadDisplayName(label: String) -> String {
        if let existing = read() {
            return existing
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        let displayName = "\(label)-\(suffix)"
        _ = save(displayName)
        return displayName
    }

    private func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let attributes: [String: Any] = query.merging([
            kSecValueData as String: data
        ]) { $1 }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
