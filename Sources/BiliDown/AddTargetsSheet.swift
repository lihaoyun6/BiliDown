import SwiftUI
import BiliCore
import BiliKit
import BiliUI
import UIKit

/// 唯一的添加入口：手输、剪贴板、批量粘贴都在这一页。
/// 认出来的东西分两种：单个视频，和一整批（UP 主投稿 / 合集）。
///
/// 底下那套状态机（解析、拉信息、缓存、勾选、入队）在 BiliUI 的
/// `TargetResolver` 里，macOS 版共用同一份。这一页只剩排版。
struct AddTargetsSheet: View {

    /// 剪贴板自动检测那条路进来的：内容已经定死了，
    /// 这一页就不该再摆一个输入框让用户去改 —— 只剩「下哪种、要不要挑 P」两件事。
    /// 不传就是原来那套（手输 / 批量粘贴）。
    var initialEntries: [InputEntry] = []

    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.dismiss) private var dismiss

    @StateObject private var resolver = TargetResolver()
    @State private var text = ""
    @State private var kind: DownloadKind = .audiovisual
    @State private var picker: TargetResolver.PickTarget?
    @State private var isCommitting = false

    @FocusState private var editorFocused: Bool

    /// 输入框高度。拽下面那根横条改，改了存着 ——
    /// 想要大输入框的人是每次都想要大的，每次重开都弹回默认只会让人再拽一遍。
    /// 用 Double 而不是 CGFloat：@AppStorage 认的是 UserDefaults 那几种类型，
    /// CGFloat 不在里头（用的时候再转一下，见 frame(height:)）。
    @AppStorage("AddTargetsEditorHeight") private var editorHeight: Double = 120
    /// 这一把拖拽开始时的基准高度，松手清掉。
    @State private var dragAnchor: Double?
    /// 拖动过程中的实时高度。拖的时候先只用它显示，松手了才写回上面那个 ——
    /// 每帧都往 UserDefaults 里塞一遍纯属白费。
    @State private var dragHeight: Double?

    /// 眼下该多高：正在拖就听拖的，否则听存下来的。
    private var editingHeight: CGFloat { CGFloat(dragHeight ?? editorHeight) }

    /// 能拽到的范围。下限差不多三行；上限再多，下面那份识别结果就没地方摆了。
    private static let minEditorHeight: Double = 72
    private static let maxEditorHeight: Double = 320

    var body: some View {
        NavigationStack {
            // 从上到下：识别结果 → 输入框 → 下载模式。
            // 结果摆最上面：它是「已经认出来的东西」，一眼就能核对是不是想要的；
            // 输入框挨着最后的模式选择器，下面那一整块是「我要干什么」。
            // 模式选择器沉在屏幕最底下不动：上面那份结果列表是可滚动的，
            // 选择器夹在它上面反而要被挤来挤去。
            VStack(spacing: 0) {
                previewList

                if showsEditor {
                    // 输入框顶上那根能拽的横条就是这一条分界线 ——
                    // 不再另外画一条线：把手落在两块的边界上，往上拖输入框长高、
                    // 上面那份结果让位，一条线两边一起动。
                    editor
                } else {
                    // 没有输入框（剪贴板那条路进来的）就还是用一条普通分界线
                    Divider()
                }

                // 输入框和模式选择器之间**不画**分界线：这俩是同一件事
                // （填什么 + 下成什么），中间横一条线反而把它们拆成两半。
                kindPicker
            }
            .navigationTitle("添加任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCommitting {
                        ProgressView()
                    } else {
                        Button(resolver.countText) { commit() }
                            .disabled(resolver.entries.isEmpty || resolver.isResolvingBulk)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            text = clipboard
                        }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    Button("完成") { editorFocused = false }
                }
            }
            .onChangeCompat(of: text) { _ in
                resolver.sync(text: text, using: queue)
            }
            .task {
                if showsEditor {
                    editorFocused = true
                } else {
                    // 剪贴板带进来的：没有文本框可解析，直接把内容摆上、开始拉信息
                    resolver.adopt(initialEntries, using: queue)
                }
            }
            .onDisappear { resolver.cancel() }
            .sheet(item: $picker) { target in
                // 这儿只记下挑了什么，真正入队等点「添加」的时候一起做
                switch target {
                case .pages(let parsed):
                    PagePickerSheet(target: parsed, kind: kind, confirmVerb: "选择") { pages in
                        resolver.confirm(pages: pages, for: parsed)
                    }

                case .bulk(let source):
                    let model = resolver.pickerModel(for: source)
                    VideoPickerSheet(
                        listTitle: model.listTitle,
                        videos: model.videos,
                        total: model.total,
                        isLoadingMore: model.isLoadingMore,
                        selection: model.selection,
                        onLoadMore: { await resolver.loadMoreBulk(source, using: queue) },
                        onConfirm: { resolver.confirm(selection: $0, for: source) }
                    )
                }
            }
        }
    }

    private var showsEditor: Bool { initialEntries.isEmpty }

    private var editor: some View {
        VStack(spacing: 0) {
            // 把手在上沿 —— 它同时充当上面那份识别结果和输入框之间的分界线
            resizeHandle

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if text.isEmpty {
                    Text("支持 BV/av 号、视频链接、用户主页链接或合集链接\n可填写多条, 每行一条")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            // 高度归用户管（拽上面那根横条），不再写死 96…150
            .frame(height: editingHeight)
        }
    }

    /// 输入框顶上那根能拽的小横条。它长在输入框和上面那份结果的交界处，
    /// 所以同时就是那一条分界线。
    ///
    /// 手感上要占满整行才好按：横条本身就 5pt 高，手指按不准，
    /// 真正接手势的是外面那圈透明区域（contentShape）。
    private var resizeHandle: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 40, height: 5)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // 坐标空间必须钉成 .global（屏幕坐标）。
                // 默认的 .local 是「以这根横条自己为原点」—— 而横条就长在输入框上沿，
                // 框一高一矮它自己就跟着上下跑。于是位移里混进了「横条自己挪了多少」，
                // 输入框越拖越抖，看着就是一直闪。
                // 换成屏幕坐标，手指动多少就是多少，跟横条飘到哪儿没关系。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // 手势给的是「从按下那刻起累计的位移」。
                        // 得拿按下时的高度当基准往上加，不能拿当前值 ——
                        // 那样每来一个事件就叠一次，手指没动多远框就飞了。
                        let anchor = dragAnchor ?? editorHeight
                        dragAnchor = anchor
                        // 减号：把手在上沿，顺着手指往上拖（translation 为负）才是长高，
                        // 上面那份结果跟着让地方。加号的话就成了往下拖反而变高。
                        dragHeight = min(
                            max(anchor - value.translation.height, Self.minEditorHeight),
                            Self.maxEditorHeight
                        )
                    }
                    .onEnded { _ in
                        // 松手才落盘
                        if let dragHeight { editorHeight = dragHeight }
                        dragHeight = nil
                        dragAnchor = nil
                    }
            )
            .accessibilityLabel("调整输入框高度")
    }

    private var kindPicker: some View {
        Picker("下载内容", selection: $kind) {
            ForEach(DownloadKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var previewList: some View {
        if resolver.entries.isEmpty {
            // 原来这儿还有一句「在此填写编号或链接」加一根朝下的手指 ——
            // 指头是对着下面那个输入框的，现在这话并进副标题里，手指去掉。
            ContentUnavailableView {
                Label("没有待添加任务", systemImage: "link")
            } description: {
                Text("在下方输入编号或链接")
            }
            // 占满这一块：上面那份结果列表就是这么高的
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 跟有结果时的列表底色对齐，不然这一块是纯白的
            .background(Color(.systemGroupedBackground))
        } else {
            List {
                Section {
                    // 行**不另外垫边距**（原来这儿写死过 6/12）：全 App 的列表
                    // 行都靠 List 自己那套默认内边距，这一页跟收藏夹里那些
                    // 视频行摆在一起才是同一个松紧。垫了这一层，这一页的行
                    // 上下都比别的列表紧一截，一眼就能看出来。
                    ForEach(resolver.entries) { entry in
                        row(for: entry)
                    }
                } header: {
                    Text("识别到 \(resolver.entries.count) 个")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(for entry: InputEntry) -> some View {
        let content = resolver.content(for: entry)

        return InputRow(
            thumbnail: content.thumbnail,
            line1: content.line1,
            line1Color: content.line1Color,
            line2: content.line2,
            line3: content.line3,
            badge: content.badge,
            trailing: content.trailing,
            onPick: content.canPick ? {
                editorFocused = false
                picker = resolver.pickerTarget(for: entry)
            } : nil
        )
    }

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

// MARK: - 分 P 选择

/// 单 P 视频直接入队；多 P 才弹这个让用户勾。
/// 顶上标题统一「选择视频」，真正的片名放列表顶上那行小字里。
/// 这儿不显示封面 —— 都是同一个视频的分 P，封面全一样，摆了也是白占地方。
struct PagePickerSheet: View {

    let target: ParsedTarget
    var kind: DownloadKind = .audiovisual
    /// 确认按钮的动词，收藏夹里用「选择」
    var confirmVerb: String = "添加"
    let onConfirm: ([Int]) -> Void

    @EnvironmentObject private var queue: DownloadQueue
    @Environment(\.dismiss) private var dismiss

    @State private var info: VideoInfo?
    @State private var selected: Set<Int> = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("选择视频")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle) { confirm() }
                            .disabled(selected.isEmpty)
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在获取视频信息…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("无法获取视频信息", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if let info {
            List {
                Section {
                    // 全选：勾上是全选，再点一下全部取消
                    SelectAllRow(state: allState) { toggleAll() }

                    ForEach(info.pages) { page in
                        Button {
                            toggle(page.page)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(page.page) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(page.page) ? Color.accentColor : Color.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("P\(page.page) \(page.title)")
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(durationText(page.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(info.title)
                }
            }
        }
    }

    private var allState: SelectAllRow.State {
        guard let count = info?.pages.count, count > 0, !selected.isEmpty else { return .none }
        return selected.count == count ? .all : .partial
    }

    /// 全勾上了就全取消，否则（空着或只勾了一部分）一律全选
    private func toggleAll() {
        guard let info else { return }
        if selected.count == info.pages.count {
            selected.removeAll()
        } else {
            selected = Set(info.pages.map(\.page))
        }
    }

    private var confirmTitle: String {
        selected.isEmpty ? confirmVerb : "\(confirmVerb) \(selected.count) 个"
    }

    private func toggle(_ page: Int) {
        if selected.contains(page) {
            selected.remove(page)
        } else {
            selected.insert(page)
        }
    }

    private func confirm() {
        onConfirm(selected.sorted())
        dismiss()
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func load() async {
        do {
            let info = try await queue.videoInfo(for: target.ref)

            guard info.isMultiPage else {
                // 单 P 没什么好选的，直接入队
                onConfirm([1])
                dismiss()
                return
            }

            self.info = info
            // 链接里写死了 ?p= 就先只勾那一 P（用户明确点过名），
            // 其它情况默认整季全勾，要少下几个自己去取消
            selected = target.page.map { Set([$0]) } ?? Set(info.pages.map(\.page))
            isLoading = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }
}
