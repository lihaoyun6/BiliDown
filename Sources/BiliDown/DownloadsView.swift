import SwiftUI
import UIKit
import BiliCore
import BiliKit
import BiliUI

struct DownloadsView: View {

    @EnvironmentObject private var queue: DownloadQueue
    @State private var isAdding = false
    @State private var showingClearConfirm = false
    /// 点失败的任务时弹出来看完整报错
    @State private var failedJob: DownloadJob?
    /// 点正在跑的任务时先问一句要不要停
    @State private var stoppingJob: DownloadJob?
    @State private var showingStopAllConfirm = false
    /// 垃圾桶那个按钮：连正在下的也一起清掉，得问一句
    @State private var showingClearAllConfirm = false
    /// 底排那个「读取剪贴板」读出来的条目。非 nil 就把添加页开成
    /// 「内容已经定死」那种 —— 跟自动检测剪贴板那条路进的是同一扇门。
    @State private var clipboardEntries: ClipEntries?
    @State private var hud: HUD?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("下载")
                // 控制面板浮在标签栏上方，用 safeAreaInset 而不是 overlay：
                // 列表自己会为了它留出底部空间，最后一行不会被压在下面。
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controlBar
                }
                .sheet(isPresented: $isAdding) {
                    AddTargetsSheet()
                }
                // 从剪贴板直接读进来的。跟 `isAdding` 那条分开两个 sheet：
                // 这个带着内容开（添加页不摆输入框），那个空着开让用户自己填。
                .sheet(item: $clipboardEntries) { clip in
                    AddTargetsSheet(initialEntries: clip.entries)
                }
                // 不要标题：这一句本身就是全部内容，上面再顶一行「清空列队」
                // 只是把同一句话说两遍
                .confirmationDialog("", isPresented: $showingClearAllConfirm, titleVisibility: .hidden) {
                    Button("清空列队", role: .destructive) { clearAll() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清除所有任务，包括尚未下载完的")
                }
                .confirmationDialog("", isPresented: $showingClearConfirm, titleVisibility: .hidden) {
                    Button("清理列队", role: .destructive) { cleanFinished() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清理列队中已完成的任务")
                }
                .confirmationDialog("停止全部任务", isPresented: $showingStopAllConfirm, titleVisibility: .visible) {
                    Button("全部停止", role: .destructive) { stopAll() }
                    Button("取消", role: .cancel) {}
                } message: {
                    // 跟单条停止一样，停下的任务进度会清零，下去之前先说一声
                    Text("停止任务后下载进度将丢失")
                }
                .alert("下载失败", isPresented: failedAlertBinding) {
                    Button("好", role: .cancel) { failedJob = nil }
                    Button("复制报告") { copyReport() }
                } message: {
                    Text(failureMessage)
                }
                .alert("停止下载", isPresented: stopAlertBinding) {
                    Button("好", role: .destructive) { confirmStop() }
                    Button("不了", role: .cancel) { stoppingJob = nil }
                } message: {
                    Text("停止任务后下载进度将丢失")
                }
                .hud($hud)
        }
    }

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty {
            // 不摆「添加任务」按钮：那会让人以为添加入口只在这儿，
            // 其实常驻的加号就在下面那排里。
            //
            // 也不摆手指箭头了。底排是六个格子，正中间落在第 3、4 颗之间，
            // 加号是第 4 颗 —— 天生偏右半个格距，怎么摆都指不准那颗。
            // 与其摆一根差半个格子的手指（看着像坏了），不如把话说清楚：
            // 名字那么具体，用户低头一看就找着了，本来也用不着指。
            ContentUnavailableView {
                Label("没有下载任务", systemImage: "arrow.down.circle")
            } description: {
                Text("点击下方 + 添加任务")
            }
            // 跟列表页的成组底色对齐，不然这一页是纯白的
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        } else {
            List {
                ForEach(queue.jobs) { job in
                    JobRowView(job: job)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            switch job.state {
                            case .failed:
                                // 点开看完整报错
                                failedJob = job
                            case .queued, .resolving, .downloading, .remuxing, .saving:
                                // 停止会把进度丢干净，先问一句
                                stoppingJob = job
                            case .stopped:
                                // 停下来的再点一下就是重下
                                queue.retry(job)
                            case .finished:
                                break
                            }
                        }
                        // 让分隔线从行首拉通，别缩到文字那儿去
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // 按钮只留图标，不写字
                            Button(role: .destructive) {
                                queue.remove(job)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("删除")

                            if job.state == .stopped || job.state.isFailed {
                                Button {
                                    queue.retry(job)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .tint(.orange)
                                .accessibilityLabel("重试")
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - 底部控制条

    /// 悬在标签栏上方的控制面板，一排按钮，圆角、不贴边。
    ///
    /// 所有按钮都集中在这儿，顶栏一个不留 —— 大屏上顶栏那两个角是拇指的禁区，
    /// 而底部这一片单手就够得着。
    ///
    /// 做成脱离底边的浮岛而不是一条通铺：通铺看着像页脚，跟列表是一体的；
    /// 浮岛是「压在内容上的工具」，跟内容分得开。四周留白也是给拇指留的，
    /// 贴着边反而不好按。
    private var controlBar: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        return VStack(spacing: 0) {
            // 图标统一用 *.circle.fill 这一套，大小粗细天然一致，
            // 不用再给哪个单独的符号调字号。
            // 顺序：垃圾桶（清空列队）/ 清理列队 / 读取剪贴板 / 加号 / 开始 / 停止 ——
            // 破坏性的两个摆在左边，往里加东西的两个（剪贴板、加号）挨在一起，
            // 管「跑不跑」的两个在右。
            //
            // 每个按钮给一个固定宽度，中间塞可伸缩的 Spacer 来分剩下的宽度：
            // 以前是「五个格子等分撑满一行」，格子一宽，两头的图标就被推到
            // 离面板边缘很远的地方，看着面板内边距特别空。
            // 现在宽度由图标自己说了算，多出来的宽度全进到图标之间，
            // 面板左右两端就收到图标边上来了。
            HStack(spacing: 0) {
                barButton("trash.circle.fill", label: "清空列队", tint: .red,
                          isEnabled: !queue.jobs.isEmpty) {
                    showingClearAllConfirm = true
                }
                Spacer(minLength: 10)
                barButton("tornado.circle.fill", label: "清理列队",
                          isEnabled: queue.hasFinished) {
                    showingClearConfirm = true
                }
                Spacer(minLength: 10)
                barButton("document.circle.fill", label: "读取剪贴板") {
                    pasteFromClipboard()
                }
                Spacer(minLength: 10)
                barButton("plus.circle.fill", label: "添加任务", weight: .semibold) {
                    isAdding = true
                }
                Spacer(minLength: 10)
                barButton("play.circle.fill", label: "全部开始下载",
                          isEnabled: queue.hasResumable) {
                    startAll()
                }
                Spacer(minLength: 10)
                barButton("stop.circle.fill", label: "全部停止",
                          isEnabled: queue.hasStoppable) {
                    showingStopAllConfirm = true
                }
            }
            // 两端的内边距：图标离面板边缘就靠它（另外每格自己还让出 11）。
            // 往外撑一些，面板不至于看着把图标箍得太紧。
            .padding(.horizontal, 12)
            // 上限 = 两端内边距 + 六个图标 + 中间那五段间距，
            // 跟上面那个 padding 是一对：padding 决定两端，这里决定中间。
            // 面板宽度就定在 368 不动：上面那个 padding 收到 12 让出来的宽度
            // 全进中间那五段，两端各收 4，面板整体还是撑开的样子。
            // minLength 那 10pt 是给窄屏兜底的，真机上到不了那么窄
            // （六格满打满算 6×44 + 5×10 + 24 = 338，还在 368 里头）。
            .frame(maxWidth: 368)
            .frame(height: 52)
        }
        // 面板上不挂任何进度、状态之类的东西 —— 它就只是按钮组。
        // 谁下到哪儿了，列表里那条自己会写。
        .background(.regularMaterial, in: shape)
        .clipShape(shape)
        // 浮岛得有边有影才浮得起来：同色系的面板压在浅色列表上，
        // 光靠材质分不出边界。
        .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        // 离屏幕两边和底边的那圈留白：不能没有（贴边就不「浮」了），
        // 也不能太宽，不然面板缩在中间显得小气。
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 控制面板上的一个格子。字号统一 22 —— 比导航栏那套 17pt 明显大一圈：
    /// 这是常驻在底部、要拿拇指去够的一排，够大才好按。
    /// 权重只有加号需要单独调（它的十字是描边画出来的，
    /// 跟周围几个实心方块比会显轻，得加粗一档）。
    ///
    /// 不做状态隐现（按钮忽有忽无，用户每次都得先确认它在不在），
    /// 而是没有对应的事可做时灰掉：位置固定，还能一眼看出「现在没什么可停的」。
    /// 加号永远亮着 —— 它是这排里唯一的入口，别的都灰了它也得好使。
    private func barButton(
        _ symbol: String,
        label: String,
        weight: Font.Weight = .regular,
        tint: Color = .accentColor,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: weight))
                // 灰掉的时候一律走灰，不能还留着本色 ——
                // 红色的垃圾桶暗一档看着依旧像能按，还以为是它自己坏了。
                .foregroundStyle(isEnabled ? tint : Color.secondary)
                // 44 见方：图标自己占 22，两边各留 11 当手指的余量，
                // 也正好是苹果说的最小可点尺寸
                .frame(width: 44)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

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

    private var stopAlertBinding: Binding<Bool> {
        Binding(
            get: { stoppingJob != nil },
            set: { if !$0 { stoppingJob = nil } }
        )
    }

    // MARK: - 读取剪贴板

    /// 一次剪贴板检测用的东西。用 id 驱动 `sheet(item:)`。
    private struct ClipEntries: Identifiable {
        let id = UUID()
        let entries: [InputEntry]
    }

    /// 点底排那个剪贴板图标：直接读一次剪贴板，认出来的链接摆进添加页。
    ///
    /// 跟 mac 版那边（右键菜单 / 顶栏的「读取剪贴板」）逐句一样，
    /// 连「认不出就说一声」的两句提示都一样 —— 点下去没反应，用户只会以为坏了。
    ///
    /// 这一下会弹系统的「允许粘贴」。这是用户自己点的，正是该弹的时候；
    /// 设置里那个默认关掉的「自动检测剪贴板」防的是**不请自来**地读。
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            hud = HUD(icon: "doc.on.clipboard", text: "剪贴板里没有文字")
            return
        }

        let entries = ShareLinkParser.parseEntries(text)
        guard !entries.isEmpty else {
            hud = HUD(icon: "questionmark.circle.fill", text: "剪贴板中没有可下载的内容")
            return
        }

        clipboardEntries = ClipEntries(entries: entries)
    }

    private func confirmStop() {
        if let job = stoppingJob { queue.stop(job) }
        stoppingJob = nil
    }

    private func stopAll() {
        let stopped = queue.stopAll()
        hud = HUD(icon: "stop.circle.fill", text: "已停止 \(stopped) 个任务")
    }

    private func startAll() {
        let started = queue.startAll()
        hud = HUD(icon: "play.circle.fill", text: "已开始 \(started) 个任务")
    }

    private func clearAll() {
        queue.removeAll()
        hud = HUD(icon: "trash.fill", text: "已清空列队")
    }

    private func cleanFinished() {
        let before = queue.jobs.count
        queue.removeFinished()
        hud = HUD(icon: "xmark.bin.fill", text: "已清理 \(before - queue.jobs.count) 个任务")
    }

    private func copyReport() {
        guard let job = failedJob else { return }
        UIPasteboard.general.string = FailureReport.json(for: job)
        failedJob = nil
        hud = HUD(icon: "doc.on.doc.fill", text: "已复制报告")
    }

}

#Preview("空") {
    DownloadsView()
        .environmentObject(DownloadQueue(settings: AppSettings()))
        .environmentObject(AppSettings())
}
