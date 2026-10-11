import Foundation

/// 保存目的地只能二选一：相册或文件，不做同时保存。
public enum SaveDestination: String, CaseIterable, Sendable, Identifiable {
    case photos
    case files

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .photos: return "相册"
        case .files: return "文件"
        }
    }

    public var systemImage: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        }
    }
}

public enum VideoCodec: String, CaseIterable, Sendable, Identifiable {
    case h264
    case h265

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        }
    }
}

/// 这一批任务要下什么。
public enum DownloadKind: String, CaseIterable, Sendable, Identifiable, Codable {
    case audiovisual
    case videoOnly
    case audioOnly
    case cover

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .audiovisual: return "音视频"
        case .videoOnly: return "仅视频"
        case .audioOnly: return "仅音频"
        case .cover: return "封面图"
        }
    }

    public var hasVideo: Bool { self == .audiovisual || self == .videoOnly }
    public var hasAudio: Bool { self == .audiovisual || self == .audioOnly }
}

/// 音频导出格式。
public enum AudioFormat: String, CaseIterable, Sendable, Identifiable {
    case m4a
    case mp3
    case wav

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        }
    }
}
