import SwiftUI
import BiliCore
import BiliKit
import UIKit

/// 打开 App 时顺手看一眼剪贴板。
///
/// 设置里那个「自动检测剪贴板」打开后才干活（默认关）：读剪贴板会弹系统的
/// 「允许粘贴」，没经用户点头不该弹那一下，所以这个功能得用户自己去开。
/// 读到的内容能用 ShareLinkParser 认出来（b23.tv / BV / av / UP 主 / 合集），
/// 就直接进「添加任务」—— 那一页不带输入框，只剩下载类型和解析结果。
///
/// 被 URL scheme 唤起的时候跳过：链接已经在手上了（走 SharedLinkReceiver），
/// 这时候再去翻剪贴板不光多余，还会平白弹一次粘贴提示。
struct ClipboardDetector: ViewModifier {

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    /// 认出来的内容。用它驱动 sheet，非 nil 就是有东西要问用户。
    @State private var clip: Clip?
    /// 上次读到的原文。切出去再切回来，剪贴板里那串还在，
    /// 不能每次都问一遍 —— 认过的就不再认。
    @State private var lastSeen: String?
    /// 用户这次点了「不允许粘贴」。
    ///
    /// 系统**不记**这个拒绝：下回再读还会再弹一次。更麻烦的是那个系统弹窗
    /// 自己会让 scenePhase 抖一下（inactive → active），于是「拒绝 → 切回前台
    /// → 再读 → 又弹」能连着来好几轮。所以得我们自己记住这一次的答复：
    /// 这趟 App 里不再读剪贴板了。
    @State private var isDenied = false
    @State private var pending: Task<Void, Never>?

    /// 一次剪贴板检测。用 id 驱动 sheet(item:)。
    private struct Clip: Identifiable {
        let id = UUID()
        let entries: [InputEntry]
    }

    func body(content: Content) -> some View {
        content
            .task { schedule() }
            .onChangeCompat(of: scenePhase) { phase in
                if phase == .active { schedule() }
            }
            // 注意这儿**不会**因为开关被拨动就去读剪贴板：刚把它打开不该立刻
            // 翻一遍 —— 用户要的是省事，不是被自己的设置项当场吓一跳。
            // 这里只把上一次的「不允许」清掉：自己去关一下再开，那就是有话要说，
            // 下次切回前台重新试一次。
            .onChangeCompat(of: settings.autoDetectClipboard) { _ in
                isDenied = false
            }
            .sheet(item: $clip) { clip in
                AddTargetsSheet(initialEntries: clip.entries)
            }
            .onDisappear { pending?.cancel() }
    }

    /// 等一小会儿再读。被 URL scheme 唤起时，链接是这个时候前后递进来的，
    /// 立刻读就抢在它前面了 —— 让一步，先看看有没有链接进来。
    private func schedule() {
        guard settings.autoDetectClipboard else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            check()
        }
    }

    private func check() {
        guard settings.autoDetectClipboard else { return }
        // 这一趟已经问过、被拒了，别再问第二遍
        guard !isDenied else { return }
        // 这一下是被链接唤起来的（或者刚被唤起过）：链接我们已经拿到了
        guard !URLOpenMarker.wasRecent() else { return }
        // 已经弹着一个了，别再往上叠
        guard clip == nil else { return }

        // hasStrings 不读内容、不弹提示，先拿它挡一道空剪贴板
        guard UIPasteboard.general.hasStrings else { return }

        // 剪贴板里明明有字，却读不出来 —— 只剩一种可能：用户刚点了
        // 「不允许粘贴」。那就到此为止，这一趟不再碰剪贴板了。
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            isDenied = true
            return
        }
        guard text != lastSeen else { return }
        lastSeen = text

        let entries = ShareLinkParser.parseEntries(text)
        guard !entries.isEmpty else { return }
        clip = Clip(entries: entries)
    }
}

/// 「刚刚是被 URL scheme 唤起的」这件事的记号。
/// 分享链接那条路（SharedLinkReceiver）进门时记一笔，剪贴板这边看见了就让开。
enum URLOpenMarker {

    private static var lastOpen: Date?

    static func note() {
        lastOpen = Date()
    }

    /// 最近这几秒里被链接唤起过吗。窗口留得比上面那个延迟宽一些，
    /// 免得两件事的先后顺序稍微一颠倒就漏判。
    static func wasRecent(within seconds: TimeInterval = 3) -> Bool {
        guard let lastOpen else { return false }
        return Date().timeIntervalSince(lastOpen) < seconds
    }
}

extension View {

    /// 挂在根视图上，按设置决定要不要自动看剪贴板。
    func detectsClipboard() -> some View {
        modifier(ClipboardDetector())
    }
}
