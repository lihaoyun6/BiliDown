import Foundation
import Security

/// 登录态。凭证落在 Keychain，退出登录时连同 WebView 的 Cookie 一起清掉。
@MainActor
public final class AccountStore: ObservableObject {

    private static let keychainAccount = "bilibili-credential"

    @Published public private(set) var credential: BiliCredential?
    /// 昵称。网络拉一次就缓存住，免得每次冷启动都要等一次请求。
    @Published public private(set) var userName: String?
    /// 头像地址。缓存的道理跟昵称一样 —— 冷启动那一瞬间侧边栏就有东西可画。
    @Published public private(set) var avatarURL: URL?
    /// 钥匙串写不进去时留给界面看的一句话，nil 表示一切正常。
    @Published public private(set) var keychainWarning: String?

    private let client = BiliClient()

    public var isLoggedIn: Bool {
        credential?.hasSession == true
    }

    /// 设置页那行显示什么：有昵称用昵称，没拉到就退回「已登录」。
    public var displayName: String {
        guard let userName, !userName.isEmpty else { return "已登录" }
        return userName
    }

    public init() {
        credential = Self.loadFromKeychain()
        if let uid = credential?.userId, !uid.isEmpty {
            userName = UserDefaults.standard.string(forKey: Self.userNameKey(uid))
            avatarURL = UserDefaults.standard.string(forKey: Self.avatarKey(uid)).flatMap(URL.init(string:))
        }
    }

    /// 冷启动兜底：钥匙串里读不出登录态时，去 WebView 的 Cookie 库里再捞一次。
    ///
    /// 钥匙串和 Cookie 库是两套彼此独立的持久化，会各自出事。自签 / 侧载的
    /// App 换过签名主体之后，钥匙串里的东西会因为访问组对不上而读不到
    /// （访问组是 `<TeamID>.<bundleID>`，跟着签名走），Cookie 库却待在 App 的
    /// 数据容器里，完好无损。
    ///
    /// 这时候的表现就是最让人摸不着头脑的那一种：每次冷启动都显示未登录，
    /// 但一点「登录」，登录页刚一加载就自个儿登回去了 —— 因为 Cookie 其实还在。
    ///
    /// 所以把 Cookie 库当第二事实来源：捞到了就认，并顺手补写回钥匙串。
    /// 正常情况下（钥匙串好好的）这里是一句空转。
    @discardableResult
    public func restoreFromCookiesIfNeeded() async -> Bool {
        guard !isLoggedIn else { return false }

        // 冷启动那一瞬间问 WKWebsiteDataStore 要 Cookie，它很可能回你一个空的 ——
        // 不是「没登录」，是那个库还没从磁盘读上来。WebKit 的 Cookie 库是懒加载的，
        // 头一次问它的时候网络进程可能都还没起来。
        //
        // 这一下就是那个很邪门的现象的来源：冷启动显示未登录，用户一点「登录」，
        // 登录页刚把 WKWebView 建出来（网络进程这才起来、Cookie 库这才读上来），
        // 还没等输账号它就自己登回去了 —— 网页一闪而过。
        //
        // 所以空手而归不算数，隔一会儿再问。真没登录的话这几十毫秒也白等不了什么。
        // 第一次立刻问，之后按 150/250/400/600/800 毫秒的间隔再问五轮，
        // 一共等两秒出头。真登录了的话第一轮就命中了，这个循环一次都不转。
        for (index, delay) in [0, 150, 250, 400, 600, 800].enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
            if let fromCookies = await BiliCookieStore.currentCredential() {
                adopt(fromCookies)
                return true
            }
        }
        return false
    }

    public func save(_ credential: BiliCredential) {
        adopt(credential)
    }

    private func adopt(_ credential: BiliCredential) {
        if let data = try? JSONEncoder().encode(credential) {
            let status = KeychainStore.save(data, account: Self.keychainAccount)
            if status == errSecSuccess {
                keychainWarning = nil
            } else {
                // 写不进钥匙串**不等于**登录态留不住。
                //
                // 侧载 / LiveContainer 里跑的 App 拿不到 application-identifier
                // 那条 entitlement，钥匙串一律回 -34018（errSecMissingEntitlement）——
                // 这不是我们代码的问题，是签名的事（见 KeychainStore 里那段注释）。
                // 而 Cookie 库待在 App 自己的容器里，压根不看 entitlement，完好无损。
                //
                // 所以别急着喊。先去 Cookie 库确认一下：那边有，就是「换了个地方存」，
                // 冷启动照样能捞回来，报这个错只会让人以为坏了。
                Task {
                    let covered = await BiliCookieStore.currentCredential() != nil
                    keychainWarning = covered ? nil : """
                        登录态没能存进钥匙串（错误码 \(status)），Cookie 库里也没找到。\
                        下次启动可能得重新登一次。
                        """
                }
            }
        } else {
            keychainWarning = "登录态序列化失败，写不进钥匙串。"
        }

        self.credential = credential
        // 昵称和头像先用缓存顶上，网上那份随后校准 —— 免得界面先闪一下「已登录」
        if !credential.userId.isEmpty {
            userName = UserDefaults.standard.string(forKey: Self.userNameKey(credential.userId))
            avatarURL = UserDefaults.standard.string(forKey: Self.avatarKey(credential.userId))
                .flatMap(URL.init(string:))
        }
        Task { await refreshProfile() }
    }

    /// 拉一次昵称和头像。已登录时冷启动也调一下，顺手校准缓存。
    public func refreshProfile() async {
        guard isLoggedIn, let credential, !credential.userId.isEmpty else { return }
        await client.setCredential(credential)
        guard let profile = try? await client.navProfile() else { return }
        userName = profile.name
        avatarURL = profile.avatarURL
        UserDefaults.standard.set(profile.name, forKey: Self.userNameKey(credential.userId))
        UserDefaults.standard.set(profile.avatarURL?.absoluteString, forKey: Self.avatarKey(credential.userId))
    }

    /// 必须等 Cookie 清完再返回 —— 否则用户马上点登录，
    /// WebView 里还是上一份会话，直接又登回原来那个号。
    public func logout() async {
        KeychainStore.delete(account: Self.keychainAccount)
        credential = nil
        userName = nil
        avatarURL = nil
        keychainWarning = nil
        await BiliCookieStore.clearAll()
    }

    private static func userNameKey(_ uid: String) -> String { "userName-\(uid)" }
    private static func avatarKey(_ uid: String) -> String { "avatar-\(uid)" }

    private static func loadFromKeychain() -> BiliCredential? {
        guard let data = KeychainStore.load(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(BiliCredential.self, from: data)
    }
}
