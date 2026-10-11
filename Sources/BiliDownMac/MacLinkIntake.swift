import Foundation
import BiliCore

/// 「外面的链接怎么进来」这件事在 macOS 上收敛成三条：
/// URL Scheme（快捷指令 / 浏览器）、剪贴板、以及用户直接粘进添加页。
/// 这一层只管**认**，不管**做** —— 拿到什么交给界面决定，
/// 好让 MacRootView 一处就能说清「链接进来之后会发生什么」。
enum MacLinkIntake {

    /// `bilidown://add?url=<百分号编码的原始链接>`
    ///
    /// 跟 iOS 版同一个约定：接收端其实只认字符串里那个链接，
    /// 路径和参数名叫什么都不挑。所以这儿也不去纠结 host/path 的写法，
    /// 把整个 URL 拆出来的参数值或者整串里能认出来的 bilibili 链接都收。
    static func link(in url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // 正常写法：?url=...
        if let value = components?.queryItems?.first(where: { $0.name == "url" })?.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        // 有人直接把链接当参数值糊在后面（bilidown://add?https://b23.tv/xxx）
        // 或者干脆整串塞进来。这两种 URLComponents 都给不出干净的 query，
        // 退回「从字符串里薅一个 bilibili 链接」。
        return firstBilibiliLink(in: url.absoluteString)
    }

    /// 从一段自由文本里薅出第一个能认的 bilibili 链接。
    /// 判据直接借 parseEntries —— 它认什么这儿就认什么，不另立一套标准。
    static func firstBilibiliLink(in text: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>"))
        let stripped = text.hasPrefix("bilidown://") ? String(text.dropFirst("bilidown://".count)) : text

        for token in stripped.components(separatedBy: separators) where !token.isEmpty {
            if !ShareLinkParser.parseEntries(token).isEmpty { return token }
        }
        return nil
    }

    /// 一段文本 → 待添加条目。空的就说明这串东西里没有能下的。
    static func entries(from text: String) -> [InputEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return ShareLinkParser.parseEntries(trimmed)
    }
}
