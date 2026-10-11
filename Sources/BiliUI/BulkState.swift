import Foundation
import BiliCore

/// 一个整批来源（UP 主投稿 / 合集）目前拉到手的东西。
/// 「添加任务」那一页和接分享那条路都用它，所以放共享层。
public struct BulkState {

    public var videos: [BulkVideo]
    public var total: Int
    public var hasMore: Bool
    public var nextPage: Int
    public var profile: UserProfile?
    public var collectionTitle: String?
    public var collectionCover: URL?

    public init(result: BulkResult) {
        self.videos = result.videos
        self.total = result.total
        self.hasMore = result.hasMore
        self.nextPage = 2
        self.profile = result.profile
        self.collectionTitle = result.collectionTitle
        self.collectionCover = result.collectionCoverURL
    }
}
