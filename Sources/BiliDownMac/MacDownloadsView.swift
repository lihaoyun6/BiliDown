import SwiftUI
import AppKit
import BiliCore
import BiliKit
import BiliUI

/// 下载队列。列表本身跟 iOS 版共用 JobRowView，差别只在壳：
/// iOS 是底部一排拇指够得着的浮岛按钮，mac 是顶栏一排工具栏按钮 ——
/// 鼠标在哪儿都够得着，没必要占一块常驻的版面。
struct MacDownloadsView: View {

    @EnvironmentObject private var queue: DownloadQueue
    /// 那四个批量操作和「添加任务」。动作本身、确认框要问的话、执行完的提示
    /// 都在它那儿 —— 右上角那排按钮和空白处的右键菜单要用同一份，不能各写一套。
    @EnvironmentObject private var actions: MacQueueActions

    /// 点失败的任务时弹出来看完整报错。这个是这一页自己的事。
    @State private var failedJob: DownloadJob?

    /// **不在这儿分叉。**
    ///
    /// 原来是 `if jobs.isEmpty { emptyState } else { list }` —— 空和非空是两棵
    /// 不同的子树，清空队列那一刻 `List` 被销毁、`emptyState` 顶上来，整棵子树换了根。
    /// 顶栏那一趟跟着重建，AppKit 就把右上角的加号弄丢了，得切一下栏目才回来。
    ///
    /// 现在列表永远都在，空态是它里面的一行 —— 跟 MacLibraryList 一个写法
    /// （那边为「滚动位置被重置」也是这么改的）。根不动，顶栏就不动。
    var body: some View {
        list
            .navigationTitle("下载")
            .toolbar { toolbarContent }
        // 确认框、提示、添加页那张 sheet 都在 MacRootView 上 ——
        // 它们是跟菜单栏共用的，得挂在哪个栏目都活着的视图上。
        .alert("下载失败", isPresented: failedAlertBinding) {
            Button("好", role: .cancel) { failedJob = nil }
            Button("复制报告") { copyReport() }
        } message: {
            Text(failureMessage)
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(queue.jobs) { job in
                JobRowView(job: job)
                    // 上下各垫一点：mac 的 List 行是贴着的，跟收藏夹 / 合集、
                    // 添加任务那几页取的是同一个数（见 `ListRowMetrics`）。
                    // 这一页也是视频列表，队列挤在一起比哪儿都难看 ——
                    // 那三行字、那根进度条离上下两条线只剩一两个点。
                    .padding(.vertical, ListRowMetrics.macRowVerticalPadding)
                    .contentShape(Rectangle())
                    .onTapGesture { tap(job) }
                    // iOS 那边是左滑出按钮，mac 上是右键菜单 —— 各按各的习惯来
                    .contextMenu {
                        if job.state == .stopped || job.state.isFailed {
                            Button("重试") { queue.retry(job) }
                        }
                        if job.state.isActive {
                            Button("停止") { queue.stop(job) }
                        }
                        Divider()
                        Button("删除", role: .destructive) { queue.remove(job) }
                    }
            }
        }
        .listStyle(.inset)
        // 列表底下那块空白也能右键。行自己的右键菜单是内层，
        // 比外层优先，所以贴着某一行点还是出那一行的菜单。
        .contextMenu { blankAreaMenu }
        // 空态浮在列表**上面**，垂直居中。两条路都不走：
        // 塞进列表当一行只能贴着顶上；在外面 `if/else` 换根会把顶栏那趟重建搞坏
        // （加号就是这么丢的）。这一层永远都在，空的时候才显形。
        .overlay { emptyState }
    }

    /// 空队列时浮在列表中间的那块提示。见 `list` 上头那段。
    ///
    /// 不摆一个大按钮：常驻的加号就在顶栏，再摆一个只会让人以为入口只在这儿。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("没有下载任务")
                .font(Typography.placeholderTitle)
            Text("点击右上角 + 添加任务")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 有任务时收起来。**不收结构、只收透明度** —— 让它一直挂在那儿，
        // 空/非空之间就没有任何东西被建出来或拆掉，顶栏那趟重建也就不会发生。
        .opacity(queue.jobs.isEmpty ? 1 : 0)
        // 纯装饰，不接鼠标：空白处的右键菜单归外层 `List` 那个管，
        // 这一层要是接了，点中间那几行字就会把菜单挡掉。
        .allowsHitTesting(false)
    }

    /// 空白处那个右键菜单。顺序是「新开一件事 → 分隔 → 从剪贴板拿 →
    /// 分隔 → 对整条队列动手」，越往下越重，最后一条是清空，画成红的。
    ///
    /// 同样这几个操作在右上角那排按钮里也有一份 —— 列表一满就没有空白可点，
    /// 这个菜单根本出不来。
    @ViewBuilder
    private var blankAreaMenu: some View {
        Button("添加任务") { actions.addTask() }

        Divider()

        // 叫「读取剪贴板」而不是「粘贴」：mac 上的「粘贴」默认指把剪贴板内容
        // 塞进当前文档的插入点，这里其实是「先把里面认出来的链接读出来给你过一眼」。
        Button("读取剪贴板") { pasteFromClipboard() }

        Divider()

        Button("全部开始") { actions.startAll(queue) }
            .disabled(!queue.hasResumable)

        Button("全部停止") { actions.stopAll() }
            .disabled(!queue.hasStoppable)

        Button("清理列队") { actions.cleanFinished() }
            .disabled(!queue.hasFinished)

        // 红的。role: .destructive 在 mac 的右键菜单里只是语义上的标记，
        // 颜色得自己上 —— 光传 role，画出来跟上面几条一模一样。
        Button(role: .destructive) {
            actions.clearAll()
        } label: {
            Text("清空列队").foregroundStyle(.red)
        }
        .disabled(queue.jobs.isEmpty)
    }

    /// 从剪贴板粘一条进来。认不出东西就说一声，别默默什么都没发生 ——
    /// 右键菜单点完没反应，用户只会以为这个功能坏了。
    private func pasteFromClipboard() {
        guard let text = MacPasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            actions.hud = HUD(icon: "doc.on.clipboard", text: "剪贴板里没有文字")
            return
        }

        let entries = MacLinkIntake.entries(from: text)
        guard !entries.isEmpty else {
            actions.hud = HUD(icon: "questionmark.circle.fill", text: "剪贴板中没有可下载的内容")
            return
        }

        actions.addTask(entries: entries)
    }

    private func tap(_ job: DownloadJob) {
        switch job.state {
        case .failed:
            // 点开看完整报错
            failedJob = job
        case .stopped:
            // 停下来的再点一下就是重下
            queue.retry(job)
        case .finished:
            break
        default:
            // 正在跑的点了就停下 —— 进度会丢，先问一句
            actions.pending = .stopOne(job)
        }
    }

    // MARK: - 顶栏

    /// 右上角那一排：清空 / 清理 / 开始 / 停止 / 读取剪贴板 / 添加，从左到右照这个次序摆。
    ///
    /// 前四个**必须**在这儿有一份。右键菜单那份只有在列表**空白处**才出得来，
    /// 而列表一满就一点空白都不剩 —— 偏偏那正是最想用它们的时候。
    /// 「读取剪贴板」同理：它原来也只有右键菜单里那一条，列表满了就不好找，
    /// 摆到这儿来正好贴在加号左边（都是「往里加东西」，一回事）。
    ///
    /// 一整组，中间两道竖线，两两一撮，从左到右：
    ///
    ///     清空 · 清理 ｜ 开始 · 停止 ｜ 读取剪贴板 · 添加
    ///
    /// 一撮是一件事：头两个都是在收拾队列，中间两个管「跑不跑」，
    /// 末两个都是往队列里放东西。
    ///
    /// 之前刻意「一颗按钮一个 ToolbarItem」、不分组也不摆竖线 ——
    /// 那会儿是五颗按钮中间横一道线，把一排切成「两个 + 三个」，
    /// 而那条缝落的地方没有任何意思。现在两两一撮，线正好落在真分界上。
    ///
    /// 得整组套起来，不能一颗一个 ToolbarItem 再往中间插一个：
    /// 整组的时候六颗是挤成一撮的，分开摆就散成六个独立项，中间那两根线
    /// 也就分不出什么来了。
    ///
    /// 缩成一组之后，顶栏里就只有这一个 item 了 —— 原来给每颗钉 id 是为了防
    /// 「切栏目重建时新旧两项对不上号、加号旁边冒出个空的 >>」，现在只有一个，
    /// 对不上号这回事不存在，id 也就跟着去了。
    ///
    /// placement 得写死：`.automatic` 在这套布局里落到哪儿是系统说了算，
    /// 写死 `.primaryAction`（右侧那一片）就不会跟侧边栏那颗开关抢地方。
    ///
    /// 只画图标，不摞文字：文字会和系统给按钮画的那个方框压在一起，
    /// 而 mac 的顶栏本来就是靠图标认的。说不清的在 `.help` 里。
    ///
    /// 图标一套**都是描边的**（`.circle`，不是 `.circle.fill`）：这副顶栏本来就
    /// 是细线稿的路子，实心的圆摆进去一块块发沉。跟着也统一了大小和笔画的粗细 ——
    /// 这几个符号同属一套，天然就一般大，不用再挑哪个单独调字号。
    /// 只有 `tornado.circle`（清理列队）是另挑的：那个动作的「扫干净」比
    /// `xmark.bin` 更贴。加号本来就没有实心版。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            toolbarButton("清空列队", systemImage: "trash.circle") {
                actions.clearAll()
            }
            .disabled(queue.jobs.isEmpty)
            .help("清除所有任务，包括尚未下载完的")

            toolbarButton("清理列队", systemImage: "tornado.circle") {
                actions.cleanFinished()
            }
            .disabled(!queue.hasFinished)
            .help("清理列队中已完成的任务")

            toolbarSeparator

            toolbarButton("全部开始", systemImage: "play.circle") {
                actions.startAll(queue)
            }
            .disabled(!queue.hasResumable)
            .help("全部开始下载")

            toolbarButton("全部停止", systemImage: "stop.circle") {
                actions.stopAll()
            }
            .disabled(!queue.hasStoppable)
            .help("全部停止")

            toolbarSeparator

            // 两张纸（`doc.on.doc`）：把剪贴板里的东西读进来，正是这个动作。
            //
            // 名字一律用老的 `doc*`，不用新的 `document*`：两套画出来一模一样
            // （逐像素比过，零差异），但 `document.on.document` 是 SF Symbols 6
            // 改名后重新登记的新名字，要 macOS 15.0；`doc.on.doc` 从 10.15 就有。
            // 下限是 13，所以写老的那个 —— 别看着名字旧就顺手改。
            //
            // 图标自己给（`clipboardIcon`），不写 `systemImage:` —— 它得小一号，
            // 理由在那张图自己头上。
            toolbarButton("读取剪贴板", action: { pasteFromClipboard() }) {
                Self.clipboardIcon
            }
            .help("读取剪贴板里的链接")

            toolbarButton("添加任务", systemImage: "plus") {
                actions.addTask()
            }
            .help("添加任务")
        }
    }

    /// 「读取剪贴板」那颗图标。**自己画一张，比系统画的小一号。**
    ///
    /// 为什么得自己画：顶栏 item 里那颗符号多大，是顶栏按自己那套样式定的 ——
    /// `Label` / `Image` 上写 `.font`、`.imageScale`、`.resizable` 递过去都会被
    /// 盖掉，试过。而 `doc.*` 这一族文档符号的图形天生比旁边那几颗圈高一截：
    /// 同样是顶栏那档点数，圈画出来墨迹 6.5×6.5，它是 6×8 —— 一条线摆下来，
    /// 就它冒头。
    ///
    /// 10.5pt 是量出来的。同一把尺子（顶栏那档字号，墨迹按 1/4 pt 量）下：
    ///
    ///     旁边的圈（trash / play / stop / tornado）  墨迹 13.00×13.00
    ///     doc.on.doc 不改                           墨迹 13×16     ← 高 3pt，就是它冒头的原因
    ///     9.75pt                                    墨迹 10.25×12.25
    ///     10pt                                      墨迹 10.25×12.75
    ///     10.25pt                                   墨迹 10.75×12.75
    ///     10.4 ~ 10.5pt                             墨迹 10.75×13.25
    ///     10.6pt                                    墨迹 11.00×13.25
    ///     10.7 ~ 10.75pt                            墨迹 11.25×13.50  ← 现在这版
    ///     10.8 ~ 11pt                               墨迹 11.25×13.75  ← 比每一颗圈都高，冒头
    ///
    /// **它得跟旁边那几颗圈一般高**，那是这颗按钮唯一的尺子：13.25 对 13.00 已经
    /// 齐平；再往上 13.50 / 13.75，一排圈里就它上下各冒出去一点 —— 正是先前
    /// 要修的那个毛病。所以大小上没有余地，只能贴着 13.00 这一档放。
    ///
    /// 档位是**跳的**，别按 0.1 去推：好几组点数（如 10.4 与 10.5、10.8 与 11）
    /// 画出来一模一样。上面这张表是逐档量出来的，调之前先看它在哪一档。
    ///
    /// **画布必须比墨迹大得多，那一格靠 `.frame` 单独钉住。**
    /// 一开始画布就是 15×15（跟圈那一格一样大），墨迹 13 高只留出 1pt 余量 ——
    /// 顶栏一缩放就顶出去，上下被切了。现在画布 20×20，墨迹只占中间 13.25，
    /// 四周各留 3.375pt：顶栏当它是 15（认 frame）就裁不到东西，当它是 20
    /// （不认 frame）也还是有富余。两种脾气都不会切。
    ///
    /// 画布跟着放宽收紧都行，但**别让它贴边**。
    ///
    /// ### 那一下「一打开是大图标、切个栏目才变小」是怎么回事
    ///
    /// `Text` 里那颗符号的大小，除了 `.font` 还受**环境的 `.imageScale`** 管 ——
    /// 而这个环境是顶栏给的，不是我们给的。顶栏**第一遍**渲染时递过来的环境是
    /// 「大号符号」那一档，画出来墨迹 14.5×15（旁边那几颗圈才 13，所以一眼看着
    /// 就是「原来那个大图标」）；切一下栏目，item 被拆掉重建，第二遍环境是正常
    /// 的，才变回 11.5×14。**画的点数一点没变，是环境在变。**
    ///
    /// 所以下面 `.environment(\.imageScale, .medium)` 那句是必须的：把它钉死，
    /// 画出来的就永远是同一张，顶栏哪一遍来都一样。去掉它这个毛病就回来。
    ///
    /// ### 调大小就改下面这一个数
    private static let clipboardPointSize: CGFloat = 12.5

    private static var clipboardIcon: some View {
        let box = CGSize(width: 20, height: 20)
        return Image(size: box) { context in
            // 加粗走 `weight`，别动 `size`：字重只让笔画变厚，外形几乎不动
            // （量过：regular 11.00×13.25 / 墨量 869 → semibold 11.25×13.50 / 1123，
            // 只差 0.25pt，而调 `size` 是整块跟着变）。
            let text = context.resolve(
                Text(Image(systemName: "doc.on.doc"))
                    .font(.system(size: clipboardPointSize, weight: .semibold))
            )
            // 文字按 rect 左上角排，不缩不放 —— 想居中得先量出来再自己算那块 rect
            let measured = text.measure(in: CGSize(width: box.width * 4, height: box.height * 4))
            context.draw(text, in: CGRect(
                x: (box.width - measured.width) / 2,
                y: (box.height - measured.height) / 2,
                width: measured.width,
                height: measured.height
            ))
        }
        // **钉死符号那一档。** 缺了这句，「打开是大图标、切个栏目才变小」就回来 ——
        // 原因见上面那段（顶栏第一遍递进来的 .imageScale 是大的）。
        // 它得挨着 `Image` 里面那层，不能被外面的环境压过去。
        .environment(\.imageScale, .medium)
        // 画布 20，这一格按 15 报给顶栏 —— 跟旁边那几颗圈占的地方一样大，
        // 多出来的 5 是透明的余量（见上面那段）。
        .frame(width: 15, height: 15)
    }

    /// 两撮按钮之间那根竖线。
    ///
    /// 不用 `Divider()`：在这个位置它被画成了一条**横**线。顶栏那一层是 AppKit
    /// 在管，SwiftUI 递过去的东西会落到它的容器里，`Divider` 靠容器方向推出来的
    /// 「我该横还是该竖」在这儿推错了 —— 换成一根宽 1 的 `Rectangle`，
    /// 横竖由自己写死的宽高说了算，不再问任何人。
    private var toolbarSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 16)
            // 两边的呼吸：整组的间距本来就挤，不额外让一点，线就贴着图标了
            .padding(.horizontal, 4)
    }

    /// 图标由调用方给的那一版。只给「读取剪贴板」用 —— 它那颗得自己画（见
    /// `clipboardIcon`）。其余五颗继续走下面那条，系统怎么画就怎么画，
    /// 别为了统一把它们的渲染路子也换掉。
    private func toolbarButton<Icon: View>(
        _ title: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            icon()
                // `.labelStyle(.iconOnly)` 那份的等价物：图标没有文字，
                // 名字只能这么挂上去，读屏和悬停提示都靠它
                .accessibilityLabel(title)
        }
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }

    // MARK: - 弹窗绑定

    private var failedAlertBinding: Binding<Bool> {
        Binding(
            get: { failedJob != nil },
            set: { if !$0 { failedJob = nil } }
        )
    }

    private var failureMessage: String {
        if case .failed(let message) = failedJob?.state { return message }
        return ""
    }

    // MARK: - 动作

    private func copyReport() {
        guard let job = failedJob else { return }
        MacPasteboard.copy(FailureReport.json(for: job))
        failedJob = nil
        actions.hud = HUD(icon: "doc.on.doc.fill", text: "已复制报告")
    }
}
