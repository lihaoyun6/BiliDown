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

    public init(bvid: String, aid: Int, title: String, coverURL: URL?, ownerName: String, pages: [VideoPage]) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.ownerName = ownerName
        self.pages = pages
    }

    public var isMultiPage: Bool { pages.count > 1 }

    public func page(number: Int) -> VideoPage? {
        pages.first { $0.page == number }
    }
}
