import SwiftUI
import AppKit
import BiliKit
import BiliUI

/// macOS 版。跟 iOS 版共用 BiliCore / BiliKit / BiliUI 三层，
/// 界面这套是重写的 —— 不是把 iOS 那份原样编过来。
@main
struct BiliDownMacApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var queue: DownloadQueue
    @StateObject private var account = AccountStore()
    @StateObject private var navigator = MacNavigator()
    /// 队列那四个批量操作 + 添加页。视图和菜单栏共用同一个 ——
    /// 菜单栏点在哪儿、当前停在哪一栏，用的都得是同一份状态。
    @StateObject private var queueActions = MacQueueActions()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _queue = StateObject(wrappedValue: DownloadQueue(settings: settings))
    }

    var body: some Scene {
        // 用 `Window` 而不是 `WindowGroup`，这是「菜单栏那条设置…」要的行为分水岭：
        // WindowGroup 的 openWindow(id:) 每调一次就**再开一个**窗口，
        // 所以主窗口开着的时候点设置，会又蹦出一个新的；
        // `Window` 是单例场景，openWindow(id:) 会把已经开着的那一个提到前面来，
        // 没有才新建。正好是要的：有主窗口就在主窗口里转设置，没有才弹一个。
        Window("BiliDown", id: MacNavigator.mainWindowID) {
            MacRootView()
                .environmentObject(settings)
                .environmentObject(queue)
                .environmentObject(account)
                .environmentObject(navigator)
                .environmentObject(queueActions)
                .frame(minWidth: 880, minHeight: 540)
        }
        .commands {
            MacCommands(navigator: navigator)
        }

        // 没有 Settings 场景了。系统那个默认行为是「另开一个小窗口」，
        // 而设置本来就是主窗口里的一个栏目 —— 开着主窗口还要再弹一个，
        // 关掉其中一个还各关各的。⌘, 改由 MacCommands 接管，切栏目。
    }
}

/// App 自己那几句介绍性的字。
///
/// 现在只有一句「这是什么」。它要出现在**两个**「关于」里：系统那个
/// 「关于 BiliDown」面板（下面 `MacCommands` 把它当 credits 递进去），
/// 和设置页「关于程序」那一组。写两份的话，改一处忘一处，
/// 两个「关于」就开始说不一样的话了。
enum MacAppInfo {

    /// 一句话说明这是个什么 App。摆在大名底下的那行。
    static let tagline = "B站视频下载工具"
}

/// 主窗口当前停在哪个栏目。
///
/// 单独抽成一个对象，是因为菜单栏那条「设置…」得能改它 ——
/// 这个动作发生在视图之外，够不着 MacRootView 的 @State。
@MainActor
final class MacNavigator: ObservableObject {

    /// 主窗口的 id。菜单栏那条命令靠它把窗口捞回来。
    static let mainWindowID = "main"

    @Published var section: MacRootView.Section = .downloads

    /// 收藏 / 合集各自点开到了哪一层。没点开就是没有这一项。
    ///
    /// 这份状态**必须存在视图外面**：切栏目时 detail 整个被重建
    /// （那边挂着 `.id(section)`），视图里的 @State 跟着一起没，
    /// 于是从收藏里点进一个夹子、去下载页转一圈再回来，
    /// 人就站在列表根上了 —— 而这本来该是「回到刚才那个夹子里」。
    ///
    /// 按 `kind` 分开存：收藏和合集是同一个视图，只差一个 kind，
    /// 混在一个变量里就会出现「在合集里点开的东西跑到收藏里去了」。
    @Published var openedLibrary: [LibraryListKind: LibrarySource] = [:]
}

/// 菜单栏。整组整组地覆盖系统默认那套 —— 这个 App 不是文档型应用，
/// 默认那些「新建 / 撤销」摆着只会让人以为有对应功能。
///
/// 「显示 > 隐藏侧边栏」**留着**。之前拿 `CommandGroup(replacing: .sidebar) {}`
/// 整组删过，想让侧边栏藏不掉 —— 那条路连同顶栏那颗开关一起放弃了：
/// 藏不干净，反倒让「显示」菜单里少一条，看着像坏了。
struct MacCommands: Commands {

    let navigator: MacNavigator

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .undoRedo) {}

        // 「BiliDown > 关于 BiliDown」。系统默认那条面板里只有三行：
        // 名字、版本、版权 —— 版权能从 Info.plist 里给（见 project.yml），
        // 但「这是个什么 App」那一行 plist 里**没有对应的键**，只能自己
        // 把面板叫出来，把那句话当 credits 一起递进去。
        //
        // 面板本身还是系统那一个（名字、版本、版权都照旧从 bundle 里取），
        // 只是多了中间那行说明。
        CommandGroup(replacing: .appInfo) {
            Button("关于 BiliDown") { showAboutPanel() }
        }

        // 「BiliDown > 设置…」。系统默认那条会另开一个小窗口，
        // 换成把主窗口切到设置那一栏 —— 设置只有一个地方看得到，
        // 不会出现「主窗口在设置页、小窗口也在设置页」这种两份。
        // ⌘, 得自己挂：默认那条被 replace 掉了，快捷键不会跟着过来。
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                navigator.section = .settings
                openWindow(id: MacNavigator.mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    /// 系统那个「关于」面板，外加中间那行说明。
    ///
    /// credits 得自己居中：面板会给它一块地方，但不会替你排版 ——
    /// 不写段落样式的话，名字、版本、版权都是居中的，只有这一行贴着左边，
    /// 一眼就看出来是「塞进去的」。字号取系统那一档小字（11），
    /// 跟面板自己那几行一般大。
    private func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSAttributedString(
            string: MacAppInfo.tagline,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph,
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
