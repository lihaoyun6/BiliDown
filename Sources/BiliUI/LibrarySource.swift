import Foundation
import BiliCore

/// 收藏夹和合集点进去之后长得一模一样：都是「一堆视频，勾几个下载」。
/// 区别只在标题和从哪个接口拉，所以合成一个来源类型，界面共用一套。
public enum LibrarySource: Hashable {

    case folder(FavFolder)
    case collection(SubscribedCollection)

    public var title: String {
        switch self {
        case .folder(let folder): return folder.title
        case .collection(let collection): return collection.title
        }
    }

    public var emptyTitle: String {
        switch self {
        case .folder: return "空收藏夹"
        case .collection: return "空合集"
        }
    }

    public var errorTitle: String {
        switch self {
        case .folder: return "读不到这个收藏夹"
        case .collection: return "读不到这个合集"
        }
    }

    /// 里面一共多少个视频，全选的时候拿它算数
    public var videoCount: Int {
        switch self {
        case .folder(let folder): return folder.mediaCount
        case .collection(let collection): return collection.videoCount
        }
    }
}
