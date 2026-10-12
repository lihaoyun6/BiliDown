import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 「我的关注」那一层：先看分组，点进一组是这一组里的人，再点进去是 TA 的投稿。
///
/// 分两层列是**因为平铺没法用**：关注几十上百号人的时候，一列排下来想找谁
/// 只能一直往下滚。分组是 B 站本来就有的东西，顺着它走就行 ——
///「默认分组」和「特别关注」这两条也混在同一个数组里回来，不用特判。
///
/// **不套 `NavigationStack`**：这两页都是推进来的，再套一层顶上就叠出两条栏。
/// 两页的形状跟收藏夹 / 合集那几页是一个路数（见 `LibraryListView`）。
///
/// 只从「我的」那一页里登录后才画出来的那一块进来（见 `MineView.body`），
/// 所以**这一页不用自己处理「没登录」**：登出之后连入口带这一页一起没了。
/// 不然就得在这儿摆一块「还没有登录」，而没登录时接口回 -101 抛出来的那句是
/// 「需要登录后才能拿到这个画质」—— 摆在关注分组上驴唇不对马嘴。
struct FollowGroupsView: View {

    /// 这一页的名字。「我的」里那一行读的是同一个 ——
    /// 名字写两份，就会再有「行上叫我的关注、进去标题少几个字」这种事。
    static let pageTitle = "我的关注"

    @EnvironmentObject private var queue: DownloadQueue

    @State private var groups: [FollowGroup] = []
    /// 「全部关注」有多少人。拿不到就不报这个数（见 `load()`）——
    /// 那一行照样能点，进去有它自己的报错。
    @State private var allCount: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""

    var body: some View {
        List {
            if groups.isEmpty {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ListPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: "读不到关注分组",
                        message: errorMessage,
                        retry: { Task { await load() } }
                    )
                } else {
                    ListPlaceholder(
                        icon: "person.2",
                        title: "还没有关注分组",
                        message: "在 B 站把关注的人分个组，这里就能看到。"
                    )
                }
            } else if visibleGroups.isEmpty {
                ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的分组")
            } else {
                // 「全部关注」单列一项摆在最上面：它**不是分组**（接口那层就不是，
                // 见 `FollowScope`），但这一页最常用的恰恰是它 —— 想找的人在哪一组
                // 未必记得住，记不住就得先看全部。
                //
                // 搜索的时候它让位：它不是搜出来的东西，留在那儿会让人以为
                // 「全部关注」这个名字匹配了关键词。
                if !isSearching {
                    NavigationLink {
                        FollowUsersView(scope: .all)
                    } label: {
                        allRow
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }

                ForEach(visibleGroups) { group in
                    NavigationLink {
                        FollowUsersView(scope: .group(group))
                    } label: {
                        row(group)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
        .navigationTitle(Self.pageTitle)
        // 分组一次全拉回来了，就地筛（跟收藏夹那页一样）
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索分组"
        )
        .task { await load() }
        .refreshable { await load() }
    }

    private var visibleGroups: [FollowGroup] {
        SearchFilter.match(groups, query: query) { [$0.name] }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 顶上那一行「全部关注」。形状跟分组那些行**一模一样** —— 同样高的占位封面、
    /// 同样两行字的位置、右边同样报个人数，一列扫下来不会觉得它不是一路东西。
    /// 图标用 `person.3`（一堆人）跟分组的 `person.2`（一伙人）分开。
    private var allRow: some View {
        HStack(spacing: 12) {
            CoverThumbnail(url: nil, placeholderSystemImage: "person.3")

            VStack(alignment: .leading, spacing: ListRowMetrics.textSpacing) {
                Text(FollowScope.all.title)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Text(" ")
                    .font(Typography.caption)
            }

            Spacer(minLength: 8)

            if let allCount {
                Text("\(allCount)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一行分组：占位封面 + 组名 + 人数。
    ///
    /// 封面那块是假的（分组没有封面可拿），但**尺寸是真的** —— 走
    /// `CoverThumbnail` 的占位那一档，行高就跟收藏夹 / 合集那几页对得上，
    /// 来回翻的时候不会一跳一跳。收藏夹列表也是这么办的（那边占位图标是文件夹）。
    ///
    /// 人数跟别处一样摆在最右边、次要色、等宽数字：一列扫下来右边缘是对齐的。
    private func row(_ group: FollowGroup) -> some View {
        HStack(spacing: 12) {
            CoverThumbnail(url: nil, placeholderSystemImage: "person.2")

            // 行距跟别处的两行字一样（见 `ListRowMetrics`）
            VStack(alignment: .leading, spacing: ListRowMetrics.textSpacing) {
                Text(group.name)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                // 这一行不写东西，但得占着位置 —— 见 FollowUsersView 里那段。
                // 分组只剩名字一行的话，这一页的行会比别处矮一截。
                Text(" ")
                    .font(Typography.caption)
            }

            Spacer(minLength: 8)

            Text("\(group.count)")
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        errorMessage = nil
        // 分组和「全部关注」的人数**并着发**：两笔请求同时在路上，
        // 这一页不会为了那一个数字多等一个来回。
        //
        // 人数那笔失败了不管：`try?` 收成 nil，那一行不报数就是了。
        // 为了一个装饰性的数字把整页打成「读不到关注分组」不值当 ——
        // 分组本身是好的，进去看人也是好的。
        async let allTask = queue.followedUsers(page: 1)
        do {
            groups = try await queue.followGroups()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        allCount = (try? await allTask)?.total
        isLoading = false
    }
}

/// 一组人（「全部关注」或某一个分组）。点一个进 TA 的投稿列表。
///
/// 两种 scope 在这一页**只差一个接口**（见 `loadPage(_:)`），其余全一样，
/// 所以是一页而不是两页 —— 搜索、翻页、空态、行长相都只写一份。
struct FollowUsersView: View {

    let scope: FollowScope

    @EnvironmentObject private var queue: DownloadQueue

    @State private var users: [FollowedUser] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""

    /// 头像那一格。比封面（`ListRowMetrics.coverHeight`，56）收一点：
    /// 圆的看着比方片子占地方，同样高就显得比别页的行大一号。
    private static let avatarSize: CGFloat = 48

    var body: some View {
        List {
            if users.isEmpty {
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
            } else {
                ForEach(visibleUsers) { user in
                    NavigationLink {
                        VideoPickerView(source: .uploads(mid: user.mid, ownerName: user.name))
                    } label: {
                        row(user)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .onAppear {
                        // 拿**显示的那一份**的末尾来比（理由同 VideoPickerView）：
                        // 拿底层那个 `users` 的末尾不行 —— 搜索的时候最后拉到的那个人
                        // 可能正好被筛掉了，那就没有任何一行能跟它相等，永远翻不到下一页。
                        if user.mid == visibleUsers.last?.mid {
                            Task { await loadMore() }
                        }
                    }
                }

                if isLoadingMore {
                    LoadMoreSpinner()
                }
            }
        }
        .navigationTitle(scope.title)
        // 搜索得搜**全量**，跟挑视频那页一个道理：人是一页 20 个拉回来的，
        // 只筛已经拉回来的那几页，等于搜到哪儿算哪儿 —— 有人关注了几百号，
        // 搜出来的结果全看滚了多远，那这个框还不如没有。
        // 所以一开始打字就把剩下的页全翻回来（见 `loadRestForSearch`）。
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索用户"
        )
        .onChangeCompat(of: query) { newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await loadRestForSearch() }
        }
        .task { await loadFirstPage() }
        .refreshable { await loadFirstPage() }
    }

    /// 界面上真正要显示的那些人。昵称和简介都搜 ——
    /// 简介里常写着「这是小号」「停更了」这类只有那儿才有的字。
    private var visibleUsers: [FollowedUser] {
        SearchFilter.match(users, query: query) { [$0.name, $0.sign] }
    }

    /// 空态 / 读失败那两句话。两种 scope 说的是同一件事，只是措辞不同 ——
    /// 「这个分组」摆在「全部关注」上就不对了。
    private var emptyTitle: String {
        switch scope {
        case .all: return "还没有关注的人"
        case .group: return "这个分组里还没有人"
        }
    }

    private var errorTitle: String {
        switch scope {
        case .all: return "读不到关注列表"
        case .group: return "读不到这个分组"
        }
    }

    /// 一行一个人：圆形头像 + 昵称 + 个人简介。
    ///
    /// 简介那一行走 `signText`：没写简介的人显示的是一句占位话（见 `FollowedUser`），
    /// 不留空。空着的话那一行就塌下去，一列扫下来高矮不齐，而且光看一片空白
    /// 分不清是「这人没写」还是「这页没加载完」。一个字也放不下的窄屏上，
    /// `lineLimit(1)` 自己会截。
    private func row(_ user: FollowedUser) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: user.avatarURL, size: Self.avatarSize)

            // 两行之间 5，比别处那些「标题 + 一行小字」的 2 松 —— 那些行旁边是
            // 封面，这里是**48 的头像**：两行字加起来还没头像高，间距给 2 的话
            // 挤成一小团吊在头像中间。撑不开行高（5 也还在 48 以内），只是摊开。
            VStack(alignment: .leading, spacing: 5) {
                Text(user.name)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Text(user.signText)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }

    // MARK: - 加载

    /// 一种 scope 一个接口，其余全一样。两种都回「这一页的人 + 还有没有下一页」，
    /// 差异收在这一个地方。
    private func loadPage(_ page: Int) async throws -> (items: [FollowedUser], hasMore: Bool) {
        switch scope {
        case .all:
            let result = try await queue.followedUsers(page: page)
            return (result.items, result.hasMore)
        case .group(let group):
            return try await queue.followGroupMembers(tagID: group.tagID, page: page)
        }
    }

    private func loadFirstPage() async {
        errorMessage = nil
        page = 1
        hasMore = true
        do {
            let result = try await loadPage(1)
            users = result.items
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
            // 同一页可能被 onAppear 触发两次，按 mid 去重
            let known = Set(users.map(\.mid))
            users.append(contentsOf: result.items.filter { !known.contains($0.mid) })
            hasMore = result.hasMore
            page += 1
        } catch {
            hasMore = false
        }
    }

    /// 一打字就把剩下的页全翻回来（理由见上面 `.searchable` 那段）。
    private func loadRestForSearch() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        var known = Set(users.map(\.mid))
        var next = page
        while hasMore {
            // 翻不动了就当到底：搜出来的少几个，也好过卡在这儿一直重试同一页
            guard let result = try? await loadPage(next) else { break }
            users.append(contentsOf: result.items.filter { known.insert($0.mid).inserted })
            hasMore = result.hasMore
            next += 1
        }
        page = next
    }
}
