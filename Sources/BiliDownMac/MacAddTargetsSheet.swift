import SwiftUI
import AppKit
import BiliCore
import BiliKit
import BiliUI

/// 唯一的添加入口：手输、批量粘贴、拖进来的链接都在这一页。
/// 认出来的东西分两种：单个视频，和一整批（UP 主投稿 / 合集）。
///
/// 底下那套状态机（解析、拉信息、缓存、勾选、入队）在 BiliUI 的
/// `TargetResolver` 里，iOS 版共用同一份。这一页只剩排版。
struct MacAddTargetsSheet: View {

    /// 从外面递进来的内容（剪贴板检测、URL Scheme、拖放）。
    /// 传了它就不摆输入框让用户改 —— 内容已经定死了，只剩「下哪种」和「要不要挑 P」。
    var initialEntries: [InputEntry] = []

    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.dismiss) private var dismiss

    @StateObject private var resolver = TargetResolver()
    @State private var text = ""
    @State private var kind: DownloadKind = .audiovisual
    @State private var picker: TargetResolver.PickTarget?
    @State private var isCommitting = false

    /// 输入框高度。跟 iOS 版一样存着 —— 想要大输入框的人是每次都想要大的。
    @AppStorage("MacAddTargetsEditorHeight") private var editorHeight: Double = 110
    /// 这一把拖拽开始时的基准高度，松手清掉。
    @State private var dragAnchor: Double?
    /// 拖动过程中的实时高度。只用来显示，松手了才写回上面那个 ——
    /// 每帧都往 UserDefaults 里塞一遍纯属白费。
    @State private var dragHeight: Double?
    /// 这一把拖拽最多能拖到多高。跟 `dragAnchor` 一样在按下那刻定死。
    @State private var dragLimit: Double?
    /// 上面那份结果眼下有多高，实时量出来的（见 `previewList`）。
    /// 「框还能再长多高」全看它还剩多少能让。
    @State private var previewHeight: CGFloat = 0

    /// 眼下该多高：正在拖就听拖的，否则听存下来的。
    private var editingHeight: CGFloat { CGFloat(dragHeight ?? editorHeight) }

    /// 弹层的尺寸**是钉死的**。
    ///
    /// 原来只写了 `minHeight`，剩下的交给内容自己撑 —— 那是「按内容自适应」，
    /// 横条一拖过头，上面那块已经挤不动了，多出来的高度就把整个窗口往下顶，
    /// 看着就是「底下一直在变长」。改成定值之后，能变的只有框里那两块怎么分。
    private static let sheetWidth: CGFloat = 560
    private static let sheetHeight: CGFloat = 560

    /// 输入框能拖到的范围。下限差不多三行；上限还有个「按实测算」的更紧的盖子，
    /// 见 `resizeHandle` —— 这个只是无论怎么算都不许越过的那条线。
    private static let minEditorHeight: Double = 80
    private static let maxEditorHeight: Double = 360

    /// 上面那份结果最少得留这么高 —— 空态那个图标加两行字差不多就是这个数，
    /// 再矮就只剩半行了。拖到这儿横条就不再往上走。
    private static let minPreviewHeight: CGFloat = 150

    private var showsEditor: Bool { initialEntries.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // macOS 的 sheet 没有导航栏，navigationTitle 在这儿是不显示的，
            // 标题得自己画一行 —— 不然这个窗口顶上是空的。
            Text("添加任务")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Divider()

            // 从上到下：识别结果 → 输入框 → 下载模式。
            // 结果摆最上面：它是「已经认出来的东西」，一眼就能核对是不是想要的。
            previewList
                // 量一下这块眼下的高度。横条能拖到哪儿，全看它还剩多少可让 ——
                // 这个数没法写死：上下那几行的实际高度随字体和系统版本变，
                // 写死了哪天就悄悄对不上。
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PreviewHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .onPreferenceChange(PreviewHeightKey.self) { previewHeight = $0 }

            if showsEditor {
                // 这根横条同时顶替了原本那条 `Divider()`
                resizeHandle
                editor
            }

            Divider()
            footer
        }
        .frame(minWidth: Self.sheetWidth)
        .frame(height: Self.sheetHeight)
        .onChangeCompat(of: text) { _ in
            resolver.sync(text: text, using: queue)
        }
        .task {
            if !showsEditor {
                // 外面递进来的：没有文本框可解析，直接把内容摆上、开始拉信息
                resolver.adopt(initialEntries, using: queue)
            }
        }
        .onDisappear { resolver.cancel() }
        .sheet(item: $picker) { target in
            // 这儿只记下挑了什么，真正入队等点「添加」的时候一起做
            switch target {
            case .pages(let parsed):
                MacPagePickerSheet(target: parsed, confirmVerb: "选择") { pages in
                    resolver.confirm(pages: pages, for: parsed)
                }
                .environmentObject(queue)

            case .bulk(let source):
                let model = resolver.pickerModel(for: source)
                MacVideoPickerSheet(
                    listTitle: model.listTitle,
                    videos: model.videos,
                    total: model.total,
                    isLoadingMore: model.isLoadingMore,
                    selection: model.selection,
                    onLoadMore: { await resolver.loadMoreBulk(source, using: queue) },
                    onConfirm: { resolver.confirm(selection: $0, for: source) }
                )
                .environmentObject(queue)
            }
        }
    }

    // MARK: - 输入框

    /// 占位文本的内边距。也是「正文该落在哪儿」的基准。
    ///
    /// 这两笔原来是分开写的：正文 6/8，占位 14/13 —— 差的那 8 和 5 正是
    /// **iOS** 那个 `TextEditor` 自己的内部边距，两头加起来刚好一样，所以在 iOS 上
    /// 看着是齐的。macOS 这层的内部边距纵向几乎为零、**横向却有半个汉字**
    /// （约 6.5），于是正文顶到了上边、又往右偏了半个字。
    private static let editorInsetH: CGFloat = 13
    private static let editorInsetV: CGFloat = 14
    /// macOS 那个 `TextEditor` 自己带的一道**横向**内部缩进（纵向没有）。
    /// 正文因此要比占位少留这么多，两边才落在同一个 x 上。
    private static let editorInternalInsetH: CGFloat = 6.5

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, Self.editorInsetH - Self.editorInternalInsetH)
                .padding(.vertical, Self.editorInsetV)

            if text.isEmpty {
                Text("支持 BV/av 号、视频链接、用户主页链接或合集链接\n可填写多条, 每行一条")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Self.editorInsetH)
                    .padding(.vertical, Self.editorInsetV)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: editingHeight)
    }

    /// 输入框顶上那根能拽的横条。它长在输入框和上面那份结果的交界处，
    /// 所以同时就是那一条分界线（左右两截线，中间留出横条的位置）。
    ///
    /// 手感上要占满整行才好按：横条本身只有 5pt 高，鼠标按不准，
    /// 真正接手势的是外面那圈透明区域（contentShape）。
    private var resizeHandle: some View {
        HStack(spacing: 10) {
            dividerSegment
            Capsule()
                .fill(.tertiary)
                .frame(width: 44, height: 5)
            dividerSegment
        }
        .frame(height: 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // 鼠标挪上来就换成「上下可拖」的指针。mac 上没有这个提示，
        // 那根横条看着就只是条分界线，没人会想到它还能拖。
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            // 坐标空间必须钉成 .global。默认的 .local 是「以这根横条自己为原点」，
            // 而横条就长在输入框上沿 —— 框一高一矮它自己就跟着上下跑，
            // 位移里于是混进了「横条自己挪了多少」，看着就是一直抖。
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // 手势给的是「从按下那刻起累计的位移」。基准得取按下时的高度，
                    // 不能取当前值 —— 那样每来一个事件就叠一次，没拖多远框就飞了。
                    let anchor = dragAnchor ?? editorHeight
                    dragAnchor = anchor
                    // 能拖到多高，按下那刻就算好并定死：
                    // 框和上面那块分的是同一个固定高度，所以「还能长多少」
                    // = 上面那块眼下的高度 − 它最少要留的高度。
                    // 一边拖一边重算的话，上面那块每让一点、上限就跟着降一点，
                    // 拖到半路就自己刹住了。
                    let room = Double(max(0, previewHeight - Self.minPreviewHeight))
                    let limit = dragLimit ?? min(Self.maxEditorHeight, anchor + room)
                    dragLimit = limit
                    // 减号：横条在上沿，顺着鼠标往上拖（translation 为负）才是长高，
                    // 上面那份结果跟着让地方。
                    dragHeight = min(
                        max(anchor - value.translation.height, Self.minEditorHeight),
                        limit
                    )
                }
                .onEnded { _ in
                    // 松手才落盘
                    if let dragHeight { editorHeight = dragHeight }
                    dragHeight = nil
                    dragAnchor = nil
                    dragLimit = nil
                }
        )
        .accessibilityLabel("调整输入框高度")
    }

    /// 横条左右那两截分界线。`HStack` 里的 `Divider()` 是**竖**的，
    /// 要横线得自己画一根。
    private var dividerSegment: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // 分段控件自己那个标签被藏了（四个格子已经把「在选什么」说清楚了，
            // 再顶一行字纯属重复），但整行没有标签的话，第一次看见这四个格子
            // 未必知道选的是「下什么」。所以在这儿补一个前置标签。
            // 不加冒号：mac 上表单标签本来就不带，带了反而像 iOS。
            Text("下载模式")

            Picker("下载模式", selection: $kind) {
                ForEach(DownloadKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            if isCommitting {
                ProgressView().controlSize(.small)
            } else {
                Button(resolver.countText) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolver.entries.isEmpty || resolver.isResolvingBulk)
            }
        }
        .padding(12)
    }

    // MARK: - 识别结果

    @ViewBuilder
    private var previewList: some View {
        if resolver.entries.isEmpty {
            // 跟 ListPlaceholder 一个样子：图标 40、标题走 Typography 那个大标题、
            // 副标题 callout。这三档原来是自己手写的（36 / .headline / .callout），
            // 手写的 `.headline` 在 mac 上是 13 的粗体 —— 标题比正文还小，
            // 所以改字号的时候漏了它。现在归到共用那档上，以后一起动。
            VStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("没有待添加任务")
                    .font(Typography.placeholderTitle)
                Text("在下方输入编号或链接")
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(resolver.entries) { entry in
                        // 上下各垫一点：mac 的 List 行是贴着的，跟收藏夹里那些
                        // 视频列表、跟点进去那个列表取的是同一个数（见 `ListRowMetrics`）
                        row(for: entry)
                            .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                    }
                } header: {
                    Text("识别到 \(resolver.entries.count) 个")
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(for entry: InputEntry) -> some View {
        let content = resolver.content(for: entry)

        return InputRow(
            thumbnail: content.thumbnail,
            title: content.title,
            titleColor: content.titleColor,
            ownerName: content.ownerName,
            identifier: content.identifier,
            badge: content.badge,
            trailing: content.trailing,
            onPick: content.canPick ? {
                picker = resolver.pickerTarget(for: entry)
            } : nil
        )
    }

    // MARK: - 入队

    private func commit() {
        guard !isCommitting else { return }
        isCommitting = true
        Task {
            let targets = await resolver.targets(using: queue)
            queue.add(targets, kind: kind)
            resolver.resetSelection()
            isCommitting = false
            dismiss()
        }
    }
}

/// 上面那份结果的高度，从底下量上来传给 sheet。
/// 只有一处会给出这个数，所以 reduce 直接取最后那个值。
private struct PreviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
