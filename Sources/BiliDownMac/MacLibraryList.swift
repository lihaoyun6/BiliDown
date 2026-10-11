import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 收藏夹列表 / 合集列表。两页长得几乎一样，只是数据来源和每行的第二行字不同，
/// 所以合成一个视图，靠 `kind` 分。点进去之后都由 MacLibraryDetailView 接手。
struct MacLibraryList: View {

    enum Kind: Hashable {
        case favorites
        case collections
    }

    let kind: Kind

    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigator: MacNavigator

    /// 点开的那一个收藏夹 / 合集。nil 就是停在列表这一层。
    /// 见 `body` 上头那段：这一页的「进下一层」是自己拿状态摆的，不用 NavigationStack。
    ///
    /// 存在 `MacNavigator` 里而不是 @State —— 切栏目时这个视图会被整个重建，
    /// @State 留不住，人就被打回列表根上了。那边按 kind 分开存，
    /// 所以收藏和合集各记各的。
    private var opened: LibrarySource? {
        get { navigator.openedLibrary[kind] }
        nonmutating set { navigator.openedLibrary[kind] = newValue }
    }

    @State private var folders: [FavFolder] = []
    @State private var collections: [SubscribedCollection] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var hud: HUD?

    /// 那把锁的宽度得钉死。`lock.open` 比 `lock` 宽出一截，不框住的话
    /// 「公开」和「私密」会差出几个点，一列扫下来齐不齐一眼就看出来。
    private static let lockWidth: CGFloat = 15

    /// 行里两行字之间那道缝。跟**点开夹子之后那个视频列表**、跟添加任务那边
    /// 取的是同一个值（见 `ListRowMetrics`）—— 几页之间来回翻，行距一样才不跳。
    private static let textSpacing: CGFloat = ListRowMetrics.textSpacing

    /// 列表这一层和「点开的那个夹子」这一层，是自己用 `opened` 摆的，
    /// **没有 NavigationStack**。
    ///
    /// 原来这里是 `NavigationStack { ... NavigationLink ... }`，在 mac 上出了个
    /// 很烦人的毛病：点进某个夹子看到视频列表之后，再去点侧边栏别的栏目，
    /// 屏幕上一动不动 —— 栏目其实切过去了，但那个 NavigationStack 把它推进去的
    /// 那一页留住了，得按一下「返回」才露出新栏目的根页。给 detail 挂 `.id(section)`
    /// 想让 SwiftUI 重建整棵子树，不管用。
    ///
    /// 根子是：**那层容器管不到里面那层的路径**，换内容时也不会替你把它弹空。
    /// 那就别套了 —— 进下一层用一个可选项状态表示，「返回」按钮自己摆在
    /// 这一页的标题行里。这样可以确定：换栏目 = 状态归零 = 一定回到列表。
    var body: some View {
        Group {
            if let opened = opened {
                MacLibraryDetailView(source: opened)
                    .toolbar {
                        ToolbarItem(id: "library-back", placement: .navigation) {
                            Button {
                                self.opened = nil
                            } label: {
                                Label("返回", systemImage: "chevron.backward")
                            }
                            .help("返回收藏夹列表")
                        }
                    }
            } else {
                content
                    .navigationTitle(title)
                    .searchable(text: $query, prompt: kind == .favorites ? "搜索收藏夹" : "搜索合集")
                    .toolbar {
                        // 刷新摆在搜索框左边。mac 上 `.searchable` 那个框永远占着
                        // 顶栏最右一格，`.primaryAction` 的项就落在它左边紧挨着 ——
                        // 所以这颗按钮不用自己找位置，placement 写对就行。
                        //
                        // 为什么非要有它：这一页会变。用户在 B 站那边新建 / 删掉
                        // 一个收藏夹、订一个新合集，这页不重新拉就还摆着旧的。
                        // `.refreshable` 那套是给下拉手势的，mac 的 List 不认，
                        // 得有颗真按钮。
                        //
                        // id 见 MacDownloadsView 那段：切栏目时这棵子树会被重建，
                        // 不钉 id 的话新旧两项对不上号，边上会冒出个空的溢出箭头。
                        //
                        // 按钮本身（图标多大、转圈怎么进出的）在 MacRefreshButton 里，
                        // 跟详情页那颗是同一个 —— 顶栏那几个坑都写在那边。
                        ToolbarItem(id: "library-refresh", placement: .primaryAction) {
                            MacRefreshButton(isLoading: isLoading) {
                                Task { await loadFirstPage() }
                            }
                        }
                    }
                    .task {
                        await waitForCredential()
                        await loadFirstPage()
                    }
                    .refreshable { await loadFirstPage() }
            }
        }
        // 换栏目**不**清「点开的那一个」了 —— 去别处转一圈再回来该还站在原地，
        // 见 MacNavigator.openedLibrary。收藏和合集各记各的，也不会串。
        //
        // 换 kind 时重新拉一遍是给「SwiftUI 把同一个视图留在原地只换了 kind」兜底的：
        // 有 `.id(section)` 在，正常走的是重建那条路（`.task` 会自己跑）。
        .onChangeCompat(of: kind) { _ in
            Task { await loadFirstPage() }
        }
        .hud($hud)
    }

    private var title: String {
        kind == .favorites ? "收藏" : "合集"
    }

    // MARK: - 显示的那一份

    /// 开了「隐藏失效内容」就把失效的摘掉。
    /// 只摘**显示**这一层，底层 items 不动 —— 一摘到底的话，
    /// 这个开关一关就得重新联网拉一遍才能把条目找回来。
    private var visibleFolders: [FavFolder] {
        SearchFilter.match(folders, query: query) { [$0.title] }
    }

    private var visibleCollections: [SubscribedCollection] {
        let kept = settings.filterInvalidContent ? collections.filter(\.isAvailable) : collections
        // 搜 UP 主名也一并算上：经常是「想找某个人的合集」，
        // 光搜合集的标题未必想得起来叫什么
        return SearchFilter.match(kept, query: query) { [$0.title, $0.ownerName] }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        // 列表一直是同一个 List：正在读、读失败、空、有内容都在这一个里面切，
        // 只换行不换根视图，滚动位置就不会莫名其妙地被重置。
        //
        // 空态那一块**不摆在 List 里当行**了，改成浮在它上面（overlay）：
        // 当行摆的话它只能贴着列表的顶 —— 一整屏的空列表面前，那三行字缩在最上头，
        // 看着像「还没加载完」。浮一层，才落在正中间。
        // List 还是同一个，所以「换内容不重置滚动位置」那件事不受影响。
        List {
            if !isEmpty && !isVisibleEmpty {
                if kind == .favorites {
                    ForEach(visibleFolders) { folder in
                        Button {
                            opened = .folder(folder)
                        } label: {
                            // 上下各垫一点：mac 的 List 行是贴着的，
                            // 垫在 Button 里面，连点按范围一起长（见 `ListRowMetrics`）
                            folderRow(folder)
                                .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(visibleCollections) { collection in
                        Button {
                            opened = .collection(collection)
                        } label: {
                            // 同上：跟收藏夹那一列是同一个行距
                            collectionRow(collection)
                                .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // 比的是显示的那一份：过滤开着的时候，底层最后几条
                            // 可能是被藏起来的，等它们永远不会触发翻页
                            if collection.seasonID == visibleCollections.last?.seasonID {
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
        .overlay { placeholder }
    }

    /// 空 / 读失败 / 搜索没结果时浮在列表中间的那一块。
    /// 反过来就是：有内容可显示的时候它什么都不画。
    @ViewBuilder
    private var placeholder: some View {
        if isEmpty {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ListPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: kind == .favorites ? "读不到收藏夹" : "读不到合集",
                    message: errorMessage,
                    retry: { Task { await loadFirstPage() } }
                )
            } else {
                ListPlaceholder(
                    icon: kind == .favorites ? "star" : "rectangle.stack",
                    title: kind == .favorites ? "还没有收藏夹" : "还没有订阅合集",
                    message: kind == .favorites
                        ? "在 B 站建一个收藏夹，这里就能看到。"
                        : "在 B 站订阅一个合集，这里就能看到。"
                )
            }
        } else if isVisibleEmpty {
            ListPlaceholder(
                icon: "magnifyingglass",
                title: isSearching
                    ? (kind == .favorites ? "没有匹配的收藏夹" : "没有匹配的合集")
                    : "没有可显示的内容"
            )
        }
    }

    private var isEmpty: Bool {
        kind == .favorites ? folders.isEmpty : collections.isEmpty
    }

    private var isVisibleEmpty: Bool {
        kind == .favorites ? visibleFolders.isEmpty : visibleCollections.isEmpty
    }

    // MARK: - 行

    /// 收藏夹这一行跟合集那一行长得一样：封面 + 两行字 + 数量（在封面气泡里）。
    /// 之前用文件夹图标，行矮得跟谁都不齐，一列排下来密得发闷。
    /// 拿最新视频的封面当夹子封面，高度就统一了。
    private func folderRow(_ folder: FavFolder) -> some View {
        HStack(spacing: 12) {
            // 收藏夹统一走占位封面（不传 url，CoverThumbnail 会铺灰底加图标）。
            // 别想着去接口里翻一个封面回来，风控拦的就是那串请求。
            //
            // 里面有多少条就写在这张封面右下角的气泡上（原来在行尾）。
            CoverThumbnail(
                url: nil,
                placeholderSystemImage: "folder",
                badge: "\(folder.mediaCount)"
            )

            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(folder.title)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                // 合集这儿放的是 UP 主，收藏夹没这个信息，改放公开/私密，
                // 反正那一行空着也是空着
                HStack(spacing: 4) {
                    Image(systemName: folder.isPrivate ? "lock" : "lock.open")
                        .font(Typography.micro)
                        .frame(width: Self.lockWidth, alignment: .leading)
                    Text(folder.isPrivate ? "私密" : "公开")
                        .lineLimit(1)
                }
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }

            // 行尾那个数字搬进封面气泡了，这儿不用再撑着东西 ——
            // 标题自己会占满，留着这个 Spacer 只是白占一点宽度。
            Spacer(minLength: 0)
        }
    }

    private func collectionRow(_ item: SubscribedCollection) -> some View {
        HStack(spacing: 12) {
            // 同上：多少集写在封面气泡上（原来在行尾）。
            CoverThumbnail(url: item.coverURL, badge: "\(item.videoCount)")

            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(item.title)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !item.ownerName.isEmpty {
                        Image(systemName: "person")
                            .font(Typography.micro)
                        Text(item.ownerName)
                            .lineLimit(1)
                    }
                }
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 加载

    /// 等队列的 client 拿到凭证再发第一个请求。
    ///
    /// 冷启动那一下有个很窄的窗口：侧边栏的「收藏」在登录态一恢复就出现了，
    /// 而凭证是 `MacRootView` 那段任务里**后面**一行才喂进 client 的。
    /// 落在窗口里的请求会被当成未登录（`notLoggedIn`）—— 界面上就是
    /// 「读不到收藏夹」闪一下，紧接着又自己好了（那次 `.task` 重跑时凭证已经在了）。
    ///
    /// 真没登录的话这页压根进不来，所以这个循环不会白等，也不会卡住：
    /// 到点就走，该报错照样报错。
    private func waitForCredential() async {
        var waited = 0
        while !queue.hasCredential && waited < 60 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    /// 重新拉第一页。
    ///
    /// 拉之前本来就有东西的话，失败得靠 HUD 出声。中间那块 errorMessage 只在
    /// 列表空着的时候才画得出来，列表里还摆着旧数据时它什么都不显示 ——
    /// 点一下刷新，转一圈，然后什么都没变，看着就像这颗按钮是坏的。
    private func loadFirstPage() async {
        let hadContent = !isEmpty

        // 顶栏那颗刷新按钮拿这个当「正在读」的灯：转圈、置灰、挡掉翻页，
        // 全靠它。所以重新拉之前得自己举起来 —— 它原来的初值 true 只在
        // 第一次进来时管用，之后每一趟都得自己开关。
        isLoading = true
        errorMessage = nil
        page = 1
        hasMore = true
        do {
            switch kind {
            case .favorites:
                // 收藏夹不多，一次就全拉回来了
                folders = try await queue.favoriteFolders()
            case .collections:
                let result = try await queue.subscribedCollections(page: 1)
                collections = result.items
                hasMore = result.hasMore
                page = 2
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            if hadContent {
                hud = HUD(icon: "exclamationmark.triangle.fill", text: message)
            }
        }
        isLoading = false
    }

    private func loadMore() async {
        guard kind == .collections, hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let result = try await queue.subscribedCollections(page: page)
            let known = Set(collections.map(\.seasonID))
            collections.append(contentsOf: result.items.filter { !known.contains($0.seasonID) })
            hasMore = result.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }
}
