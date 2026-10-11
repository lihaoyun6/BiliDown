import Foundation
import Security

/// 极薄的 Keychain 包装，只做「整个 Data 存 / 取 / 删」。
enum KeychainStore {

    private static let service = "com.lihaoyun6.BiliDown"

    /// 返回 OSStatus。以前这里把错误整个吞了（错误指针传 nil），
    /// 于是「钥匙串根本写不进去」在界面上一点痕迹都没有 ——
    /// 只表现为每次冷启动都要重登一次。现在把错误码交出去，界面能说一句人话。
    ///
    /// 真机上最常见的失败是 **-34018（errSecMissingEntitlement）**：
    /// App 的签名里没有 `application-identifier` 那条 entitlement，钥匙串一律拒收。
    /// 侧载的包、LiveContainer 里的 guest app，十有八九是这个。
    /// **这跟代码无关，是签名的事** —— 要真修，得让构建出来的包带着 entitlement
    /// （Xcode 用真实团队签名，或者让侧载工具正确注入），改多少行代码都白搭。
    /// 好在 Cookie 库不看 entitlement，所以登录态还有第二条路（见 AccountStore）。
    @discardableResult
    static func save(_ data: Data, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        #if os(iOS)
        // 「首次解锁后可读」是数据保护钥匙串的概念。macOS 上 SecItemAdd 默认
        // 走的是老的登录钥匙串，它不认这条属性，某些版本会直接拿 errSecParam
        // 打回来 —— 那样 macOS 版就成了「永远存不进去」，且只在真机上才现形。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif

        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
