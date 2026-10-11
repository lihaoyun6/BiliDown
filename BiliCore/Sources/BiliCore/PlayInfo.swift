import Foundation

/// DASH 里的单条流。视频和音频各是一串，画质/编码不同的都在里面。
public struct MediaStream: Sendable, Hashable, Identifiable {
    public let url: URL
    /// 画质编号，音频流是音频质量编号
    public let qualityID: Int
    public let bandwidth: Int
    /// 7 = AVC/H.264，12 = HEVC/H.265，13 = AV1
    public let codecID: Int
    public let codecs: String
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    /// 只有音频有，内容完整性校验用的
    public let backupURLs: [URL]

    public var id: String { url.absoluteString }

    public init(
        url: URL,
        qualityID: Int,
        bandwidth: Int,
        codecID: Int,
        codecs: String,
        mimeType: String,
        width: Int? = nil,
        height: Int? = nil,
        backupURLs: [URL] = []
    ) {
        self.url = url
        self.qualityID = qualityID
        self.bandwidth = bandwidth
        self.codecID = codecID
        self.codecs = codecs
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.backupURLs = backupURLs
    }

    public var shortCodecName: String {
        switch codecID {
        case 7: return "H.264"
        case 12: return "H.265"
        case 13: return "AV1"
        default: return codecs
        }
    }
}

public struct PlayInfo: Sendable {
    public let duration: Int
    public let videos: [MediaStream]
    public let audios: [MediaStream]
    /// 当前账号实际能拿到的画质编号
    public let acceptQuality: [Int]

    public init(duration: Int, videos: [MediaStream], audios: [MediaStream], acceptQuality: [Int]) {
        self.duration = duration
        self.videos = videos
        self.audios = audios
        self.acceptQuality = acceptQuality
    }
}

/// 画质编号 → 人话
public enum QualityName {
    public static func name(for id: Int) -> String {
        switch id {
        case 127: return "8K 超高清"
        case 126: return "杜比视界"
        case 125: return "HDR 真彩"
        case 120: return "4K 超清"
        case 116: return "1080P60"
        case 112: return "1080P 高码率"
        case 100: return "智能修复"
        case 80: return "1080P 高清"
        case 74: return "720P60"
        case 64: return "720P 高清"
        case 32: return "480P 清晰"
        case 16: return "360P 流畅"
        case 6: return "240P 极速"
        default: return "画质 \(id)"
        }
    }

    /// 角标那一档短名字。上面那个是给人挑画质时看的，能写一整行；
    /// 这个要压在封面右下角那一小块地方上，所以只留认得出的部分 ——
    /// 「1080P 高清」到这儿就是「1080P」。
    public static func badgeName(for id: Int) -> String {
        switch id {
        case 127: return "8K"
        case 126: return "杜比"
        case 125: return "HDR"
        case 120: return "4K"
        case 116: return "1080P60"
        case 112: return "1080P+"
        case 100: return "智能修复"
        case 80: return "1080P"
        case 74: return "720P60"
        case 64: return "720P"
        case 32: return "480P"
        case 16: return "360P"
        case 6: return "240P"
        // 没见过的编号就把数字原样摆出来 —— 好歹是个线索，
        // 编一个像模像样的「1080P」反而是在骗人。
        default: return "\(id)"
        }
    }
}

/// 从一堆流里挑一条。挑不到指定编码就退而求其次，
/// 优先保证「有得下」，而不是死磕编码。
public enum StreamSelector {

    public static func video(from play: PlayInfo, codec: VideoCodec) -> MediaStream? {
        guard !play.videos.isEmpty else { return nil }
        let wantedCodecID = codec == .h264 ? 7 : 12

        let preferred = play.videos.filter { $0.codecID == wantedCodecID }
        let pool = preferred.isEmpty ? play.videos : preferred

        return pool.max { lhs, rhs in
            if lhs.qualityID != rhs.qualityID { return lhs.qualityID < rhs.qualityID }
            return lhs.bandwidth < rhs.bandwidth
        }
    }

    /// 优先选 AAC。杜比（ec-3）和 FLAC 音轨带宽更高，
    /// 但换个容器就播不了，也不好转成 m4a，所以先排掉。
    public static func audio(from play: PlayInfo) -> MediaStream? {
        guard !play.audios.isEmpty else { return nil }

        let aac = play.audios.filter { $0.codecs.hasPrefix("mp4a") }
        let pool = aac.isEmpty ? play.audios : aac

        return pool.max { $0.bandwidth < $1.bandwidth }
    }
}
