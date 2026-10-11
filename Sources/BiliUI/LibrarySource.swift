import Foundation
import BiliCore

/// 一页「一堆视频，勾几个下载」的来源。收藏夹、合集、一季番剧、稍后再看、
/// 历史记录点进去之后长得一模一样：都是勾选 + 入队那套，区别只在标题、
/// 空态那几句话和从哪个接口拉，所以合成一个来源类型，界面共用一套。
public enum LibrarySource: Hashable {

    case folder(FavFolder)
    case collection(SubscribedCollection)
    /// 一季番剧 / 剧集。分集从 PGC 接口拉（见 BiliClient.seasonEpisodes）。
    case season(FollowedSeason)

    /// 下面这两个也是**自己一页**的来源：从「更多」（iOS）和侧边栏（mac）直接进去，
    /// 没有上一层列表。
    case watchLater
    case history

    public var title: String {
        switch self {
        case .folder(let folder): return folder.title
        case .collection(let collection): return collection.title
        case .season(let season): return season.title
        case .watchLater: return "稍后再看"
        case .history: return "历史记录"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .folder: return "空收藏夹"
        case .collection: return "空合集"
        case .season: return "这一季还没有分集"
        case .watchLater: return "稍后再看是空的"
        case .history: return "没有观看记录"
        }
    }

    public var errorTitle: String {
        switch self {
        case .folder: return "读不到这个收藏夹"
        case .collection: return "读不到这个合集"
        case .season: return "读不到这一季的分集"
        case .watchLater: return "读不到稍后再看"
        case .history: return "读不到历史记录"
        }
    }

    /// 里面一共多少个视频 —— **全选**的时候拿它算数。不知道就是 nil。
    ///
    /// 收藏夹 / 合集 / 一季番剧的数量是接口直接给的，能用。
    /// 稍后再看和历史记录不给总数（历史是游标翻页，翻到哪算哪），是 nil ——
    /// 但它们**还有没有全选那一行是另一回事**（见 `supportsSelectAll`）。
    public var videoCount: Int? {
        switch self {
        case .folder(let folder): return folder.mediaCount
        case .collection(let collection): return collection.videoCount
        case .season(let season): return season.episodeCount
        case .watchLater, .history: return nil
        }
    }

    /// 这一页摆不摆「全选」那一行。
    ///
    /// 摆的前提是那个「全都要」的数目**报得出来**。收藏夹 / 合集 / 一季番剧靠
    /// `videoCount`（接口给的），翻完页之后列表页还会自己数一遍。
    ///
    /// 稍后再看也摆：它一次给全（B 站这个列表封顶 100 条，没有下一页），
    /// 点开列表就已经是全部，数手里这一份就是准数（见列表页里的 `selectedCount`）。
    ///
    /// 历史记录**不摆**：它是游标翻页的，往下能一直翻，翻到哪算哪 ——
    /// 一个报不出数来的「全选」点下去，只会让所有行都看着勾上了、
    /// 按钮却是灰的。
    public var supportsSelectAll: Bool {
        switch self {
        case .folder, .collection, .season, .watchLater: return true
        case .history: return false
        }
    }

    /// 这个来源是不是**自己一页**的（追番分集 / 稍后再看 / 历史记录）。
    ///
    /// 收藏夹和合集是从上一层的列表里点进来的，所以它们的名字挂在列表里
    ///（iOS 上「全选」那一行的右端），标题栏统一叫「选择视频」——
    /// 见 VideoPickerView。自己一页的那几个没有上一层，页名就是它的名字：
    /// 标题栏得写自己的名字，列表里那一格改成报已选数量（跟 mac 一样）。
    public var isStandalone: Bool {
        switch self {
        case .folder, .collection: return false
        case .season, .watchLater, .history: return true
        }
    }
}

/// 一页「列表的列表」：收藏夹、我订阅的合集、我的追番、我的追剧。
///
/// 这四页点进去之后都是一层**列表**（夹子 / 合集 / 一季），再点一层才是视频 ——
/// 所以跟 `LibrarySource` 不是一回事：那个是「视频列表」，这个是「列表列表」。
/// 标题和几句提示文案都摆在这儿，iOS 和 mac 两个列表页共用（mac 那份多一个
/// `favorites`：iOS 的收藏是标签栏自己一整页，不走这个）。
public enum LibraryListKind: Hashable {

    case favorites
    case collections
    case bangumi
    case drama

    public var title: String {
        switch self {
        case .favorites: return "收藏"
        case .collections: return "合集"
        case .bangumi: return "我的追番"
        case .drama: return "我的追剧"
        }
    }

    public var searchPrompt: String {
        switch self {
        case .favorites: return "搜索收藏夹"
        case .collections: return "搜索合集"
        case .bangumi, .drama: return "搜索"
        }
    }

    public var emptyTitle: String {
        switch self {
        case .favorites: return "还没有收藏夹"
        case .collections: return "还没有订阅合集"
        case .bangumi: return "还没有追番"
        case .drama: return "还没有追剧"
        }
    }

    public var emptyMessage: String {
        switch self {
        case .favorites: return "在 B 站建一个收藏夹，这里就能看到。"
        case .collections: return "在 B 站订阅一个合集，这里就能看到。"
        case .bangumi: return "在 B 站追一部番，这里就能看到。"
        case .drama: return "在 B 站追一部剧，这里就能看到。"
        }
    }

    public var errorTitle: String {
        switch self {
        case .favorites: return "读不到收藏夹"
        case .collections: return "读不到合集"
        case .bangumi: return "读不到追番列表"
        case .drama: return "读不到追剧列表"
        }
    }

    /// 空态那块图标。跟侧边栏 / 「更多」里那一格用的是同一个符号。
    public var icon: String {
        switch self {
        case .favorites: return "star"
        case .collections: return "rectangle.stack"
        case .bangumi: return "sparkles.tv"
        case .drama: return "film"
        }
    }

    /// 追番和追剧是同一个接口的两种 type：1 = 番剧（含国创），2 = 影视
    ///（剧 / 电影 / 纪录片 / 综艺）。收藏夹和合集不走它。
    public var bangumiType: Int? {
        switch self {
        case .bangumi: return 1
        case .drama: return 2
        case .favorites, .collections: return nil
        }
    }
}
