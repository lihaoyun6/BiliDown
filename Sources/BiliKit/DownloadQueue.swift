import Foundation
import BiliCore

/// 下载队列 + 执行引擎。
/// 入队后先跑一轮元信息预取（标题、封面），再一个接一个下载。
@MainActor
public final class DownloadQueue: ObservableObject {

    @Published public private(set) var jobs: [DownloadJob] = []

    private let settings: AppSettings
    private let client = BiliClient()
    private let storeURL: URL?
    private var isRunning = false
    private var isPrefetching = false
    private var persistTask: Task<Void, Never>?

    /// 正在跑的任务，点停止时靠它把底层 URLSession 掐掉
    private var running: [UUID: Task<Void, Never>] = [:]
    /// 这次中断是用户按的停止，不是出错
    private var stopRequested: Set<UUID> = []

    public init(settings: AppSettings, jobs: [DownloadJob] = []) {
        self.settings = settings
        self.storeURL = Self.storeURL()

        if !jobs.isEmpty {
            self.jobs = jobs
        } else if let storeURL,
                  let data = try? Data(contentsOf: storeURL),
                  let restored = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            self.jobs = restored.map(Self.resumable)
        } else {
            self.jobs = []
        }
    }

    // MARK: - 登录态

    /// 队列的 client 拿到凭证了没。
    ///
    /// 给界面一个「再等一下」的依据：冷启动时侧边栏那条「收藏」在登录态
    /// 一恢复就出现了，而凭证是同一段任务里**后面**一行才喂进 client 的 ——
    /// 中间那一瞬间发出去的请求一律被当成未登录打回来（`notLoggedIn`），
    /// 收藏页就会先闪一下「读不到收藏夹」再自己好。
    /// 判断凭证到没到，不看「用户登没登录」，只看 client 手上有没有。
    @Published public private(set) var hasCredential = false

    /// 队列真正开跑放在这里：冷启动时凭证要等到这一步才装上，
    /// 早跑一步就会按未登录的画质去取流。
    public func setCredential(_ credential: BiliCredential?) async {
        await client.setCredential(credential)
        hasCredential = credential != nil
        startPrefetchIfNeeded()
        startIfNeeded()
    }

    /// 给「选择分 P」界面用：挑 P 之前得先知道这视频有几 P。
    public func videoInfo(for ref: VideoRef) async throws -> VideoInfo {
        try await client.videoInfo(ref: ref)
    }

    // MARK: - 收藏夹

    /// 收藏夹走队列自己的 client，这样 Cookie 一定是登录时存下的那份。
    public func favoriteFolders() async throws -> [FavFolder] {
        try await client.favoriteFolders()
    }

    public func favoriteItems(folderID: Int, page: Int) async throws -> (items: [FavItem], hasMore: Bool) {
        try await client.favoriteItems(folderID: folderID, page: page)
    }

    // MARK: - 主页 / 合集

    /// 展开 UP 主投稿或合集的一页。
    public func bulkPage(_ source: BulkSource, page: Int) async throws -> BulkResult {
        try await client.bulkPage(source, page: page)
    }

    /// 收藏页「合集」那一栏。
    public func subscribedCollections(page: Int = 1) async throws -> (items: [SubscribedCollection], hasMore: Bool) {
        try await client.subscribedCollections(page: page)
    }

    public func collectedItems(_ entry: SubscribedCollection, page: Int) async throws -> BulkResult {
        try await client.collectedItems(entry, page: page)
    }

    // MARK: - 追番 / 追剧 / 稍后再看 / 历史记录

    public func followedSeasons(type: Int, page: Int = 1) async throws -> (items: [FollowedSeason], hasMore: Bool) {
        try await client.followedSeasons(type: type, page: page)
    }

    public func seasonEpisodes(seasonID: Int) async throws -> [FavItem] {
        try await client.seasonEpisodes(seasonID: seasonID)
    }

    public func watchLater() async throws -> (items: [FavItem], total: Int) {
        try await client.watchLater()
    }

    public func history(cursor: HistoryCursor?) async throws -> (items: [FavItem], hasMore: Bool, cursor: HistoryCursor) {
        try await client.history(cursor: cursor)
    }

    // MARK: - 队列操作

    @discardableResult
    public func add(_ targets: [ParsedTarget], kind: DownloadKind = .audiovisual) -> Int {
        var added = 0
        for target in targets {
            guard !contains(ref: target.ref, page: target.page ?? 1) else { continue }
            // 新任务插在最前面，老任务往下沉。
            // 插在 added 这个位置（而不是 0）：一整批新的全压在最上面，
            // 批内还保持粘贴的先后顺序 —— 一批 20 条倒着排才奇怪。
            // 顺带一提，jobs 这个数组的顺序既是列表的顺序，也是下载顺序
            // （runLoop 取第一个 queued），所以新加的会是下一个下的。
            jobs.insert(DownloadJob(ref: target.ref, kind: kind, pageNumber: target.page), at: added)
            added += 1
        }
        schedulePersist()
        startPrefetchIfNeeded()
        startIfNeeded()
        return added
    }

    @discardableResult
    public func add(ref: VideoRef, page: Int?, kind: DownloadKind = .audiovisual) -> Int {
        add([ParsedTarget(ref: ref, page: page)], kind: kind)
    }

    public func contains(ref: VideoRef, page: Int) -> Bool {
        jobs.contains { $0.ref == ref && ($0.pageNumber ?? 1) == page }
    }

    public func remove(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
        schedulePersist()
    }

    public func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where jobs.indices.contains(index) {
            jobs.remove(at: index)
        }
        schedulePersist()
    }

    /// 只清已经下完的。
    /// 排队中、下载中、暂停的都留着 —— 尤其暂停的，那是用户特意留下的。
    /// 失败的也留着：失败还等着人处理（看报告、重试），顺手清掉等于把线索丢了。
    public func removeFinished() {
        jobs.removeAll { $0.state == .finished }
        schedulePersist()
    }

    /// 清空列队：不管什么状态，一条不留。正在下的先掐掉再移除，
    /// 不然那几条任务还在后台跑，进度回调会往一个已经不在的 job 上写。
    public func removeAll() {
        for job in jobs {
            stop(job)
        }
        jobs.removeAll()
        schedulePersist()
    }

    // MARK: - 暂停 / 继续

    /// 停止：掐掉底层传输，进度丢掉，状态落成「已停止」。
    /// 想做断点续传但 B 站那边续不上，索性当停止用。
    public func stop(_ job: DownloadJob) {
        guard !job.state.isSettled, job.state != .stopped else { return }
        stopRequested.insert(job.id)

        if let task = running[job.id] {
            // 跑着的：掐掉，process 里会接住并把状态落成 stopped
            task.cancel()
        } else {
            // 还在排队的：没什么可掐的，直接标记
            update(job.id) {
                $0.state = .stopped
                $0.progress = 0
            }
        }
    }

    /// 一次停掉所有还在等和正在跑的。已经停下的不重复处理，
    /// 更不去碰已完成/失败的 —— 那些不属于「停止」的范围。
    @discardableResult
    public func stopAll() -> Int {
        let targets = jobs.filter { $0.state == .queued || $0.state.isActive }
        for job in targets {
            stop(job)
        }
        return targets.count
    }

    // MARK: - 按钮的可用性

    // 这几个判断放在队列里而不是界面上现算：什么状态算什么，是队列自己的知识，
    // 界面只管拿结果去灰按钮，省得两边各写一份 switch，改状态时漏掉一处。

    /// 有排队中或正在跑的，才轮得到「全部停止」
    public var hasStoppable: Bool {
        jobs.contains { $0.state == .queued || $0.state.isActive }
    }

    /// 有停下或失败的，才轮得到「全部开始」
    public var hasResumable: Bool {
        jobs.contains { $0.state == .stopped || $0.state.isFailed }
    }

    /// 有下完的，才轮得到「清理列队」
    public var hasFinished: Bool {
        jobs.contains { $0.state == .finished }
    }

    /// 全部开始：把停下的和失败的重新排上。
    /// 已完成的不动 —— 下过的东西不再下一遍。
    @discardableResult
    public func startAll() -> Int {
        let targets = jobs.filter { $0.state == .stopped || $0.state.isFailed }
        for job in targets {
            retry(job)
        }
        return targets.count
    }

    /// 失败重试和停止后重下都走这里，一律从零开始。
    public func retry(_ job: DownloadJob) {
        update(job.id) {
            $0.state = .queued
            $0.progress = 0
        }
        startIfNeeded()
    }

    public var activeCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    public var queuedCount: Int {
        jobs.filter { $0.state == .queued }.count
    }

    // MARK: - 元信息预取

    /// 排队的任务也得有标题和封面可看，所以入队就先拉一遍。
    private func startPrefetchIfNeeded() {
        guard !isPrefetching else { return }
        isPrefetching = true
        Task { await prefetchLoop() }
    }

    private func prefetchLoop() async {
        defer { isPrefetching = false }

        while let next = jobs.first(where: { !$0.metadataPrefetched && $0.state == .queued }) {
            do {
                let info = try await client.videoInfo(ref: next.ref)

                // 多 P 视频又没点名要哪一 P —— 那就是整季都要，拆开
                if info.isMultiPage, next.pageNumber == nil {
                    expandAllPages(next.id, info: info)
                    continue
                }

                update(next.id) { job in
                    job.title = info.title
                    job.coverURL = info.coverURL
                    job.pageCount = info.pages.count
                    job.resolvedBVID = info.bvid

                    let wanted = job.pageNumber ?? 1
                    if let page = info.pages.first(where: { $0.page == wanted }) ?? info.pages.first {
                        job.cid = page.cid
                        // 单 P 视频不往文件名里塞 P 编号
                        job.pageNumber = info.isMultiPage ? page.page : nil
                        job.pageTitle = info.isMultiPage ? page.title : nil
                    }
                    job.metadataPrefetched = true
                }
            } catch {
                // 拉不到就拉倒，标记一下免得卡在这儿，下载时再报真正的错
                update(next.id) { $0.metadataPrefetched = true }
            }
        }
    }

    /// 多 P 视频用户没点名要哪一 P，就是整季都要：原地拆成每 P 一个任务。
    /// 拆完就全是普通任务了，进度、命名、停止都不用为「一单多 P」特事特办。
    private func expandAllPages(_ id: UUID, info: VideoInfo) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let first = info.pages.first(where: { $0.page == 1 }) ?? info.pages.first else { return }

        let template = jobs[index]

        func fill(_ job: inout DownloadJob, page: VideoPage) {
            job.title = info.title
            job.coverURL = info.coverURL
            job.pageCount = info.pages.count
            job.resolvedBVID = info.bvid
            job.pageNumber = page.page
            job.pageTitle = page.title
            job.cid = page.cid
            job.metadataPrefetched = true
        }

        // 原来那条就地变成 P1，剩下的插在它后面
        fill(&jobs[index], page: first)

        let extras = info.pages
            .filter { $0.page != first.page }
            .map { page -> DownloadJob in
                var job = DownloadJob(ref: template.ref, kind: template.kind, pageNumber: page.page)
                fill(&job, page: page)
                return job
            }

        jobs.insert(contentsOf: extras, at: index + 1)
        schedulePersist()
    }

    // MARK: - 下载

    private func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        defer { isRunning = false }

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            while true {
                let limit = max(1, settings.maxConcurrentDownloads)

                // 满了就先等一个跑完。等的时候别人还在下面跑着，
                // 空出来的位子马上被下一条补上，不会串成一批一批的。
                if inFlight >= limit {
                    await group.next()
                    inFlight -= 1
                    continue
                }

                guard let id = claimQueued() else {
                    // 队列空**且**一条都没在跑，才算真收工。只看队列空不行：
                    // 多 P 视频是在 `process` 里才拆成一条条的，拆出来的那些
                    // 正是「手上这批跑着、队列暂时空着」的时候冒出来的。
                    guard inFlight > 0 else { break }
                    await group.next()
                    inFlight -= 1
                    continue
                }

                inFlight += 1
                group.addTask { @MainActor in await self.run(id) }
            }

            await group.waitForAll()
        }
    }

    /// 包一层是为了拿到一个**能单独掐掉**的句柄：`group.addTask` 出来的子任务
    /// 取消不了某一个，而「停止」要的正是掐掉某一条的底层传输。
    private func run(_ id: UUID) async {
        let task = Task { await process(id) }
        running[id] = task
        await task.value
        running[id] = nil
    }

    /// 认领下一条排队的：**当场**把状态推成 resolving。
    /// 不当场推的话，并行的时候 while 转第二圈会挑到同一条 ——
    /// `Task {}` 建出来不会立刻跑，`process` 开头那句改状态赶不上。
    @discardableResult
    private func claimQueued() -> UUID? {
        guard let job = jobs.first(where: { $0.state == .queued }) else { return nil }
        update(job.id) { $0.state = .resolving }
        return job.id
    }

    private func process(_ id: UUID) async {
        // 认领（claimQueued）和这个任务真正开跑之间隔着一次让出，用户可能正好
        // 在这中间按了停止 —— 那一刻 `running` 里还没有这一条，stop() 走的是
        // 「还在排队的」那条路，只把状态标成了 stopped。所以进来先对一眼：
        // 不是 resolving 就别往下跑了，不然会绕过用户刚按下的停止把它下完。
        guard let snapshot = jobs.first(where: { $0.id == id }), snapshot.state == .resolving else { return }
        var workDirectory: URL?

        do {
            update(id) { $0.state = .resolving }

            var coverURL = snapshot.coverURL
            let bvid: String
            let cid: Int

            if let cachedBVID = snapshot.resolvedBVID, let cachedCID = snapshot.cid {
                bvid = cachedBVID
                cid = cachedCID
            } else {
                let info = try await client.videoInfo(ref: snapshot.ref)
                let wantedPage = snapshot.pageNumber ?? 1
                guard let page = info.pages.first(where: { $0.page == wantedPage }) ?? info.pages.first else {
                    throw BiliError.noStream
                }
                bvid = info.bvid
                cid = page.cid
                coverURL = info.coverURL

                // 预取没拉到时走的这条路，同样得多 P 展开一次
                if info.isMultiPage, snapshot.pageNumber == nil {
                    expandAllPages(id, info: info)
                } else {
                    update(id) {
                        $0.title = info.title
                        $0.coverURL = info.coverURL
                        $0.pageCount = info.pages.count
                        $0.resolvedBVID = info.bvid
                        $0.cid = page.cid
                        $0.metadataPrefetched = true
                        $0.pageNumber = info.isMultiPage ? page.page : nil
                        $0.pageTitle = info.isMultiPage ? page.title : nil
                    }
                }
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            workDirectory = directory

            if snapshot.kind == .cover {
                // 封面图不用取流，pic 那个地址就够了
                guard let coverURL else { throw BiliError.noStream }
                try await runCover(id: id, coverURL: coverURL, directory: directory)
            } else {
                let play = try await client.playInfo(bvid: bvid, cid: cid)
                let headers = client.mediaHeaders()

                if snapshot.kind == .audioOnly {
                    try await runAudioOnly(id: id, play: play, headers: headers, directory: directory)
                } else {
                    try await runVideo(
                        id: id,
                        play: play,
                        headers: headers,
                        directory: directory,
                        includeAudio: snapshot.kind == .audiovisual
                    )
                }
            }

            try Task.checkCancellation()
            update(id) {
                $0.state = .finished
                $0.progress = 1
            }

        } catch {
            if stopRequested.contains(id) || Task.isCancelled {
                // 停止不是失败：进度丢掉，重下的时候从零来
                update(id) {
                    $0.state = .stopped
                    $0.progress = 0
                }
            } else {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                update(id) { $0.state = .failed(reason) }
            }
        }

        stopRequested.remove(id)

        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    // MARK: - 视频

    private func runVideo(
        id: UUID,
        play: PlayInfo,
        headers: [String: String],
        directory: URL,
        includeAudio: Bool
    ) async throws {
        guard let videoStream = StreamSelector.video(from: play, codec: settings.videoCodec) else {
            throw BiliError.noStream
        }
        let audioStream = includeAudio ? StreamSelector.audio(from: play) : nil

        let videoWeight = audioStream == nil ? 0.9 : 0.6
        let audioWeight = 0.9 - videoWeight

        update(id) {
            // 挑中的画质记一笔：封面角标（那个「480P」）就是从这儿来的
            $0.qualityID = videoStream.qualityID
            $0.state = .downloading
            $0.progress = 0
        }

        // 落成 .mp4：AVFoundation 按扩展名认容器，.m4s 会直接报 cannot open
        let videoFile = directory.appendingPathComponent("video.mp4")
        try await fetch(videoStream, headers: headers, to: videoFile) { [weak self] value in
            self?.update(id) { $0.progress = value * videoWeight }
        }

        var audioFile: URL?
        if let audioStream {
            let target = directory.appendingPathComponent("audio.mp4")
            try await fetch(audioStream, headers: headers, to: target) { [weak self] value in
                self?.update(id) { $0.progress = videoWeight + value * audioWeight }
            }
            audioFile = target
        }

        update(id) {
            $0.state = .remuxing
            $0.progress = 0.9
        }

        let output = directory.appendingPathComponent("output.mp4")
        try await Remuxer.merge(
            video: videoFile,
            audio: audioFile,
            output: output,
            codec: settings.videoCodec
        )

        update(id) {
            $0.state = .saving
            $0.progress = 0.97
        }

        let job = jobs.first(where: { $0.id == id })
        let name = job?.fileName(ext: "mp4") ?? "\(id.uuidString).mp4"
        try await settings.outputSink.deliver(
            fileAt: output,
            fileName: name,
            kind: job?.kind ?? .audiovisual
        )
    }

    // MARK: - 仅音频

    private func runAudioOnly(id: UUID, play: PlayInfo, headers: [String: String], directory: URL) async throws {
        guard let audioStream = StreamSelector.audio(from: play) else {
            throw BiliError.noStream
        }

        update(id) {
            $0.state = .downloading
            $0.progress = 0
        }

        let audioFile = directory.appendingPathComponent("audio.mp4")
        try await fetch(audioStream, headers: headers, to: audioFile) { [weak self] value in
            self?.update(id) { $0.progress = value * 0.9 }
        }

        update(id) {
            $0.state = .remuxing
            $0.progress = 0.9
        }

        let format = settings.audioFormat
        let output = directory.appendingPathComponent("output.\(format.fileExtension)")
        try await AudioExporter.convert(source: audioFile, output: output, format: format)

        update(id) {
            $0.state = .saving
            $0.progress = 0.97
        }

        let name = jobs.first(where: { $0.id == id })?
            .fileName(ext: format.fileExtension) ?? "\(id.uuidString).\(format.fileExtension)"

        // 「相册不收纯音频」这条规矩在 sink 里，队列不用操心
        try await settings.outputSink.deliver(fileAt: output, fileName: name, kind: .audioOnly)
    }

    // MARK: - 封面图

    private func runCover(id: UUID, coverURL: URL, directory: URL) async throws {
        update(id) {
            $0.state = .downloading
            $0.progress = 0
        }

        let ext = coverURL.pathExtension.isEmpty ? "jpg" : coverURL.pathExtension
        let file = directory.appendingPathComponent("cover.\(ext)")

        try await fetch([coverURL], headers: client.mediaHeaders(), to: file) { [weak self] value in
            self?.update(id) { $0.progress = value * 0.9 }
        }

        update(id) {
            $0.state = .saving
            $0.progress = 0.97
        }

        let name = jobs.first(where: { $0.id == id })?.fileName(ext: ext) ?? "\(id.uuidString).\(ext)"
        try await settings.outputSink.deliver(fileAt: file, fileName: name, kind: .cover)
    }

    // MARK: - 下载单个流

    /// 主地址失败就换 backupUrl。B 站的 PCDN 节点时不时握手失败，
    /// 备用地址就是为这种情况准备的。
    private func fetch(
        _ stream: MediaStream,
        headers: [String: String],
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try await fetch([stream.url] + stream.backupURLs, headers: headers, to: destination, onProgress: onProgress)
    }

    private func fetch(
        _ candidates: [URL],
        headers: [String: String],
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var lastError: Error?

        for url in candidates {
            do {
                try await downloadOnce(url, headers: headers, to: destination, onProgress: onProgress)
                return
            } catch {
                // 停止掐断的那次不算失败，别去试备用地址了
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                onProgress(0)
            }
        }
        throw lastError ?? BiliError.noStream
    }

    private func downloadOnce(
        _ url: URL,
        headers: [String: String],
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let downloader = FileDownloader()
        let throttle = ProgressThrottle()

        _ = try await downloader.download(from: url, headers: headers, to: destination) { value in
            guard throttle.shouldEmit(value) else { return }
            Task { @MainActor in onProgress(value) }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        schedulePersist()
    }

    // MARK: - 落盘

    /// 队列放内存里的话，一退出 App 列表就没了。
    private static func storeURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base.appendingPathComponent("jobs.json")
    }

    /// 重启时把没跑完的重新排上。临时文件早清了，进度只能归零重下。
    private static func resumable(_ job: DownloadJob) -> DownloadJob {
        var job = job
        switch job.state {
        case .resolving, .downloading, .remuxing, .saving:
            job.state = .queued
            job.progress = 0
        case .queued, .stopped, .finished, .failed:
            // 停下的保持停下，别自作主张替用户接着下
            break
        }
        return job
    }

    /// 进度回调很密，攒一下再写盘
    private func schedulePersist() {
        guard storeURL != nil else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard let storeURL, let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// 进度回调一秒能来几百次，只在变化够明显时才往界面上推。
private final class ProgressThrottle: @unchecked Sendable {

    private let step: Double
    private var last: Double = -1

    init(step: Double = 0.005) {
        self.step = step
    }

    func shouldEmit(_ value: Double) -> Bool {
        if value >= 1 || value - last >= step {
            last = value
            return true
        }
        return false
    }
}
