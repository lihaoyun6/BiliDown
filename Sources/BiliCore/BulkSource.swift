import Foundation

/// 一次能带出一整批视频的来源：UP 主投稿、合集。
/// 这种链接没法直接变成一个任务，得先联网展开成视频列表。
public enum BulkSource: Hashable, Sendable, Identifiable {

    /// UP 主的全部投稿
    case uploads(mid: Int)
    /// UP 主名下的某一个合集
    case collection(mid: Int, seasonID: Int)

    public var mid: Int {
        switch self {
        case .uploads(let mid): return mid
        case .collection(let mid, _): return mid
        }
    }

    public var seasonID: Int? {
        if case .collection(_, let seasonID) = self { return seasonID }
        return nil
    }

    public var isCollection: Bool { seasonID != nil }

    public var id: String {
        switch self {
        case .uploads(let mid): return "space:\(mid)"
        case .collection(let mid, let seasonID): return "season:\(mid):\(seasonID)"
        }
    }
}

/// 输入框里解析出来的一条：要么是单个视频，要么是一整批的来源。
/// 两者混在一起按出现顺序排，用户看到的就是自己贴进去的顺序。
public enum InputEntry: Hashable, Sendable, Identifiable {
    case video(ParsedTarget)
    case bulk(BulkSource)

    public var id: String {
        switch self {
        case .video(let target): return "v:" + target.identity
        case .bulk(let source): return "b:" + source.id
        }
    }

    public var video: ParsedTarget? {
        if case .video(let target) = self { return target }
        return nil
    }

    public var bulk: BulkSource? {
        if case .bulk(let source) = self { return source }
        return nil
    }
}

/// UP 主信息，主页那条解析结果用它的名字和头像。
public struct UserProfile: Hashable, Sendable {
    public let mid: Int
    public let name: String
    public let avatarURL: URL?

    public init(mid: Int, name: String, avatarURL: URL?) {
        self.mid = mid
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// 展开后列表里的一个视频。只要够入队和显示就行，详细信息等下载时再拉。
public struct BulkVideo: Hashable, Sendable, Identifiable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    /// 秒。接口给的是 "12:34" 这种字符串，解析失败时是 0
    public let duration: Int
    /// 这个视频有几 P。多 P 的要展开成多个任务
    public let pageCount: Int
    /// 付费 / 充电专属（判据见 `VideoInfo.isPremium`）。
    ///
    /// **nil = 不知道**，不是「不要钱」：投稿、合集、追番这几条路都报，
    /// 但 `collectedItems` 认不出「订阅的是收藏夹」时会落到收藏夹接口上，
    /// 那边一个付费字段都没有，出来的就是 nil（见 `FavItem.isPremium`）。
    /// 补问那一步封存着，所以这种 nil 现在没人管，界面上就是不挂标记。
    public let isPremium: Bool?

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        duration: Int,
        pageCount: Int,
        isPremium: Bool? = nil
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.duration = duration
        self.pageCount = pageCount
        self.isPremium = isPremium
    }

    public var id: String { bvid }
    public var isMultiPage: Bool { pageCount > 1 }

    /// 失效的稿件（判据见 InvalidPlaceholder）
    public var isAvailable: Bool {
        !bvid.isEmpty && title != InvalidPlaceholder.video
    }
}

/// 一页展开结果。第一页额外带上来源自己的信息（UP 主是谁 / 合集叫什么），
/// 后面的页只有视频列表，别的字段是 nil。
public struct BulkResult: Hashable, Sendable {
    public let videos: [BulkVideo]
    public let total: Int
    public let hasMore: Bool
    /// 主页来源才有
    public let profile: UserProfile?
    /// 合集来源才有
    public let collectionTitle: String?
    public let collectionCoverURL: URL?
    public let collectionID: Int?

    public init(
        videos: [BulkVideo],
        total: Int,
        hasMore: Bool,
        profile: UserProfile? = nil,
        collectionTitle: String? = nil,
        collectionCoverURL: URL? = nil,
        collectionID: Int? = nil
    ) {
        self.videos = videos
        self.total = total
        self.hasMore = hasMore
        self.profile = profile
        self.collectionTitle = collectionTitle
        self.collectionCoverURL = collectionCoverURL
        self.collectionID = collectionID
    }
}

/// 我的收藏页里「合集」那一栏：别人（或自己）的合集，我订阅了它。
public struct SubscribedCollection: Hashable, Sendable, Identifiable {
    /// 合集 id，也就是 season_id
    public let seasonID: Int
    public let mid: Int
    public let title: String
    public let coverURL: URL?
    public let videoCount: Int
    /// 合集的 UP 主
    public let ownerName: String

    public init(seasonID: Int, mid: Int, title: String, coverURL: URL?, videoCount: Int, ownerName: String = "") {
        self.seasonID = seasonID
        self.mid = mid
        self.title = title
        self.coverURL = coverURL
        self.videoCount = videoCount
        self.ownerName = ownerName
    }

    public var id: Int { seasonID }
    public var source: BulkSource { .collection(mid: mid, seasonID: seasonID) }

    /// 这一条是不是「该合集已失效」那种。
    /// 失效的合集还留在订阅列表里，但点进去一个视频都没有，只有标题变成这句。
    public var isAvailable: Bool { title != InvalidPlaceholder.collection }
}
