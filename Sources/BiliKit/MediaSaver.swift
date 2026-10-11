import Foundation
import BiliCore

// 相册是 iOS 才有的东西，macOS 那边整个文件都不参与编译 ——
// 那边的落盘走 OutputSink.swift 里的 FolderSink。
#if os(iOS)

import Photos

/// 落盘。只能二选一：相册或文件。
public enum MediaSaver {

    public enum SaveError: LocalizedError {
        case photosDenied
        case saveFailed(String)
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .photosDenied:
                return "没有相册权限，去「设置 › 隐私 › 照片」里打开"
            case .saveFailed(let reason):
                return "存相册失败：\(reason)"
            case .copyFailed(let reason):
                return "写入文件失败：\(reason)"
            }
        }
    }

    /// 视频都归到相册里这个文件夹下，跟用户自己拍的东西分开。
    private static let albumName = "BiliDown"

    /// 返回给用户看的结果描述
    @discardableResult
    public static func save(
        fileAt url: URL,
        fileName: String,
        kind: DownloadKind,
        to destination: SaveDestination
    ) async throws -> String {
        // 老版本的文件夹结构在这里顺手升级掉
        migrateLegacyFilesIfNeeded()

        switch destination {
        case .photos:
            let filed = try await saveToPhotos(url, kind: kind)
            return filed ? "已存入相册 › \(albumName)" : "已存入相册"
        case .files:
            let saved = try saveToFiles(url, fileName: fileName, kind: kind)
            return "已存入文件 › \(folderName(for: kind))/\(saved.lastPathComponent)"
        }
    }

    // MARK: - 相册

    private static func saveToPhotos(_ url: URL, kind: DownloadKind) async throws -> Bool {
        // 建相册得先能读相册，所以这里要的是完全访问
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SaveError.photosDenied
        }

        var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // 原件留在临时目录，等我们收尾时自己删
                options.shouldMoveFile = false
                request.addResource(with: kind == .cover ? .photo : .video, fileURL: url, options: options)
                placeholderID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw SaveError.saveFailed(error.localizedDescription)
        }

        // 只给了「仅添加」或只选了部分照片，建不了也用不着相册，留在「最近项目」就行。
        // 建相册失败也不能让整个下载算失败 —— 视频已经在相册里了。
        guard status == .authorized, let placeholderID else { return false }
        do {
            try await addToAlbum(localIdentifier: placeholderID)
            return true
        } catch {
            return false
        }
    }

    private static func addToAlbum(localIdentifier: String) async throws {
        let album = try await album(named: albumName)

        try await PHPhotoLibrary.shared().performChanges {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
                  let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets([asset] as NSArray)
        }
    }

    /// 找到同名相册，没有就现建一个。
    private static func album(named title: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if let found = existing.firstObject { return found }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }

        guard let identifier = placeholder?.localIdentifier,
              let created = PHAssetCollection
                  .fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
                  .firstObject else {
            throw SaveError.saveFailed("建不了「\(title)」相册")
        }
        return created
    }

    // MARK: - 文件

    /// Documents/Downloads/{Video,Audio}。
    /// 配合 Info.plist 里的 UIFileSharingEnabled，会直接出现在「文件」App 里。
    public static func directory(for kind: DownloadKind) -> URL {
        let directory = documentsDirectory()
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(folderName(for: kind), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 音视频和纯视频都算视频；音频进 Audio，封面图进 Image。
    private static func folderName(for kind: DownloadKind) -> String {
        switch kind {
        case .audioOnly: return "Audio"
        case .cover: return "Image"
        case .audiovisual, .videoOnly: return "Video"
        }
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func saveToFiles(_ url: URL, fileName: String, kind: DownloadKind) throws -> URL {
        var target = directory(for: kind).appendingPathComponent(Self.safeName(fileName))
        if target.pathExtension.isEmpty { target.appendPathExtension("mp4") }
        target = uniqueURL(for: target)

        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw SaveError.copyFailed(error.localizedDescription)
        }
        return target
    }

    // 洗文件名和去重这两件事 macOS 那边也要用，已经挪到 FileNaming 里共用
    private static func safeName(_ name: String) -> String { FileNaming.safeName(name) }

    private static func uniqueURL(for url: URL) -> URL { FileNaming.uniqueURL(for: url) }

    // MARK: - 老目录升级

    /// 早先版本把文件直接堆在 Documents/BiliDown 下，
    /// 在「文件」App 里看起来是 BiliDown/BiliDown，重复了一层。
    /// 这里按扩展名分拣到 Downloads/Video 和 Downloads/Audio，然后把旧目录删掉。
    private static func migrateLegacyFilesIfNeeded() {
        let manager = FileManager.default
        let legacy = documentsDirectory().appendingPathComponent("BiliDown", isDirectory: true)

        guard let entries = try? manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil),
              !entries.isEmpty else {
            try? manager.removeItem(at: legacy)
            return
        }

        for entry in entries {
            let isAudio = ["m4a", "mp3", "wav"].contains(entry.pathExtension.lowercased())
            let target = directory(for: isAudio ? .audioOnly : .videoOnly)
            let destination = uniqueURL(for: target.appendingPathComponent(entry.lastPathComponent))
            try? manager.moveItem(at: entry, to: destination)
        }

        try? manager.removeItem(at: legacy)
    }
}

#endif
