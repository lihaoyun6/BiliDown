import Foundation
import WebKit

/// 从持久化的 WKWebView Cookie 库里读出登录凭证。
/// 登录页和之后所有的 API 请求共用同一个 Cookie 库，所以这里读到的就是真的登录态。
///
/// 整个类型锁在主线程上：WKWebsiteDataStore 的这几个方法都会进 WebKit 的
/// 网络进程，在别的线程上调会直接撞断言（SIGTRAP），退出登录就闪退。
@MainActor
public enum BiliCookieStore {

    private static let domainSuffix = "bilibili.com"

    /// 读当前 Cookie 库。没登录就返回 nil。
    public static func currentCredential() async -> BiliCredential? {
        let cookies = await allCookies()
        let bili = cookies.filter { $0.domain.hasSuffix(domainSuffix) }
        let sessData = bili.first { $0.name == "SESSDATA" }?.value ?? ""
        guard !sessData.isEmpty else { return nil }

        return BiliCredential(
            cookieHeader: bili.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            sessData: sessData,
            biliJct: bili.first { $0.name == "bili_jct" }?.value ?? "",
            userId: bili.first { $0.name == "DedeUserID" }?.value ?? ""
        )
    }

    public static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// 退出登录：清掉 B 站相关的全部 Cookie 和站点数据
    public static func clearAll() async {
        let store = WKWebsiteDataStore.default()

        let cookies = await allCookies()
        for cookie in cookies where cookie.domain.hasSuffix(domainSuffix) {
            await withCheckedContinuation { continuation in
                store.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }

        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let biliRecords = records.filter { $0.displayName.contains("bilibili") }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: biliRecords) { continuation.resume() }
        }
    }
}
