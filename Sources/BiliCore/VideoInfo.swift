import Foundation

/// 一个分 P。单 P 视频也有一页，`page` 就是 1。
public struct VideoPage: Sendable, Hashable, Identifiable {
    public let cid: Int
    public let page: Int
    public let title: String
    public let duration: Int

    public var id: Int { cid }

    public init(cid: Int, page: Int, title: String, duration: Int) {
        self.cid = cid
        self.page = page
        self.title = title
        self.duration = duration
    }
}

public struct VideoInfo: Sendable, Hashable {
    public let bvid: String
    public let aid: Int
    public let title: String
    public let coverURL: URL?
    public let ownerName: String
    public let pages: [VideoPage]
    /// 付费 / 充电专属：是的话列表里会在封面左下角挂一枚粉色的标记
    /// （见 `CoverThumbnail.isPremium`）。
    ///
    /// 就一个问题 ——「要不要挂标记」。接口那边「充电专属」「UGC 付费」「PGC 付费」
    /// 是分开的三个字段（见 `BiliClient.videoInfo`），到这儿都不分了：
    /// 用户看到的都是「这条我可能下不了」，分三种写法只是多三处要维护。
    ///
    /// 问不到的（断网、被风控拦）一律 false。标记这事**不猜**：
    /// 猜错了就是给一条正常视频挂个「要钱」的牌子。
    public let isPremium: Bool

    public init(
        bvid: String,
        aid: Int,
        title: String,
        coverURL: URL?,
        ownerName: String,
        pages: [VideoPage],
        isPremium: Bool = false
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.pages = pages
        self.isPremium = isPremium
    }

    public var isMultiPage: Bool { pages.count > 1 }

    public func page(number: Int) -> VideoPage? {
        pages.first { $0.page == number }
    }
}
