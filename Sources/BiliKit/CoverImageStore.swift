import Foundation
import CryptoKit

/// 封面图缓存。B 站的图床有防盗链，必须带 Referer，
/// 所以不能用 AsyncImage，得自己下。内存一份、磁盘一份。
@MainActor
public final class CoverImageStore: ObservableObject {

    public static let shared = CoverImageStore()

    /// 内存里的封面，含刚从磁盘读上来的。
    ///
    /// 故意**不是** @Published：`image(for:)` 是在视图 body 里调的，
    /// 而它可能顺手读一次磁盘，在 body 里改 @Published 就是
    /// 「view update 期间改状态」那个警告。
    /// 真要通知界面重画的只有一件事 —— 网上新下来一张 —— 交给 revision。
    private var images: [URL: PlatformImage] = [:]

    /// 问过磁盘、磁盘上没有的。
    /// 记下来，免得每帧重画都去 open 一次文件系统。
    private var diskMisses: Set<URL> = []

    private var loading: Set<URL> = []

    /// 新图落地时 +1，订阅这个 store 的视图靠它重画。
    @Published private var revision = 0

    /// 要不要**往网上要**封面。设置里那个「自动拉取封面」写的就是它。
    ///
    /// 关掉只是不发请求。本地缓存里已有的照常显示 ——
    /// 那份流量早就花掉了，没道理因为一个开关把它藏起来，
    /// 更没道理让人每次启动都对着占位图。
    @Published public var isFetchEnabled = true

    private let session: URLSession
    private let directory: URL

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 视图直接拿图用，同步返回。
    ///
    /// 内存里没有就问一次磁盘 —— 读一张小 jpg 很快，读过就留在内存里，
    /// 同一张不会再读第二次。这一下是「复用缓存」的关键：
    /// 光靠异步那一趟的话，每次启动的头一帧列表上全是占位图，
    /// 看着就像又在重新拉封面。
    public func image(for url: URL?) -> PlatformImage? {
        guard let url else { return nil }
        return readFromDisk(url)
    }

    /// 让这张封面就位。磁盘上有就到此为止，一个请求都不发 —— 这就是复用缓存；
    /// 磁盘上没有，才轮到网上（开关关着的话，也就到此为止了）。
    ///
    /// 不 await 那一趟下载：视图滚出屏幕会把 `.task` 取消掉，
    /// 挂在视图上的请求跟着就断了，那张图白下、也没落盘，
    /// 下次启动还得再下一遍 —— 正是「每次启动都重新拉」的来源。
    /// 反正 loading 挡着重复，让它自己在后台下完就行。
    public func load(_ url: URL?) {
        guard let url, !loading.contains(url) else { return }
        // 磁盘上已经有了：连内存都不用再动，readFromDisk 顺手就填好了
        if readFromDisk(url) != nil { return }
        guard isFetchEnabled else { return }

        loading.insert(url)
        Task { await self.fetch(url) }
    }

    /// 退出/清理时清一遍，别让缓存无限长大
    public func clearCache() {
        images.removeAll()
        diskMisses.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 内存清空了，得让界面重画回占位图
        revision += 1
    }

    /// 磁盘上缓存了多少字节
    public func diskUsage() -> Int64 {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return items.reduce(into: Int64(0)) { total, item in
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    // MARK: - 底下两层

    /// 先从磁盘捞。捞到就进内存，之后直接命中。
    private func readFromDisk(_ url: URL) -> PlatformImage? {
        if let image = images[url] { return image }
        guard !diskMisses.contains(url) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: url)),
              let image = PlatformImage(data: data) else {
            diskMisses.insert(url)
            return nil
        }
        images[url] = image
        return image
    }

    private func fetch(_ url: URL) async {
        defer { loading.remove(url) }

        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue(BiliClient.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = PlatformImage(data: data) else { return }

        images[url] = image
        try? data.write(to: fileURL(for: url))
        revision += 1
    }

    private func fileURL(for url: URL) -> URL {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest)
    }
}
