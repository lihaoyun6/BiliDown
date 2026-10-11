import Foundation

/// B 站给失效内容用的占位标题。
///
/// 这些字符串不是真的标题，是「这条已经没了」的记号。失效的东西本来就下不了、
/// 点进去也只会报错，所以「过滤无效内容」那个开关认的就是这两个词 ——
/// 接口里没有更靠谱的字段可用（失效稿件有时还留着 bvid，光看它不够）。
public enum InvalidPlaceholder {
    /// 收藏夹 / 合集里失效的稿件
    public static let video = "已失效视频"
    /// 订阅列表里失效的合集
    public static let collection = "该合集已失效"
}

/// 一个收藏夹（文件夹）。
public struct FavFolder: Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let mediaCount: Int
    /// B 站把私密收藏夹的 attr 标成 1，界面上给把锁表示一下
    public let isPrivate: Bool

    // 收藏夹没有封面可拿：列表接口不返回，去翻夹子内容又会被风控拦（详见
    // BiliClient.favoriteFolders 那段注释）。所以这里干脆不留字段，
    // 界面上统一用灰底 + 文件夹图标占位。

    public init(id: Int, title: String, mediaCount: Int, isPrivate: Bool = false) {
        self.id = id
        self.title = title
        self.mediaCount = mediaCount
        self.isPrivate = isPrivate
    }
}

/// 收藏夹里的一个视频。
public struct FavItem: Sendable, Hashable, Identifiable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let duration: Int
    public let upperName: String
    /// 总共几 P，列表接口直接带回来的
    public let pageCount: Int

    public var id: String { bvid }

    public var isMultiPage: Bool { pageCount > 1 }

    public init(
        bvid: String,
        title: String,
        coverURL: URL?,
        duration: Int,
        upperName: String,
        pageCount: Int = 1
    ) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.duration = duration
        self.upperName = upperName
        self.pageCount = max(pageCount, 1)
    }

    /// 已失效（被删/被下架）的稿件。B 站有两种写法：
    /// 彻底没了的连 bvid 都不给；另一种留着 bvid，标题直接写成「已失效视频」。
    /// 两种都算不可用 —— 只看 bvid 的话，后一种会带着一个空壳混进列表里。
    public var isAvailable: Bool {
        !bvid.isEmpty && title != InvalidPlaceholder.video
    }
}
