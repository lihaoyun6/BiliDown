import Foundation
import BiliCore

/// 用户设置。存 UserDefaults，改动立刻落盘。
@MainActor
public final class AppSettings: ObservableObject {

    private enum Key {
        static let saveDestination = "saveDestination"
        static let downloadDirectory = "downloadDirectory"
        static let videoCodec = "videoCodec"
        static let audioFormat = "audioFormat"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let autoDetectClipboard = "autoDetectClipboard"
        static let autoFetchCovers = "autoFetchCovers"
        static let filterInvalidContent = "filterInvalidContent"
    }

    private let defaults: UserDefaults

    #if os(iOS)

    @Published public var saveDestination: SaveDestination {
        didSet { defaults.set(saveDestination.rawValue, forKey: Key.saveDestination) }
    }

    #else

    /// macOS 没有「相册」这回事，保存位置就是「哪个文件夹」。
    /// 默认落在 `~/Downloads/BiliDown` —— 单独开一层，不跟用户自己的下载混在一起：
    /// `BV号_视频标题_P1.mp4` 这种名字一次能刷十几个进去，散在下载目录里很难收拾。
    @Published public var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path, forKey: Key.downloadDirectory) }
    }

    /// 界面上「恢复默认」那个按钮要用它，所以是 public 的。
    public static var defaultDownloadDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("BiliDown", isDirectory: true)
    }

    #endif

    /// 成品落到哪儿。整个下载流程里唯一一处平台相关的决定，收敛在这一个属性上；
    /// DownloadQueue 只认 OutputSink 这个协议，不认识平台。
    public var outputSink: OutputSink {
        #if os(iOS)
        MediaSaverSink(destination: saveDestination)
        #else
        FolderSink(root: downloadDirectory)
        #endif
    }

    @Published public var videoCodec: VideoCodec {
        didSet { defaults.set(videoCodec.rawValue, forKey: Key.videoCodec) }
    }

    @Published public var audioFormat: AudioFormat {
        didSet { defaults.set(audioFormat.rawValue, forKey: Key.audioFormat) }
    }

    /// 同时下几个任务。
    ///
    /// **默认 1，一个一个来。** 并行下载会把请求在时间上叠起来，
    /// 那是风控最容易注意到的一种行为 —— 得用户自己去设置里点头才开，
    /// 所以界面上从 1 往上调的时候会先提醒一句。
    ///
    /// 上限定在 10：再多也不是下得更快，是把自己往风控脸上怼。
    @Published public var maxConcurrentDownloads: Int {
        didSet {
            // 收进范围里。多半是存档被人手改坏了（比如塞了个 0 或 99）——
            // 真到那一步，第一次进来会有一次自赋值，第二次才落盘。
            let clamped = Self.clampConcurrent(maxConcurrentDownloads)
            guard clamped == maxConcurrentDownloads else {
                maxConcurrentDownloads = clamped
                return
            }
            defaults.set(clamped, forKey: Key.maxConcurrentDownloads)
        }
    }

    public static let concurrentRange = 1...10

    /// 存档里的数收进 `concurrentRange`。界面上的步进器本来就跳不出去，
    /// 这一步是防存档被改坏 —— 那些数会直接进 `DownloadQueue` 当并行度用。
    static func clampConcurrent(_ value: Int) -> Int {
        min(max(value, concurrentRange.lowerBound), concurrentRange.upperBound)
    }

    /// 打开 App 时看一眼剪贴板里有没有能下的东西，有就直接进添加任务。
    /// **默认关**：读剪贴板会弹系统的「允许粘贴」，没经用户点头不该弹那一下。
    @Published public var autoDetectClipboard: Bool {
        didSet { defaults.set(autoDetectClipboard, forKey: Key.autoDetectClipboard) }
    }

    /// 拉不拉封面图。默认拉。
    /// 关掉之后**一个封面请求都不发**，不是拿回来不显示 ——
    /// 目的就是少一串图片请求，少一份被风控盯上的由头。
    /// 但本地缓存里已有的照常显示：那份流量早花过了，
    /// 藏起来只会让人对着占位图犯嘀咕。
    @Published public var autoFetchCovers: Bool {
        didSet {
            defaults.set(autoFetchCovers, forKey: Key.autoFetchCovers)
            CoverImageStore.shared.isFetchEnabled = autoFetchCovers
        }
    }

    /// 收藏夹和合集的列表里，把失效的那些（「已失效视频」「该合集已失效」）藏掉。
    /// 默认**关**：失效也是一种信息 —— 有人就是要翻翻自己收藏的哪几个没了，
    /// 而且这些占位条目本身也不占多少地方。
    @Published public var filterInvalidContent: Bool {
        didSet { defaults.set(filterInvalidContent, forKey: Key.filterInvalidContent) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        #if os(iOS)
        self.saveDestination = SaveDestination(rawValue: defaults.string(forKey: Key.saveDestination) ?? "") ?? .photos
        #else
        self.downloadDirectory = defaults.string(forKey: Key.downloadDirectory)
            .map { URL(fileURLWithPath: $0) } ?? Self.defaultDownloadDirectory
        #endif

        self.videoCodec = VideoCodec(rawValue: defaults.string(forKey: Key.videoCodec) ?? "") ?? .h264

        // 没存过就 MP3。存档只在 rawValue 认不出来时才不认（比如是哪天删掉的旧档），
        // 到那一步也退回 MP3。
        self.audioFormat = AudioFormat(rawValue: defaults.string(forKey: Key.audioFormat) ?? "") ?? .mp3

        // 没存过就是 1：默认串行。
        self.maxConcurrentDownloads = Self.clampConcurrent(
            defaults.object(forKey: Key.maxConcurrentDownloads) as? Int ?? 1
        )
        // 开关类的默认值不能用 string(forKey:) 那套（没存过时要区分「没设过」和「设成 false」）
        self.autoDetectClipboard = defaults.object(forKey: Key.autoDetectClipboard) as? Bool ?? false
        self.autoFetchCovers = defaults.object(forKey: Key.autoFetchCovers) as? Bool ?? true
        self.filterInvalidContent = defaults.object(forKey: Key.filterInvalidContent) as? Bool ?? false

        // didSet 在 init 里不触发，得自己把状态同步给图片仓库
        CoverImageStore.shared.isFetchEnabled = self.autoFetchCovers
    }
}
