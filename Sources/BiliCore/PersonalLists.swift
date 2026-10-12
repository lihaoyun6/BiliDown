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

/// 一个关注分组 —— 「默认分组」「特别关注」和自己建的那些。
///
/// 关注几十上百号人的话，平铺的关注列表就是一个翻不到底的大长条，
/// 分组是唯一能把特定的人捞出来的东西。所以「我的关注」这条路是
/// 先进分组、再进人，不是一上来就把所有人倒在屏幕上。
public struct FollowGroup: Sendable, Hashable, Identifiable {

    /// 分组 id。`-10` 是「特别关注」、`0` 是「默认分组」—— 这两条是 B 站自己
    /// 的，跟用户建的组混在同一个数组里回来，界面上不用特判。
    public let tagID: Int
    public let name: String
    /// 这一组里有多少人。列表行右边报的就是它。
    public let count: Int

    public var id: Int { tagID }

    public init(tagID: Int, name: String, count: Int) {
        self.tagID = tagID
        self.name = name
        self.count = count
    }
}

/// 「关注」那条路里，中间那一层要看的是谁：某一组，还是**全部关注**。
///
/// 「全部关注」得单列出来，不能当成一个分组混进去：它不是分组 —— 没有 tagid，
/// 走的是另一个接口（`BiliClient.followedUsers`，那边要的是自己的 uid）。
/// 硬塞一个假 tagid 进 `FollowGroup` 是自找麻烦：那套 id 是 B 站定的，
/// `-10`（特别关注）和 `0`（默认分组）都已经被占了。
public enum FollowScope: Sendable, Hashable {

    /// 所有关注的人，不管在哪个分组里。B 站自己那条路的默认视图。
    case all
    /// B 站返回的某一组（「特别关注」「默认分组」和自己建的都在里面）。
    case group(FollowGroup)

    /// 进来之后顶上那条标题。
    public var title: String {
        switch self {
        case .all: return "全部关注"
        case .group(let group): return group.name
        }
    }
}

/// 某个关注分组里的一个人。
public struct FollowedUser: Sendable, Hashable, Identifiable {

    public let mid: Int
    public let name: String
    public let avatarURL: URL?
    /// 个人简介。很多人根本没写，那就是空串。
    public let sign: String

    /// 界面上那一行简介。没填的人给这一句，不留空。
    ///
    /// 空着不行：那一行塌下去，一列扫下来高矮不齐；填个空格也不行 ——
    /// 位置是占住了，但那块地方看着像没加载出来。给句话最省事，而且
    /// 两端（`FollowUsersView` / `MacFollowingsView`）都读这一个，
    /// 不会一边改了另一边还是空格。
    public var signText: String {
        sign.isEmpty ? "这个人没有填简介啊~~~" : sign
    }

    public var id: Int { mid }

    public init(mid: Int, name: String, avatarURL: URL?, sign: String) {
        self.mid = mid
        self.name = name
        self.avatarURL = avatarURL
        self.sign = sign
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
