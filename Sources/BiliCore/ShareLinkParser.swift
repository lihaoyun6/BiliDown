import Foundation

/// 所有输入入口（分享链接、手输、剪贴板、批量粘贴）最终都汇到这里：
/// 一段任意文本进去，一个或多个待下载目标出来。
public enum ShareLinkParser {

    /// 三种可识别形态，按优先级排列：短链 > BV 号 > av 号
    private static let targetRegex = try! NSRegularExpression(
        pattern: "(https?://b23\\.tv/[0-9A-Za-z]+)|(BV[0-9A-Za-z]{10})|((?<![0-9A-Za-z])[aA][vV][0-9]{1,15})"
    )

    private static let pageRegex = try! NSRegularExpression(pattern: "[?&]p=(\\d+)")

    /// UP 主主页和合集。第一组是 mid，第二组是合集的 season_id（主页链接没有）。
    private static let bulkRegex = try! NSRegularExpression(
        pattern: "https?://space\\.bilibili\\.com/(\\d+)(?:/lists/(\\d+))?"
    )

    /// 输入框用的解析：单个视频和整批来源混在一起，按在文本里出现的先后排。
    /// 用户贴进去什么顺序，列表里就什么顺序。
    public static func parseEntries(_ text: String) -> [InputEntry] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        var positioned: [(Int, InputEntry)] = []
        var seen = Set<String>()

        for match in targetRegex.matches(in: text, range: whole) {
            guard let ref = ref(from: match, in: ns, fullText: text) else { continue }
            let target = ParsedTarget(ref: ref, page: pageNumber(near: match.range, in: ns, fullText: text))
            let entry = InputEntry.video(target)
            if seen.insert(entry.id).inserted {
                positioned.append((match.range.location, entry))
            }
        }

        for match in bulkRegex.matches(in: text, range: whole) {
            guard let source = bulkSource(from: match, in: ns) else { continue }
            let entry = InputEntry.bulk(source)
            if seen.insert(entry.id).inserted {
                positioned.append((match.range.location, entry))
            }
        }

        return positioned.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 解析文本里出现的全部目标，按出现顺序返回，同一视频的同一 P 去重。
    public static func parseAll(_ text: String) -> [ParsedTarget] {
        let ns = text as NSString
        let matches = targetRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var result: [ParsedTarget] = []

        for match in matches {
            guard let ref = ref(from: match, in: ns, fullText: text) else { continue }
            let page = pageNumber(near: match.range, in: ns, fullText: text)
            let target = ParsedTarget(ref: ref, page: page)
            if seen.insert(target.identity).inserted {
                result.append(target)
            }
        }
        return result
    }

    /// 只要一个目标时用这个（手输框即时预览）。
    public static func parse(_ text: String) -> ParsedTarget? {
        parseAll(text).first
    }

    // MARK: - 私有

    private static func ref(from match: NSTextCheckingResult, in ns: NSString, fullText: String) -> VideoRef? {
        if match.range(at: 1).location != NSNotFound {
            let urlString = ns.substring(with: match.range(at: 1))
            let code = urlString.split(separator: "/").last.map(String.init) ?? urlString
            return .shortLink(code)
        }
        if match.range(at: 2).location != NSNotFound {
            return .bvid(ns.substring(with: match.range(at: 2)))
        }
        if match.range(at: 3).location != NSNotFound {
            // 去掉开头的 av / AV
            let raw = ns.substring(with: match.range(at: 3)).dropFirst(2)
            if let avid = Int(raw) { return .avid(avid) }
        }
        return nil
    }

    /// 主页链接：/lists/ 后面跟着非数字的话不当合集处理。
    /// 那种情况退回「这个 UP 的全部投稿」等于下几百个视频，
    /// 跟用户点进去的那个合集八竿子打不着，宁可不认。
    private static func bulkSource(from match: NSTextCheckingResult, in ns: NSString) -> BulkSource? {
        guard match.range(at: 1).location != NSNotFound,
              let mid = Int(ns.substring(with: match.range(at: 1))) else { return nil }

        if match.range(at: 2).location != NSNotFound,
           let seasonID = Int(ns.substring(with: match.range(at: 2))) {
            return .collection(mid: mid, seasonID: seasonID)
        }

        let end = match.range.location + match.range.length
        let tailLength = min(6, ns.length - end)
        if tailLength == 6, ns.substring(with: NSRange(location: end, length: 6)) == "/lists" {
            return nil
        }

        return .uploads(mid: mid)
    }

    /// `?p=` 必须和视频号在同一个「词」里才算数，
    /// 否则批量粘贴时后面那一行的分 P 会串到前面那一行去。
    private static func pageNumber(near range: NSRange, in ns: NSString, fullText: String) -> Int? {
        let token = tokenRange(containing: range, in: ns)
        guard token.length > 0 else { return nil }
        let tokenString = ns.substring(with: token)
        guard let m = pageRegex.firstMatch(
            in: tokenString,
            range: NSRange(location: 0, length: (tokenString as NSString).length)
        ), m.range(at: 1).location != NSNotFound else { return nil }

        let value = (tokenString as NSString).substring(with: m.range(at: 1))
        guard let page = Int(value), page > 0 else { return nil }
        return page
    }

    /// 向两侧扩张到最近的空白字符，得到包含该匹配的连续非空白片段。
    private static func tokenRange(containing range: NSRange, in ns: NSString) -> NSRange {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        while start > 0 {
            let scalar = ns.character(at: start - 1)
            guard let u = UnicodeScalar(scalar), !whitespace.contains(u) else { break }
            start -= 1
        }
        var end = range.location + range.length
        while end < ns.length {
            let scalar = ns.character(at: end)
            guard let u = UnicodeScalar(scalar), !whitespace.contains(u) else { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }
}
