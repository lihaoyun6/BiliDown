import Foundation
import AVFoundation
import BiliCore
import SwiftLAME

/// 把下载下来的音轨换成用户挑的格式。
public enum AudioExporter {

    public enum ExportError: LocalizedError {
        case noAudioTrack
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "这个流里没有音轨"
            case .failed(let reason): return "音频转换失败：\(reason)"
            }
        }
    }

    public static func convert(source: URL, output: URL, format: AudioFormat) async throws {
        try? FileManager.default.removeItem(at: output)

        switch format {
        case .m4a:
            try await passthroughM4A(source: source, output: output)
        case .wav:
            try await writeWAV(source: source, output: output)
        case .mp3:
            // 解码 + 编码是纯 CPU 活，扔到后台线程，别卡住界面
            try await Task.detached(priority: .utility) {
                try await writeMP3(source: source, output: output)
            }.value
        }
    }

    // MARK: - M4A

    /// AAC 轨道直接换个容器，不重新编码，音质一点不损失。
    private static func passthroughM4A(source: URL, output: URL) async throws {
        let asset = AVURLAsset(url: source)

        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ExportError.noAudioTrack
        }

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ExportError.failed("无法创建导出会话")
        }

        export.outputURL = output
        export.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                if export.status == .completed {
                    continuation.resume()
                } else {
                    let reason = export.error?.localizedDescription ?? "未知错误"
                    continuation.resume(throwing: ExportError.failed(reason))
                }
            }
        }
    }

    // MARK: - WAV

    /// PCM 没法从 AAC 直接搬，只能解出来重写成线性 PCM。
    private static func writeWAV(source: URL, output: URL) async throws {
        let asset = AVURLAsset(url: source)
        let track = try await audioTrack(of: asset)
        let parameters = try await audioParameters(of: track)

        let pcmSettings = parameters.pcmSettings

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "读写器启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        try await pump(reader: reader, readerOutput: readerOutput, writer: writer, writerInput: writerInput)
    }

    // MARK: - MP3（LAME）

    /// 解码和逐帧编码都在 SwiftLAME 的 `SwiftLameEncoder` 里，那圈
    /// reader/encoder 循环不用我们自己写了。
    ///
    /// 但它读源走的是 `AVAudioFile`，而 B 站下下来的是 DASH 的 fMP4 分片
    /// （init 段 + moof/mdat，moov 里的 sample table 是空的）—— 那种文件只有
    /// AVFoundation 那套（AVURLAsset / AVAssetReader）认，`AVAudioFile` 底下是
    /// AudioFile/ExtAudioFile，读的是经典 MP4 那张表，对着空表只会报错。
    /// 所以先把源 passthrough 导成一份**标准 m4a** 当中间文件 —— 只搬容器、
    /// 不重编码（跟上面 `.m4a` 那条路是同一段代码），再把这份交给它。
    /// 中间文件落在任务的临时目录里，跟 output 同一个地方，任务清掉时一起走。
    private static func writeMP3(source: URL, output: URL) async throws {
        let intermediate = source.deletingLastPathComponent()
            .appendingPathComponent("audio.m4a")
        defer { try? FileManager.default.removeItem(at: intermediate) }

        try await passthroughM4A(source: source, output: intermediate)

        do {
            try await SwiftLameEncoder(
                sourceUrl: intermediate,
                configuration: LameConfiguration(
                    // 320 CBR —— 反正源就是 AAC 有损的，再省码率只会更糊。
                    // quality 取 2：这套档位里 `.nearBest` 就是 2，
                    // 跟以前直接调 `lame_set_quality(lame, 2)` 给的是同一个数。
                    bitrateMode: .constant(320),
                    quality: .nearBest
                ),
                destinationUrl: output
            ).encode(priority: .utility)
        } catch {
            // SwiftLameError 没实现 LocalizedError，原样抛出去界面上只有一句
            // 「操作无法完成」；换成自己这句，至少看得出是卡在编码这一步。
            throw ExportError.failed(error.localizedDescription)
        }
    }

    // MARK: - 共用

    private struct AudioParameters {
        let sampleRate: Double
        let channels: UInt32

        var pcmSettings: [String: Any] {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    private static func audioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudioTrack
        }
        return track
    }

    private static func audioParameters(of track: AVAssetTrack) async throws -> AudioParameters {
        guard let formatDescription = try await track.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            throw ExportError.failed("读不到音轨参数")
        }
        return AudioParameters(
            sampleRate: description.mSampleRate > 0 ? description.mSampleRate : 44100,
            channels: description.mChannelsPerFrame > 0 ? description.mChannelsPerFrame : 2
        )
    }

    /// AVAssetReader 只能拉，AVAssetWriter 只能推，中间靠这个循环对接。
    private static func pump(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        let state = PumpState()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.lihaoyun6.BiliDown.audio-export")

            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !state.isFinished else { return }

                while writerInput.isReadyForMoreMediaData {
                    guard let buffer = readerOutput.copyNextSampleBuffer() else {
                        state.isFinished = true
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                let reason = writer.error?.localizedDescription ?? "写入失败"
                                continuation.resume(throwing: ExportError.failed(reason))
                            }
                        }
                        return
                    }

                    if !writerInput.append(buffer) {
                        state.isFinished = true
                        reader.cancelReading()
                        writer.cancelWriting()
                        let reason = writer.error?.localizedDescription
                            ?? reader.error?.localizedDescription
                            ?? "写入样本失败"
                        continuation.resume(throwing: ExportError.failed(reason))
                        return
                    }
                }
            }
        }
    }

    /// 回调可能在串行队列上重入，用它保证 continuation 只 resume 一次。
    private final class PumpState: @unchecked Sendable {
        var isFinished = false
    }
}

