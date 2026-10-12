import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 「挑视频」那一层：一个收藏夹 / 一个合集 / 一季番剧 / 稍后再看 / 历史记录
/// 里面的视频列表 —— 勾几个，然后入队。
///
/// 五个来源在这一层长得一模一样，区别只有标题、空态文案和拉哪个接口，
/// 所以共用这一个视图（跟 iOS 的 `VideoPickerView` 是两边各一份）。
/// 流程也跟 iOS 版一模一样（分 P 的弹选择器、全选是真的「整个夹子」、
/// 搜索得先把全量翻回来），差别只在按钮挪到了顶栏、左滑换成了右键菜单。
struct MacLibraryDetailView: View {

    let source: LibrarySource

    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var settings: AppSettings

    @State private var items: [FavItem] = []
    /// bvid -> 选中的分 P。单 P 的用 [1] 占位，只用来表示「选上了」。
    @State private var selection: [String: Set<Int>] = [:]
    /// 全选模式：全部都要，除了 excluded 里那几个。
    /// 列表是滚到哪加到哪的，全选不能写成「已加载的这些」——
    /// 一千条的收藏夹滚了二十条就点全选，那样只会下二十条。
    @State private var selectAllMode = false
    @State private var excluded: Set<String> = []
    /// 正在为「全都要」点数（见 `toggleAll()`）。
    @State private var isCountingAll = false
    @State private var page = 1
    /// 历史记录不看页号，只认这个游标（见 `BiliClient.history`）。
    /// 第一页是 nil，之后每翻一页就用上一页返回的那个。
    @State private var cursor: HistoryCursor?
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var pagePickerItem: FavItem?
    @State private var query = ""
    @State private var hud: HUD?

    var body: some View {
        content
            .navigationTitle(source.title)
            .searchable(text: $query, prompt: "搜索视频")
            // 搜索得搜全量：列表是翻到哪算哪的（一页 20 条），
            // 只筛已经拉回来的那几页等于没搜 —— 一千条的夹子里搜个标题，
            // 结果全看滚到哪儿了，那这个搜索框还不如没有。
            // 所以一开始打字就把剩下的页全翻回来。
            .onChangeCompat(of: query) { newValue in
                guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { await loadRestForSearch() }
            }
            // 顶栏左边「下载」、右边「刷新」，**一整组**。
            //
            // 原来这两颗是分开的两个 `ToolbarItem`，还各自钉了 id。那套在 mac 上
            // 会把按钮弄丢：工具栏项是挂在声明它的视图身上的，这一页又会被整个
            // 换掉（切栏目时 detail 挂着 `.id(section)`，追番那边进出分集也是换根），
            // 钉了 id 的新旧两项赶上同一趟重建，AppKit 按 id 去重就把整项丢了 ——
            // 表现就是「有时候缺下载，有时候下载和刷新都没了」。下载页那排按钮
            // 也踩过，并成一组、不钉 id 之后就再没丢过（见 MacDownloadsView 里那段）。
            //
            // 并成一组还有个好处：这一组就一项，切栏目时新旧对得上号，
            // 「旁边冒出个空的 >>」那个老毛病也不会回来。
            //
            // 次序是**先下载后刷新**：同一组里按声明顺序从左往右排，
            // 而搜索框永远占着顶栏最右一格 —— 所以刷新落在下载右边、搜索框左边，
            // 跟收藏 / 合集列表页那颗刷新在同一个位置上。
            //
            // 按钮本身在 MacRefreshButton 里，跟列表页那颗是同一个。
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    downloadMenu

                    MacRefreshButton(isLoading: isLoading) {
                        Task { await loadFirstPage() }
                    }
                }
            }
            .task { await loadFirstPage() }
            // 收藏夹那几页的付费标记本来要在这儿补问一轮（见 `resolvePremiums`）——
            // **已封存**，不调用。一页二十条就是二十个请求，换一枚标记不值，
            // 而且这个接口（`fav/resource/list`）怎么都省不掉这一步
            // （它的 media 对象一个付费字段都没有）。要重新打开，把下面这行加回来：
            // .task(id: items.count) { await resolvePremiums() }
            .refreshable { await loadFirstPage() }
            .sheet(item: $pagePickerItem) { item in
                MacPagePickerSheet(target: ParsedTarget(ref: .bvid(item.bvid)), confirmVerb: "选择") { pages in
                    selection[item.bvid] = Set(pages)
                }
            }
            .hud($hud)
    }

    /// 挑哪种、下多少，都收在一个菜单里 —— mac 上没地方摆一大排按钮。
    private var downloadMenu: some View {
        Menu {
            ForEach(DownloadKind.allCases) { kind in
                Button(kind.displayName) { download(kind: kind) }
            }
        } label: {
            Label(downloadButtonTitle, systemImage: "arrow.down.circle")
        }
        .disabled(selectedCount == 0 || isCountingAll)
    }

    // MARK: - 显示的那一份

    /// 界面上真正要显示的那些条目。开了「过滤无效内容」就把失效的摘掉。
    /// 全选和入队也走这个，不然勾了半天把下不了的也算进去了。
    private var visibleItems: [FavItem] {
        let kept = settings.filterInvalidContent ? items.filter(\.isAvailable) : items
        return SearchFilter.match(kept, query: query) { [$0.title, $0.upperName] }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        // 空态浮在列表上，不摆进 List 当行 —— 当行只能贴着顶，见 MacLibraryList
        // 里那段。List 本身还是同一个，滚动位置不受影响。
        List {
            if !items.isEmpty && !visibleItems.isEmpty {
                // 这一格右端原来是收藏夹名 / 合集名 —— 那名字现在就在上面
                // 那行页标题上，再来一遍是重复。改成报已选数量：
                // 勾着勾着能看着它涨，比一个重复的名字有用。
                //
                // 稍后再看有这一行（一次给全，数目数得出来），历史记录没有
                // （游标翻页翻不到底）—— 谁摆谁不摆归 `supportsSelectAll` 管。
                if source.supportsSelectAll {
                    SelectAllRow(
                        state: allState,
                        trailingText: selectedCountText,
                        symbolFont: .title3
                    ) {
                        toggleAll()
                    }
                    .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                }

                ForEach(visibleItems) { item in
                    FavItemRow(
                        item: item,
                        state: checkState(for: item),
                        selectedPages: selectedPageCount(for: item)
                    ) {
                        tap(item)
                    }
                    // 上下各垫一点：mac 的 List 行是贴着的，跟收藏夹列表、
                    // 添加任务那页取的是同一个数（见 `ListRowMetrics`）
                    .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                    .contextMenu {
                        Button("复制 BV 号") { copyBV(item.bvid) }
                        Button("复制视频链接") { copyLink(item.bvid) }
                    }
                    .onAppear {
                        if item.bvid == visibleItems.last?.bvid {
                            Task { await loadMore() }
                        }
                    }
                }

                if isLoadingMore {
                    LoadMoreSpinner()
                }
            }
        }
        .overlay { placeholder }
    }

    /// 正在读 / 读失败 / 空 / 搜索没结果时浮在列表中间的那一块。
    @ViewBuilder
    private var placeholder: some View {
        if items.isEmpty {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ListPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: source.errorTitle,
                    message: errorMessage,
                    retry: { Task { await loadFirstPage() } }
                )
            } else {
                ListPlaceholder(icon: "tray", title: source.emptyTitle)
            }
        } else if visibleItems.isEmpty {
            ListPlaceholder(
                icon: "magnifyingglass",
                title: isSearching ? "没有匹配的视频" : source.emptyTitle
            )
        }
    }

    /// 「全都要」会下多少个。
    ///
    /// 全都要的时候得报整个收藏夹的数量，不是已经拉到的那些 —— 但**翻完之前
    /// 那个数报不准**：开着「隐藏失效内容」的时候，接口给的总数里混着失效的，
    /// 而失效的入不了队（见下面 performDownload 那一段）。
    ///
    /// 所以分两种情况：**翻完了就直接数手里这一份**（已经滤过失效，
    /// 这个数跟真正入队的条数一定一样）；没翻完的先用接口的总数顶着，
    /// 同时 `toggleAll()` 那边已经在翻了，转完就换成准的。
    ///
    /// 搜索状态下不用翻：打字那会儿已经把全量拉回来了，「全都要」就是
    /// 「搜出来的这些」，数眼前这一份是准的。
    ///
    /// 稍后再看 / 历史记录走不到「全都要」（没有全选那一行），
    /// 取 videoCount 的地方兜一个可见条数，纯粹是不想让这儿出现 `?? 0`。
    private var selectedCount: Int {
        guard selectAllMode else { return selection.count }
        if isSearching || !hasMore {
            return max(visibleItems.count - excluded.count, 0)
        }
        return max((source.videoCount ?? visibleItems.count) - excluded.count, 0)
    }

    private var downloadButtonTitle: String {
        if isCountingAll { return "统计中…" }
        return selectedCount == 0 ? "下载" : "下载 \(selectedCount) 个"
    }

    /// 全选那一行右端那句话。一个没勾就空着 ——
    /// 「已选 0 个」是一句没有信息量的话，不如让那一格干净着。
    ///
    /// mac 这一格摆的**一直是**已选数量（夹子名挂在页标题上，这儿不放名字），
    /// 所以「正在统计」这句话也得从这儿出 —— iOS 那边这一格放的是夹子名，
    /// 那句话就只落在下载按钮上。
    private var selectedCountText: String? {
        if isCountingAll { return "正在统计…" }
        return selectedCount == 0 ? nil : "已选 \(selectedCount) 个"
    }

    // MARK: - 勾选

    private func checkState(for item: FavItem) -> FavItemRow.CheckState {
        if selectAllMode {
            return excluded.contains(item.bvid) ? .none : .all
        }
        guard let pages = selection[item.bvid], !pages.isEmpty else { return .none }
        guard item.isMultiPage else { return .all }
        return pages.count >= item.pageCount ? .all : .partial
    }

    /// 这个条目勾了几 P。全都要的时候多 P 视频整季都算上。
    private func selectedPageCount(for item: FavItem) -> Int? {
        if selectAllMode {
            return excluded.contains(item.bvid) ? nil : item.pageCount
        }
        return selection[item.bvid]?.count
    }

    /// 全选就是整个收藏夹全要，包括还没滚到的那些 —— 一千条也只下一次。
    /// 再点一下全部取消。分 P 视频整季一起要，不会弹出分 P 选择器。
    private func toggleAll() {
        if allState == .all {
            selectAllMode = false
            selection.removeAll()
            excluded.removeAll()
            return
        }

        selectAllMode = true
        selection.removeAll()
        excluded.removeAll()

        // 「全都要」到底是多少个，开着「隐藏失效内容」的时候得把整个夹子翻完
        // 才算得出来（接口的总数里混着失效的）。这一趟不用白翻：下载那一刻
        // 本来就要翻，早翻还能让「已选 N 个」一开始就是准的 ——
        // 不会出现「说好 220 个，结果只进来 215 个」。
        //
        // 开关关着的时候不用翻：那时候接口的总数就是准数。
        guard settings.filterInvalidContent, hasMore, !isSearching else { return }
        isCountingAll = true
        Task {
            _ = await loadAllItems()
            isCountingAll = false
        }
    }

    private var allState: SelectAllRow.State {
        if selectAllMode { return excluded.isEmpty ? .all : .partial }
        return selection.isEmpty ? .none : .partial
    }

    private func tap(_ item: FavItem) {
        if selectAllMode {
            // 全都要的模式下点条目就是「这个不要」，分 P 的整个算一个
            if excluded.contains(item.bvid) {
                excluded.remove(item.bvid)
            } else {
                excluded.insert(item.bvid)
            }
            return
        }

        if item.isMultiPage {
            // 分 P 的得先问要哪几 P
            if selection[item.bvid] == nil {
                pagePickerItem = item
            } else {
                selection[item.bvid] = nil
            }
        } else if selection[item.bvid] == nil {
            selection[item.bvid] = [1]
        } else {
            selection[item.bvid] = nil
        }
    }

    private func copyBV(_ bvid: String) {
        MacPasteboard.copy(bvid)
        hud = HUD(icon: "doc.on.doc.fill", text: "已复制 \(bvid)")
    }

    /// 复制的是网页版地址（`https://www.bilibili.com/video/BV…`），不是 BV 号。
    /// 提示里不摆地址：那条 URL 比整块 HUD 还长，摆出来也只有截断的下场。
    private func copyLink(_ bvid: String) {
        MacPasteboard.copy(VideoRef.bvid(bvid).webURL)
        hud = HUD(icon: "link", text: "已复制视频链接")
    }

    // MARK: - 入队

    private func download(kind: DownloadKind) {
        Task { await performDownload(kind: kind) }
    }

    private func performDownload(kind: DownloadKind) async {
        // 全都要的话得先把整个收藏夹翻完，不然只加到滚过的那几条。
        // 搜索状态下不用翻：打字那会儿已经把全量拉回来了。
        let pool = (selectAllMode && !isSearching) ? await loadAllItems() : visibleItems

        var targets: [ParsedTarget] = []
        for item in pool {
            if selectAllMode {
                guard !excluded.contains(item.bvid) else { continue }
                // 分 P 的不点明哪一 P，交给队列自己展开成全部 P
                targets.append(ParsedTarget(ref: .bvid(item.bvid)))
                continue
            }
            guard let pages = selection[item.bvid], !pages.isEmpty else { continue }
            if item.isMultiPage {
                for page in pages.sorted() {
                    targets.append(ParsedTarget(ref: .bvid(item.bvid), page: page))
                }
            } else {
                targets.append(ParsedTarget(ref: .bvid(item.bvid)))
            }
        }

        let added = queue.add(targets, kind: kind)
        selectAllMode = false
        excluded.removeAll()
        selection.removeAll()
        // 入队反馈走 HUD，弹窗还得用户自己点掉，太烦
        hud = added > 0
            ? HUD(icon: "checkmark.circle.fill", text: "已添加 \(added) 个视频")
            : HUD(icon: "info.circle.fill", text: "这些视频已经在队列里了")
    }

    /// 把后面几页全翻出来。中途翻不动了就交已经拿到的，总比一条都不加强。
    private func loadAllItems() async -> [FavItem] {
        var all = items
        var known = Set(all.map(\.bvid))
        var next = page
        var more = hasMore

        while more {
            guard let result = try? await loadPage(next) else { break }
            all.append(contentsOf: result.items.filter { known.insert($0.bvid).inserted })
            more = result.hasMore
            next += 1
        }

        items = all
        page = next
        hasMore = false
        return settings.filterInvalidContent ? all.filter(\.isAvailable) : all
    }

    // MARK: - 加载

    /// 各个来源各走各的接口，出来的东西归一成同一种条目。
    ///
    /// `page` 对历史记录没意义（它是游标翻的），那种情况走 `cursor` 那个状态；
    /// 别的来源每次调用都会把 cursor 覆盖成 nil 也无所谓，反正用不上。
    private func loadPage(_ page: Int) async throws -> (items: [FavItem], hasMore: Bool) {
        switch source {
        case .folder(let folder):
            return try await queue.favoriteItems(folderID: folder.id, page: page)

        case .collection(let collection):
            let result = try await queue.collectedItems(collection, page: page)
            let items = result.videos.map {
                FavItem(
                    bvid: $0.bvid,
                    title: $0.title,
                    coverURL: $0.coverURL,
                    duration: $0.duration,
                    upperName: collection.ownerName,
                    pageCount: $0.pageCount,
                    isPremium: $0.isPremium
                )
            }
            return (items, result.hasMore)

        case .season(let season):
            // 一季的分集一次全给（几百集也是一次），没有下一页
            let episodes = try await queue.seasonEpisodes(seasonID: season.seasonID)
            return (episodes, false)

        case .uploads(let mid, let ownerName):
            // 投稿这一档目前只有 iOS 造得出来（「我的关注」→ 分组 → 人 → TA 的投稿），
            // mac 侧边栏没有这条路。这一支留着是因为 `LibrarySource` 是两端共用的，
            // 少一支就编不过 —— 真接起来的时候（比如 mac 也加个关注栏目）行为已经在这儿了：
            // 跟 iOS 一样，按发布时间倒序，一页 30 条。
            let result = try await queue.bulkPage(.uploads(mid: mid), page: page)
            let items = result.videos.map {
                FavItem(
                    bvid: $0.bvid,
                    title: $0.title,
                    coverURL: $0.coverURL,
                    duration: $0.duration,
                    upperName: ownerName,
                    pageCount: $0.pageCount,
                    isPremium: $0.isPremium
                )
            }
            return (items, result.hasMore)

        case .watchLater:
            // 同理：B 站这个列表封顶 100 条，也是一次给全
            let result = try await queue.watchLater()
            return (result.items, false)

        case .history:
            let result = try await queue.history(cursor: cursor)
            cursor = result.cursor
            return (result.items, result.hasMore)
        }
    }

    /// 搜索要拿全量，把还没翻的页一次翻完。
    private func loadRestForSearch() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        _ = await loadAllItems()
    }

    /// 重新拉第一页。
    ///
    /// **不碰勾选**：`selection` / `excluded` / `selectAllMode` 都是按 bvid 存的，
    /// 换一批 items 它们照样有效 —— 刷新完勾还在。收藏夹里刚删掉的那个视频
    /// 也留着：bvid 本身还是能下的，替用户把它取消掉反而是帮倒忙。
    ///
    /// 拉之前本来就有东西的话，失败得靠 HUD 出声。下面那块 errorMessage 只在
    /// 列表空着的时候才画得出来，列表里还摆着旧数据时它什么都不显示 ——
    /// 点一下刷新，转一圈，然后什么都没变，看着就像这颗按钮是坏的。
    private func loadFirstPage() async {
        let hadContent = !items.isEmpty
        isLoading = true
        errorMessage = nil
        page = 1
        cursor = nil
        hasMore = true
        do {
            let result = try await loadPage(1)
            items = result.items
            hasMore = result.hasMore
            page = 2
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            if hadContent {
                hud = HUD(icon: "exclamationmark.triangle.fill", text: message)
            }
        }
        isLoading = false

        // 正在搜索的话，剩下的页得重新翻回来。这一页的搜索要的是**全量**
        // （见上面 onChangeCompat 那段）：列表是翻到哪算哪的，刷新只拿回第一页，
        // 搜索池就悄悄缩回去了 —— 搜索框里那个词没变，结果却少了几屏，
        // 看着像「搜不到了」。
        if isSearching {
            await loadRestForSearch()
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let result = try await loadPage(page)
            // 同一页可能被 onAppear 触发两次，按 bvid 去重
            let known = Set(items.map(\.bvid))
            items.append(contentsOf: result.items.filter { !known.contains($0.bvid) })
            hasMore = result.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }

    /// 把这一列里「还不知道要不要钱」的条目补上（`isPremium == nil`）。
    /// **现在是封存状态，没人调用** —— 见 body 里 `.task { await loadFirstPage() }`
    /// 下面那三行：收藏夹那个接口不报付费字段，补这一步只能一条一条问详情，
    /// 一页二十条就是二十个请求（实测十来秒），当时决定不做。
    ///
    /// 代码留着，等哪天有更省流的路子（或者 B 站那个接口开始报付费字段了）
    /// 直接接上就行：把那段注释里那行 `.task(id: items.count)` 加回来。
    ///
    /// 谁会是 nil：只有收藏夹那条路。补法是拿着 bvid 逐条问一次稿件详情，
    /// **一条问完再问下一条**，理由写在 `BiliClient.premiumFlag(bvid:)` 里
    /// （那儿的注释才是正文，这儿只说界面这一侧的两件事）：
    ///
    /// 一、**不占着列表**。二十条顺序问下来是十来秒，等齐了再显示，
    /// 用户会以为 App 卡死了 —— 所以是列表先出来，标记随后一条条冒出来，
    /// 问出一条就改一条。
    ///
    /// 二、**问不到的就一直不画**。`nil` 是「不知道」，不是「不要钱」，
    /// 别顺手把它当成免费（标记不猜）。
    ///
    /// 跟 iOS 那份是同一段（`VideoPickerView.resolvePremiums`）——
    /// 两个端的列表本来就是各写一份的，改一个记得改另一个。
    private func resolvePremiums() async {
        for bvid in items.filter({ $0.isPremium == nil }).map(\.bvid) {
            // 翻页 / 搜索会重开一轮（见 body 上那个 `.task(id:)`），
            // 被掐掉的这一轮就停在这儿，剩下的交给新一轮
            if Task.isCancelled { return }
            guard await queue.premiumFlag(bvid: bvid) == true else { continue }
            // 这中间列表可能已经被换掉了，按 bvid 找回来再改
            if let index = items.firstIndex(where: { $0.bvid == bvid }) {
                items[index].isPremium = true
            }
        }
    }
}

// MARK: - 一个条目

/// 收藏夹 / 合集里的一行：选择框 + 封面 + 标题 + UP 主 + 时长或 P 数。
private struct FavItemRow: View {

    enum CheckState {
        case none
        case partial
        case all
    }

    let item: FavItem
    let state: CheckState
    /// 这个条目勾了几 P。单 P 的和还没勾的都没有值
    let selectedPages: Int?
    let onTap: () -> Void

    /// 跟封面一样高，也就是视频行那一档（见 `ListRowMetrics.videoCoverHeight`；
    /// mac 上跟通用那档是同一个数，这个尺寸只在 iOS 上小一圈）
    private static let coverHeight: CGFloat = ListRowMetrics.videoCoverHeight

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                    .font(.title3)
                    // 挑不挑那颗圈/方块得跟封面**一条中线**：以前是拿一个写死的
                    // top padding 顶下来的，封面一改高矮就偏了。框成封面那么高、
                    // 自己在里头居中，封面多高都跟着走。
                    .frame(height: Self.coverHeight, alignment: .center)

                // 时长 / 总 P 数在封面右下角那个气泡里，跟添加任务那页一个规矩；
                // 要钱的视频在左下角多一枚粉色标记。
                //
                // 收藏夹那几页给不出这个信息（`isPremium` 是 nil = 不知道），
                // 补问那一步封存着（见 `resolvePremiums`），所以那几页不挂标记；
                // 合集 / 投稿 / 稍后 / 历史 / 追番分集那几条路接口自己就报了。
                // `== true` 就是在说「只认知道的，不知道的当没这回事」
                CoverThumbnail.videoRow(
                    url: item.coverURL,
                    badge: coverBadge,
                    isPremium: item.isPremium == true
                )

                // 三行字走共享的那一份（标题 / BV 号 / person + UP 主）——
                // 跟添加任务那页解析出来的视频行、跟 iOS 那边是同一套排法
                VideoRowText(
                    title: item.title,
                    ownerName: item.upperName,
                    identifier: item.bvid,
                    // 只有历史记录那几行有值，有了第三行就摆时间不摆 BV 号
                    playedAt: item.playedAt,
                    trailing: pageCountText
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 多 P 的视频在 **BV 号那一行的最右头**只报**已选几 P**：
    /// 总共有几 P 已经写在封面那个「共 12 P」的气泡里了，这儿再说一遍是重复
    /// （跟添加任务那页取的是同一套写法）。一个都没勾就空着 ——
    /// 「已选 0 P」是一句没有信息量的话。
    private var pageCountText: String? {
        guard item.isMultiPage, let selectedPages else { return nil }
        return "已选 \(selectedPages) P"
    }

    /// 封面右下角气泡里的字：单 P 是时长，多 P 是**总共几 P**。
    /// 多 P 的时长是整个合集的，没什么参考意义，不如报 P 数。
    ///
    /// 写成「共 12 P」而不是「12P」：后者会被当成 1080P 那种画质标。
    private var coverBadge: String? {
        item.isMultiPage ? "共 \(item.pageCount) P" : durationText
    }

    /// 分 P 的视频用方框，好跟单 P 的圆圈区分开。
    private var symbol: String {
        switch (item.isMultiPage, state) {
        case (false, .none): return "circle"
        case (false, .all): return "checkmark.circle.fill"
        case (false, .partial): return "minus.circle.fill"
        case (true, .none): return "square"
        case (true, .all): return "checkmark.square.fill"
        case (true, .partial): return "minus.square.fill"
        }
    }

    private var durationText: String {
        let minutes = item.duration / 60
        let seconds = item.duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
