import Foundation

/// 队列里的一个下载任务。标题和封面靠入队后的预取填上，
/// 在那之前界面显示 BV 号。
public struct DownloadJob: Identifiable, Hashable, Sendable, Codable {

    public enum State: Hashable, Sendable {
        case queued
        /// 展开短链 / 拉视频信息 / 取流
        case resolving
        case downloading
        case remuxing
        case saving
        /// 用户点了条目停下来的。不做断点续传，进度已经丢干净了
        case stopped
        case finished
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .resolving, .downloading, .remuxing, .saving: return true
            case .queued, .stopped, .finished, .failed: return false
            }
        }

        /// 已经有结果的（完成或失败）。这种的不该再被停止/继续碰到。
        public var isSettled: Bool {
            switch self {
            case .finished, .failed: return true
            default: return false
            }
        }

        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public let id: UUID
    public let ref: VideoRef
    public let kind: DownloadKind

    public var title: String
    public var coverURL: URL?
    /// 请求的分 P。多 P 视频才有值，决定文件名里要不要带 _P编号。
    public var pageNumber: Int?
    public var pageTitle: String?
    /// 这个视频总共有几 P，拉到信息前是 nil
    public var pageCount: Int?

    /// 实际挑中的那路流是什么画质（编号见 `QualityName`）。
    ///
    /// 取流那一刻才知道，所以排队中的任务还没有 —— 界面上的封面角标
    /// 就等它有值了才画。
    public var qualityID: Int?

    /// 预取阶段存下来的，下载时就不用再问一遍接口
    public var resolvedBVID: String?
    public var cid: Int?
    /// 预取试过了（成功或失败都算），避免失败时反复重试卡住队列
    public var metadataPrefetched: Bool

    public var progress: Double
    public var state: State

    public init(ref: VideoRef, kind: DownloadKind = .audiovisual, pageNumber: Int? = nil) {
        self.id = UUID()
        self.ref = ref
        self.kind = kind
        self.title = ""
        self.pageNumber = pageNumber
        self.qualityID = nil
        self.metadataPrefetched = false
        self.progress = 0
        self.state = .queued
    }

    public var refKey: String { ref.key }

    /// 多 P 视频（已经知道总 P 数且大于 1）
    public var isMultiPage: Bool {
        if let count = pageCount, count > 1 { return true }
        if let page = pageNumber, page > 1 { return true }
        return false
    }

    public var displayTitle: String {
        title.isEmpty ? refKey : title
    }

    /// 分 P 副标题（P3 第三话）。多 P 视频才有，选的正好是 P1 也算 ——
    /// 只看 pageNumber > 1 的话，多 P 视频选 P1 会装得跟普通视频一样。
    public var subtitle: String? {
        guard isMultiPage else { return nil }
        let page = pageNumber ?? 1
        if let pageTitle, !pageTitle.isEmpty { return "P\(page) \(pageTitle)" }
        return "P\(page)"
    }

    /// 状态行末尾那个短标记：[P1]。也是多 P 视频才有。
    public var pageBadge: String? {
        guard isMultiPage else { return nil }
        return "[P\(pageNumber ?? 1)]"
    }

    /// 封面右下角那个小气泡里的字。没得显示就返回 nil，那一格就不画。
    ///
    /// 只有视频这档要看画质，而画质得等取流 —— 所以排队中的视频任务
    /// 这会儿还没有气泡。与其先编一个再改，不如先不显示。
    public var coverBadge: String? {
        switch kind {
        case .cover: return "封面"
        case .audioOnly: return "音频"
        case .audiovisual, .videoOnly:
            guard let qualityID else { return nil }
            return QualityName.badgeName(for: qualityID)
        }
    }

    /// 命名：BV号_视频标题_P编号，P编号只在多 P 时出现
    public func fileName(ext: String) -> String {
        // 短链展开后就知道真 BV 号了，用它命名。
        // 退而求其次也得洗一遍：refKey 对短链来说是「b23.tv/xxxx」，
        // 里面那个斜杠会被 appendingPathComponent 当成子目录，落盘必失败。
        var parts = [Self.sanitize(resolvedBVID ?? refKey)]
        if !title.isEmpty { parts.append(Self.sanitize(title)) }
        if isMultiPage, let page = pageNumber { parts.append("P\(page)") }
        return parts.joined(separator: "_") + "." + ext
    }

    /// 文件名里不能出现的字符直接去掉
    public static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: illegal).joined()
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

// 带关联值的枚举没法定制合成结果，手写一遍。
// 落盘只为了重启后还能看到列表，历史版本多出来的字段一律当 queued。
extension DownloadJob.State: Codable {

    private enum CodingKeys: String, CodingKey {
        case status
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "resolving": self = .resolving
        case "downloading": self = .downloading
        case "remuxing": self = .remuxing
        case "saving": self = .saving
        case "stopped": self = .stopped
        // 旧版本落盘的是 paused，读回来当 stopped
        case "paused": self = .stopped
        case "finished": self = .finished
        case "failed":
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self = .failed(message ?? "下载失败")
        default:
            self = .queued
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try container.encode("queued", forKey: .status)
        case .resolving: try container.encode("resolving", forKey: .status)
        case .downloading: try container.encode("downloading", forKey: .status)
        case .remuxing: try container.encode("remuxing", forKey: .status)
        case .saving: try container.encode("saving", forKey: .status)
        case .stopped: try container.encode("stopped", forKey: .status)
        case .finished: try container.encode("finished", forKey: .status)
        case .failed(let message):
            try container.encode("failed", forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }
}
