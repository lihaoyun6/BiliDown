import SwiftUI
import UIKit
import BiliCore
import BiliKit
import BiliUI

/// 「挑视频」那一页：一条条勾，勾完入队。
///
/// 四个来源（收藏夹 / 订阅合集 / 一季番剧 / 稍后再看 / 历史记录）看上去是四件事，
/// 但进到这一层全都一样 —— 一个视频列表 + 勾选 + 入队，区别只有标题、空态文案
/// 和从哪个接口拉。所以只有这一个页面，来源由 `LibrarySource` 带进来。
///
/// mac 那边是同名的一份（MacLibraryDetailView），改动记得两边一起。
struct VideoPickerView: View {

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
    @State private var showingKindPicker = false
    @State private var query = ""
    @State private var hud: HUD?

    var body: some View {
        content
            // 收藏夹名 / 合集名放到列表顶上那行小字里，标题栏统一叫「选择视频」，
            // 标题摆在顶栏中间（.inline）—— 跟原生那套一致，往上推也不会有大标题。
            // 追番那四个没有上一层列表，名字就是这一页的，标题栏写自己的名字。
            .navigationTitle(source.isStandalone ? source.title : "选择视频")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索视频"
            )
            // 搜索得搜全量：列表是翻到哪算哪的（一页 20 条），
            // 只筛已经拉回来的那几页等于没搜 —— 一千条的夹子里搜个标题，
            // 结果全看滚到哪儿了，那这个搜索框还不如没有。
            // 所以一开始打字就把剩下的页全翻回来。
            .onChangeCompat(of: query) { newValue in
                guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { await loadRestForSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(downloadButtonTitle) { showingKindPicker = true }
                        .disabled(selectedCount == 0 || isCountingAll)
                }
            }
            .task { await loadFirstPage() }
            .refreshable { await loadFirstPage() }
            // 点下载之后先问下什么，再入队
            .confirmationDialog("下载内容", isPresented: $showingKindPicker, titleVisibility: .visible) {
                ForEach(DownloadKind.allCases) { kind in
                    Button(kind.displayName) { download(kind: kind) }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $pagePickerItem) { item in
                PagePickerSheet(target: ParsedTarget(ref: .bvid(item.bvid)), confirmVerb: "选择") { pages in
                    selection[item.bvid] = Set(pages)
                }
            }
            .hud($hud)
    }

    /// 界面上真正要显示的那些条目。开了「过滤无效内容」就把失效的摘掉。
    ///
    /// 只在**用的时候**摘，不去动底层那个 items ——
    /// 一摘到底的话，这个开关一关就得重新联网拉一遍才能把条目找回来。
    /// 顺带一提，全选和入队也走这个，不然勾了半天把下不了的也算进去了。
    private var visibleItems: [FavItem] {
        let kept = settings.filterInvalidContent ? items.filter(\.isAvailable) : items
        return SearchFilter.match(kept, query: query) { [$0.title, $0.upperName] }
    }

    /// 搜索框里有没有字
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var content: some View {
        // 和收藏夹列表一样：一个 List 从头用到尾，中途只换行不换根视图
        List {
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
                // 有东西，只是这一下没筛出来（搜的词没对上，
                // 或者全被「过滤无效内容」藏了）
                ListPlaceholder(
                    icon: "magnifyingglass",
                    title: isSearching ? "没有匹配的视频" : source.emptyTitle
                )
            } else {
                // 全选和条目直接摆进 List，**别**再套一层 Section。
                //
                // 套 Section 会在第一组的顶上多出一块空白：SwiftUI 的 List 底下是
                // UITableView，它会按 sectionHeaderTopPadding 给每个 section 的表头
                // 上面留一段（分组样式默认 22pt 左右），第一组也不例外 —— 于是
                // 「列表离顶栏空着老大一块」。没有显式 Section 的时候不吃这一段，
                // 所以外面收藏夹、合集那两个列表（行都是直接摆在 List 里的）一直没事。
                //
                // 不套 Section 也不影响长相：insetGrouped 会把 List 顶层的行
                // 归成一个隐式分组，照样是一张卡片，「全选」和下面的条目还是同一组。
                //
                // 收藏夹名 / 合集名挂在「全选」那行的右端，省掉一整行表头。
                // 自己一页的那几个名字已经写在标题栏上了，这一格改成报已选数量。
                // 选择框字号跟下面 FavItemRow 的对齐（那边是 .title3）。
                //
                // 稍后再看有这一行（一次给全，数目数得出来），历史记录没有
                // （游标翻页翻不到底）—— 谁摆谁不摆归 `supportsSelectAll` 管。
                if source.supportsSelectAll {
                    SelectAllRow(
                        state: allState,
                        trailingText: source.isStandalone ? selectedCountText : source.title,
                        symbolFont: .title3
                    ) {
                        toggleAll()
                    }
                }

                ForEach(visibleItems) { item in
                    FavItemRow(
                        item: item,
                        state: checkState(for: item),
                        selectedPages: selectedPageCount(for: item)
                    ) {
                        tap(item)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            copyBV(item.bvid)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .tint(.blue)
                        .accessibilityLabel("复制 BV 号")

                        // BV 号和链接都有人要：BV 号是拿去做别的工具的入参，
                        // 链接是发给别人的。所以两个都留着，各一个颜色 ——
                        // 划开一眼能认出哪个是哪个。
                        Button {
                            copyLink(item.bvid)
                        } label: {
                            Image(systemName: "link")
                        }
                        .tint(.green)
                        .accessibilityLabel("复制视频链接")
                    }
                    .onAppear {
                        // 拿显示的那一份的末尾来比：过滤开着的时候，
                        // 底层最后几条可能是被藏起来的，等它们永远不会触发翻页
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
        // 这一行是在治「列表离顶栏空着一大块」。
        //
        // 现象：搜索框和顶栏都好好的，但列表内容整体往下缩了一大段，
        // 而且往上推一点点，顶栏就提前切进「被内容侵入」的样子 —— 说明滚动视图
        // 自己认为内容已经压上去了。那是滚动视图给内容留的额外上边距（content margin）
        // 比真正露在外面的导航栏那一层还大，多出来的那截就是白的地方。
        //
        // 这个页面是**推入**的，而且标题是 .inline，跟外面那两个根列表不是一种情况：
        // 外面的是大标题，那一段额外边距正好被大标题本身占着，所以看不出来。
        //
        // 把它清零。导航栏自己的安全区不归它管，不受影响 ——
        // 清零之后「全选」正好接在搜索框底下。
        .contentMargins(.top, 0, for: .scrollContent)
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
    /// 稍后再看走到这儿也是准的：它没有下一页，`hasMore` 一直是 false，
    /// 走的就是「数手里这一份」那一路。历史记录没有全选那一行，走不到这儿。
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

    /// 「全选」那一行右端那句话，给**自己一页**的那几个来源用
    /// （收藏夹 / 合集那一格放的是夹子名，见上面 SelectAllRow 那段）。
    /// 一个都没勾就空着 —— 「已选 0 个」是一句没有信息量的话。
    private var selectedCountText: String? {
        selectedCount == 0 ? nil : "已选 \(selectedCount) 个"
    }

    // MARK: - 勾选

    /// 分 P 视频用方框，勾满打钩、只勾一部分就是一横。
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
        // 本来就要翻，早翻还能让按钮上的数字一开始就是准的 ——
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
        UIPasteboard.general.string = bvid
        hud = HUD(icon: "doc.on.doc.fill", text: "已复制 \(bvid)")
    }

    /// 复制的是网页版地址（`https://www.bilibili.com/video/BV…`），不是 BV 号。
    /// 提示里不摆地址了 —— 那条 URL 比整块 HUD 还长，摆出来也只有截断的下场，
    /// 反正复制到的东西用户是知道的。
    private func copyLink(_ bvid: String) {
        UIPasteboard.general.string = VideoRef.bvid(bvid).webURL
        hud = HUD(icon: "link", text: "已复制视频链接")
    }

    // MARK: - 入队

    private func download(kind: DownloadKind) {
        Task { await performDownload(kind: kind) }
    }

    private func performDownload(kind: DownloadKind) async {
        // 全都要的话得先把整个收藏夹翻完，不然只加到滚过的那几条。
        // 搜索状态下不用翻：打字那会儿已经把全量拉回来了，
        // visibleItems 就是「全量里筛出来的那些」，「全都要」自然就是这些。
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
                    pageCount: $0.pageCount
                )
            }
            return (items, result.hasMore)

        case .season(let season):
            // 一季的分集一次全给（几百集也是一次），没有下一页
            let episodes = try await queue.seasonEpisodes(seasonID: season.seasonID)
            return (episodes, false)

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
    /// 循环那套直接复用 loadAllItems，外面只多一个转圈。
    private func loadRestForSearch() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        _ = await loadAllItems()
    }

    private func loadFirstPage() async {
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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
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

// MARK: - 收藏条目

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

    /// 跟封面一样高、跟别的视频行同一档（见 `ListRowMetrics.videoCoverHeight`）。
    /// 右边那三行字合成一块，整块在封面里居中（`VideoRowText` 管）。
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
                // 跟添加任务那页解析出来的视频行、跟 mac 那边是同一套排法
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
