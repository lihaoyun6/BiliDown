import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 一页「列表的列表」：我订阅的合集 / 我的追番 / 我的追剧。
///
/// 这三页在 iOS 上都从「我的」推进来，形状一样 —— 一列条目，点进去才是视频
///（合集点进去是合集里的视频，追番点进去是那一季的分集）。区别只有拉哪个接口、
/// 行上摆什么，所以共用这一个页面；收藏那页不在这儿，它自己一页
///（`FavoritesView`）。
///
/// **不套 `NavigationStack`**：这几页是推进来的 —— 再套一层就是导航栈里套导航栈，
/// 顶上会叠出两条栏。标题、搜索框照旧，它们本来就归上面那一层管。
/// 标题读 `kind.mineTitle` —— 跟「我的」里那一行是同一个名字。
///
/// mac 那边对应的是 `MacLibraryList`（同一个 `LibraryListKind`）。
struct LibraryListView: View {

    let kind: LibraryListKind

    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var settings: AppSettings

    /// 合集和追番是两套数据、两个接口，就分开放 —— 合到一个枚举里
    /// 只会让每一处都得先拆包再取值，读起来绕。
    @State private var collections: [SubscribedCollection] = []
    @State private var seasons: [FollowedSeason] = []

    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""

    var body: some View {
        let visible = visibleCollections
        let visibleSeasons = visibleFollowedSeasons

        content(empty: visible.isEmpty && visibleSeasons.isEmpty) {
            if kind == .collections {
                ForEach(visible) { item in
                    NavigationLink {
                        VideoPickerView(source: .collection(item))
                    } label: {
                        collectionRow(item)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .onAppear {
                        // 比的是显示的那一份（理由同 VideoPickerView）
                        if item.seasonID == visible.last?.seasonID {
                            Task { await loadMore() }
                        }
                    }
                }
            } else {
                ForEach(visibleSeasons) { season in
                    NavigationLink {
                        VideoPickerView(source: .season(season))
                    } label: {
                        seasonRow(season)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .onAppear {
                        if season.seasonID == visibleSeasons.last?.seasonID {
                            Task { await loadMore() }
                        }
                    }
                }
            }

            if isLoadingMore {
                LoadMoreSpinner()
            }
        }
        .navigationTitle(kind.mineTitle)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: kind.searchPrompt
        )
        // 列表也是一页 15 / 20 条，搜索得搜全量（理由同 VideoPickerView）
        .onChangeCompat(of: query) { newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await loadRestForSearch() }
        }
        .task { await loadFirstPage() }
        .refreshable { await loadFirstPage() }
    }

    /// 骨架：正在读 / 读失败 / 空 / 有内容都在同一个 List 里切，
    /// 只有行在变，滚动视图不重建。
    private func content<Rows: View>(
        empty: Bool,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        List {
            if empty {
                if isLoading {
                    LoadingRow()
                } else if let errorMessage {
                    ListPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: kind.errorTitle,
                        message: errorMessage,
                        retry: { Task { await loadFirstPage() } }
                    )
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ListPlaceholder(
                        icon: kind.icon,
                        title: kind.emptyTitle,
                        message: kind.emptyMessage
                    )
                } else {
                    ListPlaceholder(icon: "magnifyingglass", title: "没有匹配的")
                }
            } else {
                rows()
            }
        }
    }

    // MARK: - 显示哪些

    /// 显示的那些。开了「过滤无效内容」就把「该合集已失效」的藏掉。
    /// 只摘显示这一层，底层数据留着。
    private var visibleCollections: [SubscribedCollection] {
        guard kind == .collections else { return [] }
        let kept = settings.filterInvalidContent ? collections.filter(\.isAvailable) : collections
        // 搜 UP 主名也一并算上：经常是「想找某个人的合集」，
        // 光搜合集的标题未必想得起来叫什么
        return SearchFilter.match(kept, query: query) { [$0.title, $0.ownerName] }
    }

    private var visibleFollowedSeasons: [FollowedSeason] {
        guard kind != .collections else { return [] }
        return SearchFilter.match(seasons, query: query) { [$0.title] }
    }

    // MARK: - 行

    private func collectionRow(_ item: SubscribedCollection) -> some View {
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

    /// 追番 / 追剧那一行。中间那行摆「更新至第 220 话」（接口给的 `index_show`）——
    /// 追番列表里最要紧的就是这一句，比 UP 主名有用得多。
    /// 接口偶尔不给（还没开播的），这一行就空着，行高跟别的一样。
    private func seasonRow(_ season: FollowedSeason) -> some View {
        HStack(spacing: 12) {
            CoverThumbnail(url: season.coverURL)

            VStack(alignment: .leading, spacing: ListRowMetrics.textSpacing) {
                Text(season.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(season.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("\(season.episodeCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 加载

    private func loadFirstPage() async {
        errorMessage = nil
        page = 1
        hasMore = true
        do {
            try await load(page: 1, replace: true)
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
            try await load(page: page, replace: false)
            page += 1
        } catch {
            hasMore = false
        }
    }

    /// 两个来源的翻页。`replace` 决定是覆盖还是往后接 ——
    /// 顺便按 id 去重，同一页可能被 onAppear 触发两次。
    private func load(page: Int, replace: Bool) async throws {
        switch kind {
        case .collections:
            let result = try await queue.subscribedCollections(page: page)
            let known = Set(collections.map(\.seasonID))
            let fresh = result.items.filter { !known.contains($0.seasonID) }
            collections = replace ? result.items : collections + fresh
            hasMore = result.hasMore

        case .bangumi, .drama:
            let result = try await queue.followedSeasons(type: kind.bangumiType ?? 1, page: page)
            let known = Set(seasons.map(\.seasonID))
            let fresh = result.items.filter { !known.contains($0.seasonID) }
            seasons = replace ? result.items : seasons + fresh
            hasMore = result.hasMore

        case .favorites:
            // iOS 的收藏是标签栏自己一整页（FavoritesView），不走这儿；
            // mac 那份用的是同一个 kind，那边有它自己的实现
            break
        }
    }

    private var currentCount: Int {
        kind == .collections ? collections.count : seasons.count
    }

    /// 搜索要拿全量：现在手上只有头一页，不把剩下的翻完，
    /// 搜出来的「没有匹配的」是假的。翻的过程中底下那个转圈照转。
    private func loadRestForSearch() async {
        while hasMore {
            let before = currentCount
            await loadMore()
            // 没往前推进就说明到底了或者出错了，别在这儿空转
            if currentCount == before { break }
        }
    }
}
