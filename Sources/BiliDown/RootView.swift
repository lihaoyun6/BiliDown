import SwiftUI
import BiliKit
import BiliUI

/// 三页：下载队列、我的、设置。没有首页，没有搜索，没有播放。
struct RootView: View {

    /// 标签页。得有个具名的类型才能把「当前在哪一页」传出去 ——
    /// 分享进来的任务建好之后要主动切到「下载」去。
    enum Tab: Hashable {
        case downloads
        case mine
        case settings
    }

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var queue: DownloadQueue
    @State private var tab: Tab = .downloads

    /// 角标往左挪几个点（**正数是往左**，系统那个 API 就是这个方向）。
    ///
    /// 系统默认角标左边缘落在 80，图标外框右边缘是 85 —— 整个角标探在图标
    /// 外面，看着像「挨着图标放着」。一路试过来的（2026-10-12）：
    /// 4 → 8 → 6 → 4，落在 4。改这个数就行，一比一，不用重新量。
    private static let badgeLeftShift: CGFloat = 4

    var body: some View {
        TabView(selection: $tab) {
            // 标签栏的底**故意不设**，交给系统那套两态去管：
            // 没内容滚到它底下时是透明的，跟页面底色连成一片、也没有分界线；
            // 有内容钻进它下层了，才换成毛玻璃 + 那条发丝线。
            // 这就是别的 App 那个观感。之前挂过 .toolbarBackground(.visible, for: .tabBar)，
            // 那个强制「底常显」，等于把第一态焊死成第二态 ——
            // 分界线和毛玻璃就任何时候都在了。
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                // 「还有几个任务没了结」那个红色角标，挂在**下载这个标签**上：
                // 系统画的就是一枚红胶囊白字，数字为 0 的时候自己就没了，
                // 不用我们再管。mac 那边是侧边栏「下载管理」右边自己画的一枚
                // （见 `MacRootView.activityPill`）—— 一个口径（`inFlightCount`），
                // 两个摆法：这边没有侧边栏，那边没有标签栏。
                //
                // 位置往左挪了几个点：系统默认是把角标摆在图标外框的右上角、
                // 整个探在图标外面（看着像挨着图标放着）。见 `badgeLeftShift`。
                .badge(queue.inFlightCount)
                .tag(Tab.downloads)

            // 收藏 / 合集 / 追番 / 追剧 / 稍后再看 / 历史记录，外加账号那一行，
            // 全都在这一页里。**登录与否都在这儿** —— 没登录时顶上那行就是个登录入口。
            //
            // 这一页原来是「更多」，跟「收藏」两个标签一起等登录才画出来。
            // 标签栏会跟着登录态在两个和四个之间跳，几个图标的位置也跟着挪；
            // 账号、收藏、追番本来就是同一摊东西，收进一页之后标签数就恒定了。
            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(Tab.mine)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // 从系统/LiveContainer 分享进来的链接
        .receivesSharedLinks(selection: $tab)
        // 角标往左挪几个点（`TabBarBadgeOffset` 里有为什么、以及这个数怎么来的）。
        // 挂在整条 TabView 的背景上：它只是借「进了视图树」去找那个 UITabBar。
        .background(TabBarBadgeOffset(horizontal: Self.badgeLeftShift))
        // 打开 App 时自动看一眼剪贴板（设置里开关，默认关）
        .detectsClipboard()
        .task {
            // 钥匙串里没读出登录态的话，去 Cookie 库里捞一次。
            // 冷启动第一件事就得做：后面这句 setCredential 要拿它当输入。
            await account.restoreFromCookiesIfNeeded()
            await queue.setCredential(account.credential)
            // 缓存里可能有旧昵称，顺手校准一次
            await account.refreshProfile()
        }
        .onChangeCompat(of: account.credential) { credential in
            Task { await queue.setCredential(credential) }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppSettings())
        .environmentObject(DownloadQueue(settings: AppSettings()))
        .environmentObject(AccountStore())
}
