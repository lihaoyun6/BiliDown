import SwiftUI
import UIKit
import BiliCore
import BiliKit
import BiliUI

/// 只有登录后才出现的第三个 Tab：按收藏夹分组，进去挑视频批量下载。
struct FavoritesView: View {

    /// 那把锁的宽度得钉死。`lock.open` 比 `lock` 宽出一截
    /// （caption2 下量出来是 15pt 对 11pt），不框住的话「公开」和「私密」
    /// 会差出四个点，一列扫下来齐不齐一眼就看出来。
    /// 左对齐而不是居中：这样不管哪把锁，左边缘都在同一个位置，
    /// 图标那一列才是齐的。
    private static let lockWidth: CGFloat = 15

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var queue: DownloadQueue

    @State private var folders: [FavFolder] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("收藏")
                // .always：搜索框常驻在标题底下，不跟着列表滚走 ——
                // 它是这一页的入口，藏起来等于没有。
                // 用系统这一个是图它能跟导航栏联动：往上推列表，大标题会缩成
                // 小版本，搜索框也跟着走那套动画 —— 自己拿 VStack 摆一个搜索框
                // 就把 List 从导航栏根视图的位置上挤下来了，大标题再也不缩。
                // 宽度上跟列表卡片差的那几个点，认了。
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索收藏夹"
                )
                .task { await load() }
                .refreshable { await load() }
        }
    }

    /// 收藏夹不多，一次就全拉回来了，所以这儿就地筛选即可
    private var visibleFolders: [FavFolder] {
        SearchFilter.match(folders, query: query) { [$0.title] }
    }

    private var content: some View {
        // 列表一直是同一个 List：正在读、读失败、空、有内容都在这一个里面切，
        // 只有行在变，滚动视图不重建，就不会在底部标签栏那儿闪。
        List {
            if folders.isEmpty {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ListPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: "读不到收藏夹",
                        message: errorMessage,
                        retry: { Task { await load() } }
                    )
                } else {
                    ListPlaceholder(
                        icon: "star",
                        title: "还没有收藏夹",
                        message: "在 B 站建一个收藏夹，这里就能看到。"
                    )
                }
            } else if visibleFolders.isEmpty {
                ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的收藏夹")
            } else {
                ForEach(visibleFolders) { folder in
                    NavigationLink {
                        FavFolderView(source: .folder(folder))
                    } label: {
                        row(for: folder)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
    }

    /// 收藏夹这一行跟合集那一行、以及点进去之后的视频行长得一样：
    /// 封面 + 两行字 + 数量。之前用文件夹图标，行矮得跟谁都不齐，
    /// 一列排下来密得发闷。拿最新视频的封面当夹子封面，高度就统一了。
    private func row(for folder: FavFolder) -> some View {
        HStack(spacing: 12) {
            // 收藏夹统一走占位封面（不传 url，CoverThumbnail 会铺灰底加图标）。
            // 别想着去接口里翻一个封面回来，风控拦的就是那串请求。
            CoverThumbnail(url: nil, placeholderSystemImage: "folder")

            // 行距跟点进去之后的视频列表同一个值（见 `ListRowMetrics`）
            VStack(alignment: .leading, spacing: ListRowMetrics.textSpacing) {
                Text(folder.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                // 合集这儿放的是 UP 主，收藏夹没这个信息，改放公开/私密，
                // 反正那一行空着也是空着
                HStack(spacing: 4) {
                    Image(systemName: folder.isPrivate ? "lock" : "lock.open")
                        .font(.caption2)
                        .frame(width: Self.lockWidth, alignment: .leading)
                    Text(folder.isPrivate ? "私密" : "公开")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(folder.mediaCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            folders = try await queue.favoriteFolders()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 单个收藏夹 / 单个合集

// LibrarySource 搬到 BiliUI 去了（两端共用）。

struct FavFolderView: View {

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
    @State private var showingKindPicker = false
    @State private var query = ""
    @State private var hud: HUD?

    var body: some View {
        content
            // 收藏夹名 / 合集名放到列表顶上那行小字里，标题栏统一叫「选择视频」，
            // 标题摆在顶栏中间（.inline）—— 跟原生那套一致，往上推也不会有大标题
            .navigationTitle("选择视频")
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
                        .disabled(selectedCount == 0)
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
                // 选择框字号跟下面 FavItemRow 的对齐（那边是 .title3）。
                SelectAllRow(state: allState, trailingText: source.title, symbolFont: .title3) {
                    toggleAll()
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

    /// 全都要的时候得报整个收藏夹的数量，不是已经拉到的那些。
    /// 搜索状态下另说：那时候「全都要」就是「搜出来的这些」，
    /// 数量直接数眼前这一份（搜之前已经把全量翻回来了，数是准的）。
    private var selectedCount: Int {
        let total = isSearching ? visibleItems.count : source.videoCount
        return selectAllMode ? max(total - excluded.count, 0) : selection.count
    }

    private var downloadButtonTitle: String {
        selectedCount == 0 ? "下载" : "下载 \(selectedCount) 个"
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

// MARK: - 我订阅的合集

/// 登录后才出现的第四个 Tab：收藏页里「合集」那一栏。
/// 点进去之后和收藏夹一样挑视频下载。
struct CollectionsView: View {

    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var settings: AppSettings

    @State private var items: [SubscribedCollection] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("合集")
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索合集"
                )
                // 合集列表也是一页 20 条，搜索得搜全量（理由同 FavFolderView）
                .onChangeCompat(of: query) { newValue in
                    guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    Task { await loadRestForSearch() }
                }
                .task { await loadFirstPage() }
                .refreshable { await loadFirstPage() }
        }
    }

    /// 显示的那些。开了「过滤无效内容」就把「该合集已失效」的藏掉。
    /// 同上，只摘显示这一层，底层数据留着。
    private var visibleItems: [SubscribedCollection] {
        let kept = settings.filterInvalidContent ? items.filter(\.isAvailable) : items
        // 搜 UP 主名也一并算上：经常是「想找某个人的合集」，
        // 光搜合集的标题未必想得起来叫什么
        return SearchFilter.match(kept, query: query) { [$0.title, $0.ownerName] }
    }

    private var content: some View {
        List {
            if items.isEmpty {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ListPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: "读不到合集",
                        message: errorMessage,
                        retry: { Task { await loadFirstPage() } }
                    )
                } else {
                    ListPlaceholder(
                        icon: "rectangle.stack",
                        title: "还没有订阅合集",
                        message: "在 B 站订阅一个合集，这里就能看到。"
                    )
                }
            } else if visibleItems.isEmpty {
                ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的合集")
            } else {
                ForEach(visibleItems) { item in
                    NavigationLink {
                        FavFolderView(source: .collection(item))
                    } label: {
                        row(for: item)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .onAppear {
                        // 比的是显示的那一份（理由同 FavFolderView）
                        if item.seasonID == visibleItems.last?.seasonID {
                            Task { await loadMore() }
                        }
                    }
                }

                if isLoadingMore {
                    LoadMoreSpinner()
                }
            }
        }
    }

    private func row(for item: SubscribedCollection) -> some View {
        HStack(spacing: 12) {
            CoverThumbnail(url: item.coverURL)

            // 行距跟点进去之后的视频列表同一个值（见 `ListRowMetrics`）
            VStack(alignment: .leading, spacing: ListRowMetrics.textSpacing) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !item.ownerName.isEmpty {
                        Image(systemName: "person")
                            .font(.caption2)
                        Text(item.ownerName)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(item.videoCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func loadFirstPage() async {
        errorMessage = nil
        page = 1
        hasMore = true
        do {
            let result = try await queue.subscribedCollections(page: 1)
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
            let result = try await queue.subscribedCollections(page: page)
            let known = Set(items.map(\.seasonID))
            items.append(contentsOf: result.items.filter { !known.contains($0.seasonID) })
            hasMore = result.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }

    /// 搜索要拿全量：现在手上只有头一页 20 条，
    /// 不把剩下的翻完，搜出来的「没有匹配的合集」是假的。
    /// 就沿着 loadMore 一页页翻到没有为止，翻的过程中底下那个转圈照转。
    private func loadRestForSearch() async {
        while hasMore {
            let before = items.count
            await loadMore()
            // 没往前推进就说明到底了或者出错了，别在这儿空转
            if items.count == before { break }
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
