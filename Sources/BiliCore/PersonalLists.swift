import Foundation

/// 追番 / 追剧列表里的一季。
///
/// 列表里的条目是**一整季**，不是单个视频：接口只给 `season_id`，没有 bvid ——
/// 分集得拿着 season_id 再去问一次（见 `BiliClient.seasonEpisodes`）。
/// 所以这两页是「先挑哪一季，再挑哪几集」，跟订阅合集是同一个形状。
public struct FollowedSeason: Sendable, Hashable, Identifiable {

    public let seasonID: Int
    public let title: String
    public let coverURL: URL?
    /// 一共几集
    public let episodeCount: Int
    /// 「更新至第220话」。还没开播或者接口没给就是空串，界面上那一行就空着。
    public let progressText: String

    public var id: Int { seasonID }

    public init(seasonID: Int, title: String, coverURL: URL?, episodeCount: Int, progressText: String) {
        self.seasonID = seasonID
        self.title = title
        self.coverURL = coverURL
        self.episodeCount = episodeCount
        self.progressText = progressText
    }
}

/// 历史记录的翻页游标。
///
/// 历史**不按页号翻**，只认上一页返回的这个三元组：页码那套在这儿没有意义
/// （历史是随时在长的，第 2 页跟第 1 页之间还夹着新记录）。所以翻页状态得跟着
/// 页面走：第一页传 nil，之后把上一次拿到的原样递回去。
public struct HistoryCursor: Sendable, Hashable {

    public let max: Int
    public let viewAt: Int
    public let business: String

    public init(max: Int, viewAt: Int, business: String) {
        self.max = max
        self.viewAt = viewAt
        self.business = business
    }
}
