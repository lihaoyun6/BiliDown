import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 队列那四个批量操作，外加「添加任务」。
///
/// 下载页上两处要触发同一套：右上角那排按钮，和列表空白处的右键菜单。
/// 动作只写这一份。
///
/// 状态放在视图外面，是因为那两处要摆出来的东西（确认框、提示、添加页）
/// 挂在 `MacRootView` 上 —— 见那边的说明。
@MainActor
final class MacQueueActions: ObservableObject {

    /// 等用户点一下确认的操作。页面弹完框把它清掉。
    @Published var pending: Confirmation?
    /// 飘一下的提示。整个窗口共用这一个。
    @Published var hud: HUD?
    /// 添加任务那张 sheet 要装的东西。空着开 = 用户自己填。
    @Published var addSheet: AddSheet?

    /// 添加页那张 sheet 装的东西。
    /// 点加号是空着开（用户自己填），剪贴板或链接带内容进来是带着认出来的条目开 ——
    /// 用两个 Bool 会有一个「先设内容再翻开关」的中间态，合成一个可选项省掉。
    struct AddSheet: Identifiable {
        let id = UUID()
        var entries: [InputEntry] = []
    }

    /// 四个要问一句的操作。文案跟 iOS 版逐字一致 ——
    /// 同一件事在两个平台上说法不一样，看着像两个功能。
    enum Confirmation: Identifiable {
        case clearAll
        case cleanFinished
        case stopAll
        /// 停单条。跟 stopAll 分开一个 case，是因为按钮上的字不一样：
        /// 「全部停止」压在一个任务上，用户会以为点下去所有任务都要停。
        case stopOne(DownloadJob)

        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .cleanFinished: return "cleanFinished"
            case .stopAll: return "stopAll"
            case .stopOne(let job): return "stopOne-\(job.id)"
            }
        }

        var title: String {
            switch self {
            case .clearAll: return "清空列队"
            case .cleanFinished: return "清理列队"
            case .stopAll: return "停止全部任务"
            case .stopOne: return "停止下载"
            }
        }

        var confirmTitle: String {
            switch self {
            case .clearAll: return "清空列队"
            case .cleanFinished: return "清理列队"
            case .stopAll: return "全部停止"
            case .stopOne: return "停止"
            }
        }

        var message: String {
            switch self {
            case .clearAll: return "清除所有任务，包括尚未下载完的"
            case .cleanFinished: return "清理列队中已完成的任务"
            case .stopAll, .stopOne: return "停止任务后下载进度将丢失"
            }
        }
    }

    // MARK: - 动作

    /// 开添加页。默认空着开，让用户自己填。
    func addTask(entries: [InputEntry] = []) {
        addSheet = AddSheet(entries: entries)
    }

    /// 全部开始。这个不用问一句：它只是让停着的跑起来，没什么可丢的。
    func startAll(_ queue: DownloadQueue) {
        let started = queue.startAll()
        hud = HUD(icon: "play.circle.fill", text: "已开始 \(started) 个任务")
    }

    /// 下面三个都只是「要问一句」—— 真正动手在 `perform` 里，
    /// 等用户在确认框上点了那个按钮。
    func stopAll() { pending = .stopAll }
    func cleanFinished() { pending = .cleanFinished }
    func clearAll() { pending = .clearAll }

    /// 用户在确认框上点了确认之后跑的。
    func perform(_ choice: Confirmation, queue: DownloadQueue) {
        switch choice {
        case .clearAll:
            queue.removeAll()
            hud = HUD(icon: "trash.fill", text: "已清空列队")

        case .cleanFinished:
            let before = queue.jobs.count
            queue.removeFinished()
            // 跟顶栏那颗「清理列队」是同一颗龙卷风（都是不带圈的）。
            // 旁边「已清空列队」的垃圾桶同理。
            hud = HUD(icon: "tornado", text: "已清理 \(before - queue.jobs.count) 个任务")

        case .stopAll:
            let stopped = queue.stopAll()
            hud = HUD(icon: "stop.circle.fill", text: "已停止 \(stopped) 个任务")

        case .stopOne(let job):
            queue.stop(job)
        }
    }
}
