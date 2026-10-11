import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 接分享进来的链接。挂在根视图上。
///
/// 系统把内容递给一个 App 只有「打开 URL」这一种形式。目前真会走到这条路的
/// 是 LiveContainer：它自己当分享目标，弹窗让你选一个 guest app，再把链接
/// 转交给那个 App。所以这里要有一个自己的 URL scheme（Info.plist 里那个
/// `bilidown`）才接得住。
///
/// 收到之后按来源分三种走法：
///   - 普通视频：没什么可挑的，直接问要下哪种
///   - 分 P 视频：先挑 P，再问要下哪种
///   - UP 主主页 / 合集：先挑视频，再问要下哪种
/// 挑完就入队 —— 分享这个动作本身意图很明确，不再走「添加任务」那套编辑框。
///
/// 解析靠的是 ShareLinkParser 本来就在干的事：从一段文本里抠 b23.tv / BV / av。
/// LiveContainer 把原链接整个塞进一个参数里、还编码过一遍也无所谓，
/// 先整体解一次码再交给它，链接照样找得到。
struct SharedLinkReceiver: ViewModifier {

    /// 当前在哪一页。任务建好之后要把用户送到「下载」去。
    /// 被快捷指令唤起的时候，App 十有八九停在别的页面上（或者是刚冷启动），
    /// 不切过去的话人只看见界面闪一下，不知道东西加到哪儿了。
    @Binding var selection: RootView.Tab

    @EnvironmentObject private var queue: DownloadQueue

    /// 还没处理的条目。分享通常只有一条，多条也能一条条过完。
    @State private var pending: [InputEntry] = []
    /// 已经定下来的目标，最后一起问要下哪种
    @State private var targets: [ParsedTarget] = []

    /// 选择器里挑好、但还没换算成目标的。换算成「全都要」得联网把后面的页翻完，
    /// 所以要等选择器关掉之后再做。
    @State private var picked: (source: BulkSource, selection: VideoSelection)?

    @State private var pageTarget: ParsedTarget?
    @State private var bulkSource: BulkSource?
    @State private var bulk: BulkState?
    @State private var bulkPaging = false

    @State private var isAskingKind = false
    @State private var hud: HUD?

    func body(content: Content) -> some View {
        content
            .onOpenURL { receive($0) }
            .sheet(item: $pageTarget, onDismiss: { advance() }) { target in
                PagePickerSheet(target: target, confirmVerb: "选择") { pages in
                    targets.append(contentsOf: pages.map { ParsedTarget(ref: target.ref, page: $0) })
                }
            }
            // 挂在上一个 sheet 外面一层，两个 sheet 不在同一个视图上，免得有一个弹不出来
            .sheet(item: $bulkSource, onDismiss: { advance() }) { source in
                picker(for: source)
            }
            .confirmationDialog("下载内容", isPresented: $isAskingKind, titleVisibility: .visible) {
                ForEach(DownloadKind.allCases) { kind in
                    Button(kind.displayName) { download(kind) }
                }
                Button("取消", role: .cancel) {}
            }
            .hud($hud)
    }

    // MARK: - 入口

    private func receive(_ url: URL) {
        // 记一笔：这一下是链接唤起来的，剪贴板那边就别再插一脚了
        URLOpenMarker.note()

        // 递进来的一定是一串 URL。包裹层和原链接一起解一次码就够，
        // 解析器自己会在里面找链接，不用管外层长什么样。
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString

        let entries = ShareLinkParser.parseEntries(text)
        guard !entries.isEmpty else {
            hud = HUD(icon: "questionmark.circle.fill", text: "没认出这个链接")
            return
        }

        pending = entries
        targets.removeAll()
        picked = nil
        advance()
    }

    // MARK: - 一步步来

    /// 选择器是独立的 sheet，在它的 onDismiss 里接着往下走 ——
    /// sheet 还在往下收的时候弹不出下一个东西。
    private func advance() {
        Task { await step() }
    }

    private func step() async {
        // 上一个选择器挑好的先换算成目标
        if let picked {
            self.picked = nil
            await collect(picked.source, picked.selection)
        }

        // 没什么可挑的就一路走到底，碰到要挑的才停下来等
        while !pending.isEmpty {
            let entry = pending.removeFirst()

            switch entry {
            case .video(let target):
                // 链接里带了 ?p= 就是指名道姓要那一 P，不用问
                if target.page == nil,
                   let info = try? await queue.videoInfo(for: target.ref),
                   info.isMultiPage {
                    pageTarget = target
                    return
                }
                targets.append(target)

            case .bulk(let source):
                do {
                    let result = try await queue.bulkPage(source, page: 1)
                    bulk = BulkState(result: result)
                    bulkSource = source
                    return
                } catch {
                    // 这一个来源读不出来就跳过，别把别的也拖下水
                    hud = HUD(icon: "exclamationmark.triangle.fill", text: "这个来源没读出来")
                }
            }
        }

        finish()
    }

    private func finish() {
        guard !targets.isEmpty else {
            hud = HUD(icon: "questionmark.circle.fill", text: "没认出可下载的内容")
            return
        }
        isAskingKind = true
    }

    // MARK: - 选择器

    private func picker(for source: BulkSource) -> some View {
        VideoPickerSheet(
            listTitle: source.isCollection
                ? (bulk?.collectionTitle ?? "合集 \(source.seasonID ?? 0)")
                : (bulk?.profile?.name ?? "UP 主 \(source.mid)"),
            videos: bulk?.videos ?? [],
            total: bulk?.total ?? 0,
            isLoadingMore: bulkPaging,
            // 默认全都要，跟「添加任务」里一致
            selection: .all(except: []),
            onLoadMore: { await loadMore(source) },
            onConfirm: { picked = (source, $0) }
        )
    }

    /// 选择器里滚到底了，接着往后拉一页
    private func loadMore(_ source: BulkSource) async {
        guard var state = bulk, state.hasMore, !bulkPaging else { return }
        bulkPaging = true
        defer { bulkPaging = false }

        do {
            let next = try await queue.bulkPage(source, page: state.nextPage)
            let known = Set(state.videos.map(\.bvid))
            state.videos.append(contentsOf: next.videos.filter { !known.contains($0.bvid) })
            state.hasMore = next.hasMore
            state.nextPage += 1
        } catch {
            state.hasMore = false
        }
        bulk = state
    }

    // MARK: - 换算 & 入队

    /// 把选择器挑的结果换算成入队目标。
    /// 「全都要」得先把后面的页翻完 —— 没拉下来的那些也得算进去。
    private func collect(_ source: BulkSource, _ selection: VideoSelection) async {
        switch selection {
        case .only(let picked):
            targets.append(contentsOf: picked.sorted().map { ParsedTarget(ref: .bvid($0)) })

        case .all(let except):
            guard var state = bulk else { return }

            while state.hasMore {
                guard let next = try? await queue.bulkPage(source, page: state.nextPage) else { break }
                let known = Set(state.videos.map(\.bvid))
                state.videos.append(contentsOf: next.videos.filter { !known.contains($0.bvid) })
                state.hasMore = next.hasMore
                state.nextPage += 1
            }

            targets.append(contentsOf: state.videos
                .filter { !except.contains($0.bvid) }
                .map { ParsedTarget(ref: .bvid($0.bvid)) })
        }

        bulk = nil
        bulkSource = nil
    }

    private func download(_ kind: DownloadKind) {
        let added = queue.add(targets, kind: kind)
        targets.removeAll()

        // 先切页面再看结果。不管加没加成，用户想看的都是下载页 ——
        // 重复的那条也在那儿摆着，比一句「已经在队列里了」有用。
        selection = .downloads

        hud = added > 0
            ? HUD(icon: "checkmark.circle.fill", text: "已添加 \(added) 个视频")
            : HUD(icon: "info.circle.fill", text: "这些视频已经在队列里了")
    }
}

extension View {

    /// 挂在根视图上，接分享进来的链接。
    /// selection 传当前标签页：任务建好之后要把用户切到下载页看进度。
    func receivesSharedLinks(selection: Binding<RootView.Tab>) -> some View {
        modifier(SharedLinkReceiver(selection: selection))
    }
}
