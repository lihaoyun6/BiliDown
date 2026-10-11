import Foundation

/// 列表顶上那个搜索框的匹配规则。收藏夹、合集、视频三处都用它，
/// 免得同一个「怎么算匹配上」在三处各写一遍、还各写得不一样。
public enum SearchFilter {

    /// 关键词为空就原样返回（没搜索时不筛东西）；
    /// 否则拿 `fields` 给出的几个字段去模糊匹配，命中任意一个就算。
    ///
    /// 用 `localizedCaseInsensitiveContains` 而不是 `contains`：
    /// 中文标题里常夹着英文（BV 号、番剧名），大小写不该成为搜不到的理由。
    public static func match<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return items }
        return items.filter { item in
            fields(item).contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }
}
