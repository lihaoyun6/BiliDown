import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 一个收藏夹 / 一个合集里面的视频列表：勾几个，然后入队。
/// 流程跟 iOS 版一模一样（分 P 的弹选择器、全选是真的「整个夹子」、
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
    @State private var page = 1
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
            .toolbar {
                // id 见 MacDownloadsView 里那段：不写 id，重建时会对不上号，
                // 加号旁边会多出一个空的溢出箭头。
                ToolbarItem(id: "download-selection", placement: .primaryAction) {
                    downloadMenu
                }

                // 刷新。**声明在下载菜单后面**，落点才是贴着搜索框那一边：
                // 同一个 placement 的项按声明顺序从左往右排，而搜索框永远
                // 占着顶栏最右一格 —— 所以它排在下载菜单右边、搜索框左边，
                // 跟收藏 / 合集列表页那颗在同一个位置上。
                //
                // 按钮本身在 MacRefreshButton 里，跟列表页那颗是同一个。
                ToolbarItem(id: "library-detail-refresh", placement: .primaryAction) {
                    MacRefreshButton(isLoading: isLoading) {
                        Task { await loadFirstPage() }
                    }
                }
            }
            .task { await loadFirstPage() }
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
        .disabled(selectedCount == 0)
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
                SelectAllRow(
                    state: allState,
                    trailingText: selectedCountText,
                    symbolFont: .title3
                ) {
                    toggleAll()
                }
                .padding(.vertical, ListRowMetrics.macRowVerticalPadding)

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

    /// 全都要的时候得报整个收藏夹的数量，不是已经拉到的那些。
    /// 搜索状态下另说：那时候「全都要」就是「搜出来的这些」。
    private var selectedCount: Int {
        let total = isSearching ? visibleItems.count : source.videoCount
        return selectAllMode ? max(total - excluded.count, 0) : selection.count
    }

    private var downloadButtonTitle: String {
        selectedCount == 0 ? "下载" : "下载 \(selectedCount) 个"
    }

    /// 全选那一行右端那句话。一个没勾就空着 ——
    /// 「已选 0 个」是一句没有信息量的话，不如让那一格干净着。
    private var selectedCountText: String? {
        selectedCount == 0 ? nil : "已选 \(selectedCount) 个"
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
        } else {
            selectAllMode = true
            selection.removeAll()
            excluded.removeAll()
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

    /// 收藏夹和合集各走各的接口，出来的东西归一成同一种条目
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
                    pageCount: $0.pageCount
                )
            }
            return (items, result.hasMore)
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

                // 时长 / 总 P 数在封面右下角那个气泡里，跟添加任务那页一个规矩
                CoverThumbnail.videoRow(url: item.coverURL, badge: coverBadge)

                // 三行字走共享的那一份（标题 / BV 号 / person + UP 主）——
                // 跟添加任务那页解析出来的视频行、跟 iOS 那边是同一套排法
                VideoRowText(
                    title: item.title,
                    identifier: item.bvid,
                    trailing: pageCountText,
                    ownerName: item.upperName
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
