import Foundation

/// 一个待下载视频的标识。只有 BV / av 号足够发起请求，
/// 短链必须先联网跟随重定向才知道指向哪个视频。
public enum VideoRef: Hashable, Sendable, Codable {
    case bvid(String)
    case avid(Int)
    /// 形如 https://b23.tv/xxxxx，这里存的是末段 code，需联网展开
    case shortLink(String)

    public var key: String {
        switch self {
        case .bvid(let b): return b
        case .avid(let a): return "av\(a)"
        case .shortLink(let code): return "b23.tv/\(code)"
        }
    }

    public var isResolved: Bool {
        if case .shortLink = self { return false }
        return true
    }

    /// 这个视频在网页版的地址。列表里的「复制视频链接」和失败报告都用它 ——
    /// 同一串地址写两处，早晚有一处忘了跟着改。
    public var webURL: String {
        switch self {
        case .bvid(let bvid): return "https://www.bilibili.com/video/\(bvid)"
        case .avid(let aid): return "https://www.bilibili.com/video/av\(aid)"
        case .shortLink(let code): return "https://b23.tv/\(code)"
        }
    }
}

/// 从一段用户输入里解析出来的目标。分 P 信息只在链接带 `?p=` 时才存在。
public struct ParsedTarget: Hashable, Sendable, Identifiable {
    public let ref: VideoRef
    /// 链接里的 `?p=` 参数，没有就是 nil
    public let page: Int?

    public init(ref: VideoRef, page: Int? = nil) {
        self.ref = ref
        self.page = page
    }

    /// 去重用的身份：同一个视频的同一 P 只算一个任务
    public var identity: String {
        "\(ref.key)#\(page ?? 1)"
    }

    public var id: String { identity }
}
