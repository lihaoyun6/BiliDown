import Foundation
import BiliCore

/// 成品从临时目录搬到「最终位置」这一步。
///
/// 整个下载流程里**只有这一步**是平台相关的：iOS 是相册 / 「文件」App，
/// macOS 是一个文件夹。收成一个协议之后，DownloadQueue 就彻底不认识平台了 ——
/// 它只管把做好的文件交给 sink，至于落到哪儿、走不走相册，由 sink 自己决定。
public protocol OutputSink: Sendable {
    /// 把 source 搬到最终位置，返回一句给用户看的结果描述。
    @discardableResult
    func deliver(fileAt source: URL, fileName: String, kind: DownloadKind) async throws -> String
}

// MARK: - macOS：一个文件夹

/// 存进某个目录。macOS 那边用；iOS 的「文件」走 MediaSaver 里那条老路。
public struct FolderSink: OutputSink {

    public enum FolderError: LocalizedError {
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let reason): return "写入文件失败：\(reason)"
            }
        }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    @discardableResult
    public func deliver(fileAt source: URL, fileName: String, kind: DownloadKind) async throws -> String {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        var target = root.appendingPathComponent(FileNaming.safeName(fileName))
        if target.pathExtension.isEmpty { target.appendPathExtension("mp4") }
        target = FileNaming.uniqueURL(for: target)

        do {
            // 下载的中转目录在 App 自己的容器里，跟用户挑的目录多半不同卷，
            // 所以这一步跨卷是很正常的事，交给 FileManager 自己处理。
            try manager.moveItem(at: source, to: target)
        } catch {
            throw FolderError.writeFailed(error.localizedDescription)
        }
        return "已存入 \(target.path)"
    }
}

// MARK: - iOS：相册 / 文件二选一

#if os(iOS)

/// 把既有的 MediaSaver 包成 sink。相册 / 「文件」那套逻辑原样不动，
/// 包括「纯音频一律进文件」这条规矩 —— 它本来就该属于 sink，
/// 而不是让队列去记「音频要走哪个目的地」。
struct MediaSaverSink: OutputSink {
    let destination: SaveDestination

    @discardableResult
    func deliver(fileAt source: URL, fileName: String, kind: DownloadKind) async throws -> String {
        // 相册不收纯音频
        let target: SaveDestination = kind == .audioOnly ? .files : destination
        return try await MediaSaver.save(fileAt: source, fileName: fileName, kind: kind, to: target)
    }
}

#endif
