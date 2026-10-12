import SwiftUI
import BiliCore
import BiliKit

/// 添加页里一行「识别结果」该长什么样。
/// 这个是给界面看的那一份，跟底层模型分开 ——
/// 底层那份是「拉到什么就存什么」，「正在获取视频信息…」这种话是给人看的。
public struct InputRowContent {
    public let thumbnail: InputThumbnail
    public let title: String
    public let titleColor: Color
    /// 第二行的 UP 主名。整批来源没有这个概念（主页那条自己就是 UP 主，
    /// 合集那条接口不给名字），给 nil —— 那一行的地方照样留着。
    public let ownerName: String?
    /// 第三行那串号：视频是 BV 号，整批来源是 UID / 合集 ID
    public let identifier: String
    /// 第三行**最右头**那句话：多 P 视频的「已选 3 P」（总 P 数在封面气泡里），
    /// 整批来源的「共 N 个视频 · 已选 N 个」。
    public let trailing: String?
    /// 封面上那个气泡里的字（单 P 视频的时长、多 P 视频的总 P 数）
    public let badge: String?
    /// 付费 / 充电专属：封面左下角挂枚粉色标记（见 `CoverThumbnail`）。
    /// 整批来源那两条不是「一个视频」，一直是 false。
    public let isPremium: Bool
    /// 有内容可挑才给那个按钮（多 P 视频、拉到东西的整批来源）
    public let canPick: Bool
}

/// 「添加任务」那一页的状态机：把用户敲 / 粘 / 从外面递进来的一坨文本
/// 解析成待添加的条目，逐条去拉视频信息，整批来源（UP 主投稿 / 合集）
/// 边拉边缓存，最后把勾好的东西翻成一串 `ParsedTarget` 交给队列。
///
/// 这套东西跟平台一点关系都没有，iOS 和 macOS 两个添加页共用它，
/// 各自只剩「怎么把这些字段摆到屏幕上」。
///
/// 队列是**按调用传进来**的，不存成属性：`DownloadQueue` 活在环境里，
/// 而这玩意儿是 `@StateObject`，构造的时候还拿不到环境。与其搞一个
/// 「先 attach 再能用」的半残状态，不如让需要它的方法自己收参数。
@MainActor
public final class TargetResolver: ObservableObject {

    // MARK: - 解析出来的东西

    @Published public private(set) var entries: [InputEntry] = []

    /// 已经拉到手的视频信息，按视频号缓存
    @Published public private(set) var infos: [VideoRef: VideoInfo] = [:]
    @Published public private(set) var failedRefs: Set<VideoRef> = []
    private var pendingRefs: Set<VideoRef> = []

    /// 整批来源目前拉到的内容，按来源缓存
    @Published public private(set) var bulkStates: [BulkSource: BulkState] = [:]
    @Published public private(set) var bulkFailed: Set<BulkSource> = []
    /// 正在往后翻页的来源，选择器里显示个转圈
    @Published public private(set) var bulkPaging: Set<BulkSource> = []
    private var bulkPending: Set<BulkSource> = []

    // MARK: - 用户挑的

    /// 用户在分 P 选择器里手动挑过的，只加挑中的那几 P。
    /// 没挑过的多 P 视频不记在这儿 —— 入队后由队列展开成全部 P。
    @Published public var pageSelection: [VideoRef: Set<Int>] = [:]
    /// 用户在整批选择器里挑的。没记在这儿的就是「全都要」
    @Published public var bulkSelection: [BulkSource: VideoSelection] = [:]

    private var resolveTask: Task<Void, Never>?

    public init() {}

    /// 页面走了就把还在跑的循环掐掉，别让它攥着队列和网络连接不放。
    /// 顺手把 `resolveTask` 清空 —— 不然下次 `sync` 会以为还有一个在跑，
    /// 再也不启动了。
    public func cancel() {
        resolveTask?.cancel()
        resolveTask = nil
    }

    // MARK: - 输入

    /// 文本框那条路：内容每次变化都重新解析一遍。
    ///
    /// 中间隔了一层比对：用户删掉一个多余空格、或者改了个不影响视频号的
    /// URL 参数时，解析出来的目标列表是一模一样的，那就不该把下面的信息
    /// 重新拉一遍、把已经挑好的分 P 清掉。
    public func sync(text: String, using queue: DownloadQueue) {
        apply(ShareLinkParser.parseEntries(text), using: queue)
    }

    /// 从外面递进来的那条路（剪贴板 / URL Scheme / 拖放）：
    /// 内容已经定死了，没有文本框可解析，直接把条目摆上、开始拉信息。
    public func adopt(_ entries: [InputEntry], using queue: DownloadQueue) {
        guard !entries.isEmpty else { return }
        apply(entries, using: queue)
    }

    private func apply(_ parsed: [InputEntry], using queue: DownloadQueue) {
        guard parsed != entries else { return }
        entries = parsed

        // 已经删掉的，缓存、失败标记和挑过的分 P 一起清掉，回头再加还能重新拉
        let liveRefs = Set(parsed.compactMap(\.video).map(\.ref))
        let liveSources = Set(parsed.compactMap(\.bulk))

        infos = infos.filter { liveRefs.contains($0.key) }
        failedRefs.formIntersection(liveRefs)
        pageSelection = pageSelection.filter { liveRefs.contains($0.key) }

        bulkStates = bulkStates.filter { liveSources.contains($0.key) }
        bulkFailed.formIntersection(liveSources)
        bulkSelection = bulkSelection.filter { liveSources.contains($0.key) }

        startResolving(using: queue)
    }

    /// 整批来源还没拉到，就不知道要加多少个，添加按钮先按着
    public var isResolvingBulk: Bool {
        entries.compactMap(\.bulk).contains { bulkStates[$0] == nil && !bulkFailed.contains($0) }
    }

    /// 添加按钮上那个数字
    public var countText: String {
        entries.isEmpty ? "添加" : "添加 \(entries.count) 个"
    }

    // MARK: - 给界面看的字段

    public func content(for entry: InputEntry) -> InputRowContent {
        switch entry {
        case .video(let target):
            let info = infos[target.ref]
            var badge: String?
            var selectedPages: String?
            if let info = info {
                if info.isMultiPage {
                    // 多 P：**总 P 数进封面气泡**，写成「共 12 P」——
                    // 光写「12P」会被当成 1080P 那种画质标，加个「共」才是「一共几 P」。
                    badge = "共 \(info.pages.count) P"
                    // 已选几 P 挂在第二行最右头（那边就不报总 P 了，气泡里已经有了）。
                    selectedPages = "已选 \(selectedPageCount(target, info: info)) P"
                } else {
                    // 单 P：气泡里还是时长
                    badge = badgeDuration(target)
                }
            }
            return InputRowContent(
                thumbnail: .cover(info?.coverURL),
                title: videoTitle(target.ref),
                titleColor: videoTitleColor(target.ref),
                ownerName: info?.ownerName,
                identifier: info?.bvid ?? target.ref.key,
                trailing: selectedPages,
                badge: badge,
                // 信息还没拉回来的时候是 false：标记只画「已经知道要钱」的，
                // 拉回来之前先不画，免得闪一下
                isPremium: info?.isPremium == true,
                canPick: info?.isMultiPage == true
            )

        case .bulk(let source):
            let state = bulkStates[source]
            let failed = bulkFailed.contains(source)
            let detail = bulkDetail(source, state: state)

            return InputRowContent(
                thumbnail: bulkThumbnail(source, state: state),
                title: bulkTitle(source, state: state, failed: failed),
                titleColor: failed ? .orange : .primary,
                // 整批来源没有 UP 主这一层：主页那条的第一行**就是**这个 UP 主的名字
                // （再报一遍是重复），合集那条接口不给名字。空着，位置留着。
                ownerName: nil,
                identifier: bulkIdentifier(source),
                // 整批来源没有 P 数的概念：封面（合集封面 / UP 主头像）上没东西可标，
                // 第三行最右头报的是「共 N 个视频 · 已选 N 个」——「这一批里有多少、
                // 要下多少」是这一行的全部信息量。
                trailing: detail.isEmpty ? nil : detail,
                badge: nil,
                // 这一行不是「一个视频」：点开是一堆人 / 一堆视频，
                // 「其中有一条要钱」不是这一行能说清的事，所以不挂标记
                isPremium: false,
                // 一条都没拉到就没什么可挑的
                canPick: state?.videos.isEmpty == false
            )
        }
    }

    /// 那个「挑一挑」的按钮被点了，该弹哪个选择器
    public func pickerTarget(for entry: InputEntry) -> PickTarget {
        switch entry {
        case .video(let target): return .pages(target)
        case .bulk(let source): return .bulk(source)
        }
    }

    public enum PickTarget: Hashable, Identifiable {
        case pages(ParsedTarget)
        case bulk(BulkSource)

        public var id: Self { self }
    }

    public func state(for source: BulkSource) -> BulkState? { bulkStates[source] }

    /// 没挑过就是全都要 —— 没拉下来的那些也算在内
    public func selection(for source: BulkSource) -> VideoSelection {
        bulkSelection[source] ?? .all(except: [])
    }

    /// 整批选择器的数据源。凑在这儿，两个平台的视图就不用各自拼一遍了。
    public func pickerModel(for source: BulkSource) -> VideoPickerModel {
        let state = bulkStates[source]
        return VideoPickerModel(
            listTitle: source.isCollection
                ? (state?.collectionTitle ?? "合集 \(source.seasonID ?? 0)")
                : (state?.profile?.name ?? "UP 主 \(source.mid)"),
            videos: state?.videos ?? [],
            total: state?.total ?? 0,
            isLoadingMore: bulkPaging.contains(source),
            selection: selection(for: source)
        )
    }

    /// 手动挑过就用挑的；链接里写死了 ?p= 就是那一个；其它情况默认整季
    private func selectedPageCount(_ target: ParsedTarget, info: VideoInfo) -> Int {
        if let pages = pageSelection[target.ref] { return pages.count }
        if target.page != nil { return 1 }
        return info.pages.count
    }

    private func videoTitle(_ ref: VideoRef) -> String {
        if let info = infos[ref] { return info.title }
        return failedRefs.contains(ref) ? "无法获取视频信息" : "正在获取视频信息…"
    }

    private func videoTitleColor(_ ref: VideoRef) -> Color {
        if infos[ref] != nil { return .primary }
        return failedRefs.contains(ref) ? .orange : .secondary
    }

    /// 单 P 视频封面气泡里那个时长（`1:02:33`）。
    /// 链接指定了哪一 P 就报哪一 P 的；多 P 的气泡里装的是总 P 数，走不着这儿。
    private func badgeDuration(_ target: ParsedTarget) -> String? {
        guard let info = infos[target.ref] else { return nil }
        let page = info.pages.first { $0.page == (target.page ?? 1) } ?? info.pages.first
        guard let seconds = page?.duration else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 整批来源的行

    /// 合集用合集自己的封面，主页用 UP 主头像。
    private func bulkThumbnail(_ source: BulkSource, state: BulkState?) -> InputThumbnail {
        guard let state else { return .cover(nil) }
        return source.isCollection ? .cover(state.collectionCover) : .avatar(state.profile?.avatarURL)
    }

    private func bulkTitle(_ source: BulkSource, state: BulkState?, failed: Bool) -> String {
        guard let state else {
            return failed ? "拿不到这个来源" : "正在读取…"
        }
        if source.isCollection {
            return state.collectionTitle ?? "合集 \(source.seasonID ?? 0)"
        }
        return state.profile?.name ?? "UP 主 \(source.mid)"
    }

    private func bulkIdentifier(_ source: BulkSource) -> String {
        if let seasonID = source.seasonID {
            return "合集 ID \(seasonID)"
        }
        return "UID \(source.mid)"
    }

    private func bulkDetail(_ source: BulkSource, state: BulkState?) -> String {
        guard let state else { return "" }
        let picked = selection(for: source).count(total: state.total)
        return "共 \(state.total) 个视频 · 已选 \(picked) 个"
    }

    // MARK: - 挑完回填

    public func confirm(pages: [Int], for target: ParsedTarget) {
        pageSelection[target.ref] = Set(pages)
    }

    public func confirm(selection: VideoSelection, for source: BulkSource) {
        bulkSelection[source] = selection
    }

    // MARK: - 入队

    /// 把「已经勾好的这些」翻成一串待入队目标，交给队列去展开。
    public func targets(using queue: DownloadQueue) async -> [ParsedTarget] {
        var toAdd: [ParsedTarget] = []

        for entry in entries {
            switch entry {
            case .video(let target):
                if let pages = pageSelection[target.ref], !pages.isEmpty {
                    // 手动挑过的：只加挑中的那几 P
                    toAdd.append(contentsOf: pages.sorted().map { ParsedTarget(ref: target.ref, page: $0) })
                } else if let page = target.page {
                    // 链接里写死了 ?p=，就按链接来
                    toAdd.append(ParsedTarget(ref: target.ref, page: page))
                } else {
                    // 剩下的原样入队。多 P 视频交给队列展开成全部 P
                    toAdd.append(target)
                }

            case .bulk(let source):
                switch selection(for: source) {
                case .only(let picked):
                    // 只要这几个：不用再往后翻了
                    toAdd.append(contentsOf: picked.sorted().map { ParsedTarget(ref: .bvid($0)) })

                case .all(let except):
                    // 全都要：剩下的页得翻完才知道有哪些，边翻边把排除的剔掉
                    for video in await allVideos(of: source, using: queue) where !except.contains(video.bvid) {
                        toAdd.append(ParsedTarget(ref: .bvid(video.bvid)))
                    }
                }
            }
        }

        return toAdd
    }

    /// 添加完把挑的东西清掉 —— 留着的话，用户再打开这一页会看见上次的勾选，
    /// 而队列里那些早就加过了。
    public func resetSelection() {
        pageSelection.removeAll()
        bulkSelection.removeAll()
    }

    // MARK: - 加载

    /// 选择器里滚到底了，接着往后拉一页
    public func loadMoreBulk(_ source: BulkSource, using queue: DownloadQueue) async {
        guard var state = bulkStates[source], state.hasMore, !bulkPaging.contains(source) else { return }
        bulkPaging.insert(source)
        defer { bulkPaging.remove(source) }

        do {
            let next = try await queue.bulkPage(source, page: state.nextPage)
            let known = Set(state.videos.map(\.bvid))
            state.videos.append(contentsOf: next.videos.filter { !known.contains($0.bvid) })
            state.hasMore = next.hasMore
            state.nextPage += 1
        } catch {
            state.hasMore = false
        }
        bulkStates[source] = state
    }

    /// 把剩下的页一页页翻完。中途翻不动了就把已经拿到的交出去，总比一条都不加强。
    private func allVideos(of source: BulkSource, using queue: DownloadQueue) async -> [BulkVideo] {
        guard var state = bulkStates[source] else { return [] }

        while state.hasMore {
            do {
                let next = try await queue.bulkPage(source, page: state.nextPage)
                let known = Set(state.videos.map(\.bvid))
                state.videos.append(contentsOf: next.videos.filter { !known.contains($0.bvid) })
                state.hasMore = next.hasMore
                state.nextPage += 1
            } catch {
                break
            }
        }

        bulkStates[source] = state
        return state.videos
    }

    /// 已经在跑的话不用再开一个，那个循环会自己捡起新冒出来的目标。
    private func startResolving(using queue: DownloadQueue) {
        guard resolveTask == nil else { return }
        resolveTask = Task { [weak self] in
            await self?.resolveLoop(using: queue)
        }
    }

    private func resolveLoop(using queue: DownloadQueue) async {
        while !Task.isCancelled {
            if let next = entries.compactMap(\.video).first(where: {
                infos[$0.ref] == nil && !failedRefs.contains($0.ref) && !pendingRefs.contains($0.ref)
            }) {
                pendingRefs.insert(next.ref)
                do {
                    let info = try await queue.videoInfo(for: next.ref)
                    guard !Task.isCancelled else { return }
                    infos[next.ref] = info
                } catch {
                    guard !Task.isCancelled else { return }
                    failedRefs.insert(next.ref)
                }
                pendingRefs.remove(next.ref)
                continue
            }

            guard let source = entries.compactMap(\.bulk).first(where: {
                bulkStates[$0] == nil && !bulkFailed.contains($0) && !bulkPending.contains($0)
            }) else { break }

            bulkPending.insert(source)
            do {
                let result = try await queue.bulkPage(source, page: 1)
                guard !Task.isCancelled else { return }
                bulkStates[source] = BulkState(result: result)
            } catch {
                guard !Task.isCancelled else { return }
                bulkFailed.insert(source)
            }
            bulkPending.remove(source)
        }
        resolveTask = nil
    }
}

/// 整批选择器要的那几样东西。从解析器里取出来打包给视图，
/// 省得两个平台的视图各自去 resolver 上抠一遍。
public struct VideoPickerModel {
    public let listTitle: String
    public let videos: [BulkVideo]
    public let total: Int
    public let isLoadingMore: Bool
    public let selection: VideoSelection
}
