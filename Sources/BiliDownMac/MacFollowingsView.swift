import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 侧边栏「关注」那一栏：先看分组，点进一组是这一组里的人，再点进去是 TA 的投稿。
///
/// 跟 iOS 的「我的关注」是同一件事、同一套接口（`FollowGroupsView`）：分组由
/// `queue.followGroups()` 拉，组里的人由 `queue.followGroupMembers(tagID:)` 拉，
/// 最后那一层挑视频直接复用 `MacLibraryDetailView(source: .uploads(…))` ——
/// 连「新的在上、老的在下」都是投稿接口自己带的（那儿写的是 `order=pubdate`）。
///
/// 三层摆在**同一个视图**里，靠 `MacNavigator` 上那两个可选项状态切，**不套
/// `NavigationStack`**：理由跟 `MacLibraryList` 那段一模一样 —— 那层容器管不到
/// 里面那层的路径，换栏目时不会替你把它弹空，于是「点了侧边栏却一动不动」。
/// 所以「返回」也是自己摆在顶栏里的。
///
/// 状态（点开的是哪一组、哪个人）存在 `MacNavigator` 上，不在这儿的 @State 里 ——
/// 切栏目时这一页会被整个重建（detail 挂着 `.id(section)`），@State 留不住。
struct MacFollowingsView: View {

    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var navigator: MacNavigator

    /// 点开的是哪一层的人：「全部关注」或者某一组。nil 就是停在分组那一层。
    private var openedScope: FollowScope? { navigator.openedFollowScope }
    /// 点开的是哪个人。有值就说明已经进到「TA 的投稿」那一层了。
    private var openedUser: FollowedUser? { navigator.openedFollowUser }

    @State private var groups: [FollowGroup] = []
    /// 「全部关注」有多少人。拿不到就不报这个数（见 `loadGroups`）——
    /// 那一行照样能点，进去有它自己的报错。
    @State private var allCount: Int?
    @State private var users: [FollowedUser] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hud: HUD?
    /// 顶上那个搜索框。层级之间共用这一个（`.searchable` 在同一页里换不了
    /// 第二个框），换层的时候清掉（见 `goBack` 和那两处点开的动作）。
    @State private var query = ""

    /// 行里两行字之间那道缝。跟收藏夹那几页取的是同一个值（见 `ListRowMetrics`）——
    /// 几页之间来回翻，行距一样才不跳。
    private static let textSpacing: CGFloat = ListRowMetrics.textSpacing

    /// 行尾那个折角往里收多少（跟 `MacLibraryList` 同一个数、同一个道理）。
    private static let disclosureTrailingInset: CGFloat = 10

    /// 头像那一格。比封面（`ListRowMetrics.coverHeight`，56）收一点：
    /// 圆的看着比方片子占地方，一样高就显得比别页的行大一号。
    /// 也比 iOS 那份（48）小一圈 —— mac 的行里字小一号，头像跟着收，
    /// 侧边栏左下角那个账号头像也是这个比例（36 对 iOS 的 40）。
    private static let avatarSize: CGFloat = 44

    var body: some View {
        Group {
            if let user = openedUser {
                // 挑视频那一层整个交出去，不再自己画 —— 它跟收藏夹 / 合集
                // 点进去是同一页（`LibrarySource.uploads`）。
                MacLibraryDetailView(source: .uploads(mid: user.mid, ownerName: user.name))
            } else {
                content
                    // 最上面那层跟侧边栏那一行同名（`MacRootView.Section.title`），
                    // 点进某一组 / 全部关注之后换成那一层的名字 —— 那已经是
                    // 下一层了，「我的关注」这个栏名管不到它头上。
                    .navigationTitle(openedScope?.title ?? MacRootView.Section.followings.title)
                    // 搜索框在这一层换不了第二个，所以两种措辞由当前停在哪一层决定：
                    // 最上面筛的是分组名，进去之后筛的是人名和简介。
                    .searchable(text: $query, prompt: openedScope == nil ? "搜索分组" : "搜索用户")
                    .onChangeCompat(of: query) { newValue in
                        guard openedScope != nil else { return }
                        guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        Task { await loadRestForSearch() }
                    }
                    .task { await loadFirstPage() }
                    .refreshable { await loadFirstPage() }
            }
        }
        // 顶栏挂在 `Group` 这一层，不写进里面那个 if/else —— 理由见
        // `MacLibraryList.toolbarContent` 上头那一大段（项挂在声明它的视图身上，
        // 那个视图被换掉的时候 AppKit 会把项弄丢）。
        .toolbar { toolbarContent }
        .hud($hud)
    }

    /// 顶栏：还没点进哪一组时是右上角那颗刷新，点进去之后换成左上角的「返回」。
    ///
    /// 跟 `MacLibraryList` 一样是**一整组、不钉 id**：`ToolbarItem(id:)` 那套是给
    /// 可自定义工具栏用的，钉了反而会跟视图重建撞上，把整项弄丢（就是那个
    ///「切栏目之后按钮没了」的老毛病）。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if openedScope != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Label("返回", systemImage: "chevron.backward")
                }
                .help(openedUser == nil ? "返回关注分组" : "返回这一组")
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                MacRefreshButton(isLoading: isLoading) {
                    Task { await loadFirstPage() }
                }
            }
        }
    }

    /// 退回上一层：在「TA 的投稿」里就退回这一层的人，已经在人这一层了就退回分组。
    ///
    /// 退回去顺手把搜索框清掉：上一层的搜索结果摆在下一层的列表前面没有意义，
    /// 而且框里的字留着、列表却是另一批东西，看着像筛错了。
    private func goBack() {
        query = ""
        if navigator.openedFollowUser != nil {
            navigator.openedFollowUser = nil
        } else {
            navigator.openedFollowScope = nil
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        // 列表一直是同一个 List：正在读、读失败、空、有内容都在这一个里面切，
        // 只换行不换根视图，滚动位置就不会莫名其妙地被重置。
        // 空态那一块浮在它上面（overlay），不摆进 List 当行 —— 当行只能贴着顶，
        // 一整屏的空列表面前那几行字缩在最上头，看着像「还没加载完」（同 MacLibraryList）。
        List {
            if openedScope != nil {
                if !visibleUsers.isEmpty {
                    ForEach(visibleUsers) { user in
                        Button {
                            navigator.openedFollowUser = user
                        } label: {
                            userRow(user)
                                .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // 比的是**显示的那一份**的末尾（理由同 VideoPickerView）：
                            // 拿底层那个 `users` 的末尾不行 —— 搜索时最后拉到的那个人
                            // 可能正好被筛掉了，那就没有任何一行能跟它相等。
                            if user.mid == visibleUsers.last?.mid {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if isLoadingMore {
                        LoadMoreSpinner()
                    }
                }
            } else if !visibleGroups.isEmpty {
                // 搜索的时候它让位：它不是搜出来的东西（同 iOS 那份）。
                if !isSearching {
                    Button {
                        open(.all)
                    } label: {
                        allRow
                            .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(visibleGroups) { group in
                    Button {
                        open(.group(group))
                    } label: {
                        groupRow(group)
                            .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay { placeholder }
    }

    /// 点开一层人。「全部关注」和分组走的是同一个动作，只是 scope 不一样。
    ///
    /// 先把上一层的人清掉再拉：不清的话，切过去的那一帧摆的还是上一组的人，
    /// 标题却已经是新的了。搜索框也一并清掉（理由见 `goBack`）。
    private func open(_ scope: FollowScope) {
        query = ""
        navigator.openedFollowScope = scope
        users = []
        Task { await loadUsers(of: scope, reset: true) }
    }

    /// 顶上那一行「全部关注」。形状跟分组那些行**一模一样** —— 同样高的占位封面、
    /// 同样两行字的位置、行尾同样一个折角，一列扫下来不觉得它不是一路东西。
    /// 封面上那个气泡里是总人数（跟分组那一行的气泡报的是组里的人数一个道理），
    /// 人数拿不到就空着。
    private var allRow: some View {
        HStack(spacing: 12) {
            CoverThumbnail(
                url: nil,
                placeholderSystemImage: "person.3",
                badge: allCount.map(String.init)
            )

            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(FollowScope.all.title)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Text(" ")
                    .font(Typography.caption)
            }

            Spacer(minLength: 8)

            disclosure
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 分组一次全拉回来了，就地筛（跟收藏夹那页一样）。
    private var visibleGroups: [FollowGroup] {
        SearchFilter.match(groups, query: query) { [$0.name] }
    }

    /// 人名和简介都搜 —— 简介里常写着「这是小号」「停更了」这类只有那儿才有的字。
    private var visibleUsers: [FollowedUser] {
        SearchFilter.match(users, query: query) { [$0.name, $0.sign] }
    }

    /// 正在读 / 读失败 / 空 时浮在列表中间的那一块。分两层各说各的。
    @ViewBuilder
    private var placeholder: some View {
        if openedScope == nil {
            if groups.isEmpty {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ListPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: "读不到关注分组",
                        message: errorMessage,
                        retry: { Task { await loadFirstPage() } }
                    )
                } else {
                    ListPlaceholder(
                        icon: "person.2",
                        title: "还没有关注分组",
                        message: "在 B 站把关注的人分个组，这里就能看到。"
                    )
                }
            } else if visibleGroups.isEmpty {
                // 分组本身是有的，只是这一个关键词一个都没匹配上。
                ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的分组")
            }
        } else if users.isEmpty {
            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ListPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: errorTitle,
                    message: errorMessage,
                    retry: { Task { await loadFirstPage() } }
                )
            } else {
                ListPlaceholder(icon: "person.2", title: emptyTitle)
            }
        } else if visibleUsers.isEmpty {
            ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的用户")
        }
    }

    /// 空态 / 读失败那两句话。两种 scope 说的是同一件事，只是措辞不同 ——
    /// 「这个分组」摆在「全部关注」上就不对了。
    private var emptyTitle: String {
        openedScope == .all ? "还没有关注的人" : "这个分组里还没有人"
    }

    private var errorTitle: String {
        openedScope == .all ? "读不到关注列表" : "读不到这个分组"
    }

    // MARK: - 行

    /// 一行分组：占位封面 + 组名。
    ///
    /// 封面那块是假的（分组没有封面可拿），但**尺寸是真的** —— 走
    /// `CoverThumbnail` 的占位那一档，行高就跟收藏夹那几页对得上，来回翻不跳。
    /// 收藏夹 / 合集也是这么办的（那边占位图标是文件夹，多少条写在封面气泡上，
    /// 这儿也一样，气泡里是这一组有多少人）。
    ///
    /// 名字底下留一行空的：不占着位置的话，这一页的行会比别处矮一截，
    /// 两行字的块也不是居中在封面里的（同 `MacLibraryList.seasonRow` 里那句）。
    private func groupRow(_ group: FollowGroup) -> some View {
        HStack(spacing: 12) {
            CoverThumbnail(
                url: nil,
                placeholderSystemImage: "person.2",
                badge: "\(group.count)"
            )

            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(group.name)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Text(" ")
                    .font(Typography.caption)
            }

            Spacer(minLength: 8)

            disclosure
        }
    }

    /// 一行一个人：圆形头像 + 昵称 + 个人简介。
    ///
    /// 简介那一行走 `signText`：没写简介的人显示的是一句占位话（见 `FollowedUser`），
    /// 不留空 —— 空着那一行就塌下去，这些行会比别人矮一截。跟 iOS 那份读的是
    /// 同一个属性，不会一边改了另一边还空着。头像走共享的那一个（`AvatarView`，
    /// 两端的关注列表和 iOS 的账号那一行用的是同一份）。
    private func userRow(_ user: FollowedUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: user.avatarURL, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: Self.textSpacing) {
                Text(user.name)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Text(user.signText)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            disclosure
        }
    }

    /// 行尾那个「进下一级」的折角。收藏 / 合集那几页是同一个记号，
    /// 样式和往左收多少都跟它们对齐（理由见 `MacLibraryList.disclosure`）。
    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.trailing, Self.disclosureTrailingInset)
    }

    // MARK: - 加载

    /// 等队列的 client 拿到凭证再发第一个请求（理由见 `MacLibraryList` 里同名那个）。
    private func waitForCredential() async {
        var waited = 0
        while !queue.hasCredential && waited < 60 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    /// 按**当前停在哪一层**重新拉第一页。顶栏那颗刷新和 `.task` 都走它。
    ///
    /// 停在「TA 的投稿」那一层时什么都不做 —— 那一层是 `MacLibraryDetailView`，
    /// 它自己会拉。
    private func loadFirstPage() async {
        await waitForCredential()

        if let scope = openedScope {
            guard openedUser == nil else { return }
            await loadUsers(of: scope, reset: true)
        } else {
            await loadGroups()
        }
    }

    private func loadGroups() async {
        let hadContent = !groups.isEmpty
        isLoading = true
        errorMessage = nil
        // 分组和「全部关注」的人数**并着发**（跟 iOS 那边同一套）：
        // 那一行的人数不该让整页多等一个来回；这笔失败了就 `try?` 收成 nil 不报数，
        // 不为一个装饰性的数字把整页打成「读不到关注分组」。
        async let allTask = queue.followedUsers(page: 1)
        do {
            groups = try await queue.followGroups()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            // 列表里还摆着旧数据的时候，中间那块 errorMessage 画不出来 ——
            // 点一下刷新、转一圈、什么都没变，看着就像这颗按钮是坏的。
            if hadContent {
                hud = HUD(icon: "exclamationmark.triangle.fill", text: message)
            }
        }
        allCount = (try? await allTask)?.total
        isLoading = false
    }

    /// 一种 scope 一个接口，其余全一样（跟 iOS 那份同一个写法）。
    private func loadPage(_ page: Int, of scope: FollowScope) async throws -> (items: [FollowedUser], hasMore: Bool) {
        switch scope {
        case .all:
            let result = try await queue.followedUsers(page: page)
            return (result.items, result.hasMore)
        case .group(let group):
            return try await queue.followGroupMembers(tagID: group.tagID, page: page)
        }
    }

    private func loadUsers(of scope: FollowScope, reset: Bool) async {
        let hadContent = !users.isEmpty
        if reset {
            isLoading = true
            errorMessage = nil
        }

        do {
            let result = try await loadPage(reset ? 1 : page, of: scope)
            if reset {
                users = result.items
                page = 2
            } else {
                // 同一页可能被 onAppear 触发两次，按 mid 去重
                let known = Set(users.map(\.mid))
                users.append(contentsOf: result.items.filter { !known.contains($0.mid) })
                page += 1
            }
            hasMore = result.hasMore
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if reset {
                errorMessage = message
                if hadContent {
                    hud = HUD(icon: "exclamationmark.triangle.fill", text: message)
                }
            } else {
                // 翻页翻不动了就当到底，别揪着同一页一直重试
                hasMore = false
            }
        }

        if reset {
            isLoading = false
        }
    }

    private func loadMore() async {
        guard let scope = openedScope, hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loadUsers(of: scope, reset: false)
    }

    /// 一打字就把剩下的页全翻回来（理由见上面 `.searchable` 那段）：
    /// 一页 20 个，只筛已经拉回来的那几页等于搜到哪儿算哪儿。
    private func loadRestForSearch() async {
        guard let scope = openedScope, hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        var known = Set(users.map(\.mid))
        var next = page
        while hasMore {
            // 翻不动了就当到底：搜出来的少几个，也好过卡在这儿一直重试同一页
            guard let result = try? await loadPage(next, of: scope) else { break }
            users.append(contentsOf: result.items.filter { known.insert($0.mid).inserted })
            hasMore = result.hasMore
            next += 1
        }
        page = next
    }
}
