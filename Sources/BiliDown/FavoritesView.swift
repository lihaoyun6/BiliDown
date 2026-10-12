import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 「我的」里最上面那个入口：按收藏夹分组，进去挑视频批量下载。
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
        // 这一页现在是**推入**的（从「我的」点进来），所以**不套 NavigationStack** ——
        // 自己再套一层的话，顶上会叠出两条栏，返回按钮也出不来。
        // 搜索框照旧是 `.navigationBarDrawer(displayMode: .always)`：
        // 推入的页面一样认这个摆法，框还是常驻在标题底下、往上推列表时跟着大标题缩。
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
                        VideoPickerView(source: .folder(folder))
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
