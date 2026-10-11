import SwiftUI
import BiliKit
import BiliUI

/// 只有两页：下载队列和设置。没有首页，没有搜索，没有播放。
struct RootView: View {

    /// 标签页。得有个具名的类型才能把「当前在哪一页」传出去 ——
    /// 分享进来的任务建好之后要主动切到「下载」去。
    enum Tab: Hashable {
        case downloads
        case favorites
        case more
        case settings
    }

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var queue: DownloadQueue
    @State private var tab: Tab = .downloads

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
                .tag(Tab.downloads)

            // 没登录就读不到自己的收藏夹、合集、追番这些东西，
            // 所以这两个 Tab 登录后才出现
            if account.isLoggedIn {
                FavoritesView()
                    .tabItem { Label("收藏", systemImage: "star") }
                    .tag(Tab.favorites)

                // 合集 / 追番 / 追剧 / 稍后再看 / 历史记录都收在这一页里 ——
                // 五个 Tab 换一个，标签栏才不会挤到第五个就得靠系统收起来。
                // 跟着收藏一起等登录：里面那几样都是自己账号上的东西。
                MoreView()
                    .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                    .tag(Tab.more)
            }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // 从系统/LiveContainer 分享进来的链接
        .receivesSharedLinks(selection: $tab)
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
