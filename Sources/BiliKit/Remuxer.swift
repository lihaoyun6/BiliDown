import Foundation
import AVFoundation
import BiliCore

/// .m4s 就是分片 MP4，改名后让 AVMutableComposition 直接导出即可，
/// 视频轨零重编码，音频轨零重编码。
public enum Remuxer {

    public enum RemuxError: LocalizedError {
        case noVideoTrack
        case exportFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "视频流里没有画面轨"
            case .exportFailed(let reason): return "合并失败：\(reason)"
            case .cancelled: return "合并被取消"
            }
        }
    }

    public static func merge(video: URL, audio: URL?, output: URL, codec: VideoCodec) async throws {
        try? FileManager.default.removeItem(at: output)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)

        guard let sourceVideo = try await tracks(.video, of: videoAsset, label: video.lastPathComponent).first else {
            throw RemuxError.noVideoTrack
        }

        let videoDuration = try await videoAsset.load(.duration)
        let videoRange = CMTimeRange(start: .zero, duration: videoDuration)

        let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        try compositionVideo?.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        compositionVideo?.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if let audio {
            let audioAsset = AVURLAsset(url: audio)
            if let sourceAudio = try await tracks(.audio, of: audioAsset, label: audio.lastPathComponent).first {
                let audioDuration = try await audioAsset.load(.duration)
                let compositionAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try compositionAudio?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: audioDuration),
                    of: sourceAudio,
                    at: .zero
                )
            }
        }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw RemuxError.exportFailed("无法创建导出会话")
        }

        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        try await run(export)

        if codec == .h265 {
            try patchHEVCSampleEntry(at: output)
        }
    }

    /// AVFoundation 读不开文件时只会甩一句 "cannot open"，
    /// 这里补上到底是哪个文件、哪个错误域，下次出事好定位。
    private static func tracks(
        _ mediaType: AVMediaType,
        of asset: AVURLAsset,
        label: String
    ) async throws -> [AVAssetTrack] {
        do {
            return try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            let nsError = error as NSError
            throw RemuxError.exportFailed(
                "读不了 \(label)（\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)）"
            )
        }
    }

    private static func run(_ export: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: RemuxError.cancelled)
                default:
                    let reason = export.error?.localizedDescription ?? "未知错误"
                    continuation.resume(throwing: RemuxError.exportFailed(reason))
                }
            }
        }
    }

    // MARK: - H.265 的坑

    /// B 站的 HEVC 轨用的是 `hev1` 采样描述，相册只认 `hvc1`，
    /// tag 不改的话导出成功但存不进相册。
    /// 只动 moov 里 stsd 那一小段，不整个文件读进内存。
    static func patchHEVCSampleEntry(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        let hev1 = Data("hev1".utf8)
        let stsd = Data("stsd".utf8)

        guard let stsdOffset = try find(stsd, in: handle) else { return }
        // stsd 后面紧跟采样描述，4 KB 足够覆盖
        guard let hev1Offset = try find(hev1, in: handle, from: stsdOffset, limit: stsdOffset + 4096) else { return }

        try handle.seek(toOffset: hev1Offset)
        try handle.write(contentsOf: Data("hvc1".utf8))
    }

    /// 分块扫描，返回第一个匹配的偏移。只在文件里找一次，不常驻内存。
    private static func find(
        _ needle: Data,
        in handle: FileHandle,
        from start: UInt64 = 0,
        limit: UInt64? = nil
    ) throws -> UInt64? {
        let chunkSize: UInt64 = 1 << 20
        let overlap = UInt64(needle.count - 1)
        let fileSize = try handle.seekToEnd()

        var offset = start
        var carry = Data()

        while offset < fileSize {
            let upper = limit.map { min($0, fileSize) } ?? fileSize
            guard offset < upper else { return nil }

            try handle.seek(toOffset: offset)
            let readSize = Int(min(chunkSize, upper - offset))
            guard readSize > 0, let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else { return nil }

            var buffer = carry
            buffer.append(chunk)

            if let range = buffer.range(of: needle) {
                return offset - UInt64(carry.count) + UInt64(range.lowerBound)
            }

            carry = buffer.suffix(Int(overlap))
            offset += UInt64(chunk.count)
        }
        return nil
    }
}
