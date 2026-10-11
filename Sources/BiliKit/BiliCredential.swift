import Foundation

/// 从 B 站官方登录页拿到的 Cookie 集合。
/// 只存 Cookie，永远不会有账号密码——密码从来没离开过 B 站自己的页面。
public struct BiliCredential: Codable, Sendable, Equatable {

    /// 直接塞进请求头用的完整 Cookie 串
    public let cookieHeader: String
    public let sessData: String
    /// CSRF token，写操作（比如读收藏夹）要带上
    public let biliJct: String
    public let userId: String
    public let savedAt: Date

    public init(cookieHeader: String, sessData: String, biliJct: String, userId: String, savedAt: Date = Date()) {
        self.cookieHeader = cookieHeader
        self.sessData = sessData
        self.biliJct = biliJct
        self.userId = userId
        self.savedAt = savedAt
    }

    public var hasSession: Bool { !sessData.isEmpty }
}
