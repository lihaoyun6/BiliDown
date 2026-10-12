import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// 「我的」那一页：顶上是账号，登录之后下面才是关注 / 收藏 / 合集 / 追番 / 追剧 /
/// 稍后再看 / 历史记录。
///
/// 这一页跟「下载」「设置」一样**常驻标签栏** —— 没登录的时候也在，
/// 顶上那行写「登录解锁更多功能」，点一下就是登录页；底下那串入口整块不画
///（理由见 `body` 里那段）。
/// 收藏原来是单独一个标签、跟「更多」一起等登录才画出来：标签栏会随着登录态
/// 从两个变成四个，几个图标的位置也跟着挪。三个标签始终都在就不挪了；
/// 自己账号上的东西本来也该收在同一页里。
///
/// 以前这一页叫「更多」，只管下面那一堆入口，账号那摊子在设置页里。
/// 现在账号摆在最上面（就是这一页的头），设置页那边整块拿掉了 ——
/// 「登录 / 退出」跟「我收藏了什么、追了什么」是一件事，该在一块儿。
struct MineView: View {

    @EnvironmentObject private var account: AccountStore

    /// 选好登录方式之后才开登录窗：有值就说明该弹窗了（`sheet(item:)`）。
    /// 用可选项而不是一个 Bool 加一份 mode，是因为"选完了"和"选的是哪种"
    /// 本来就是同一件事，拆成两个状态迟早会出现对不上的那一帧。
    @State private var loginMode: LoginMode?
    /// 「二维码登录 / 账号登录」那个菜单开了没有。
    @State private var choosingLoginMode = false
    @State private var confirmingLogout = false

    /// 图标那一列的宽度。这几个图标宽窄不一（`clock.arrow.circlepath` 比 `film`
    /// 宽出一截），不框住的话几条文字的左边缘会各差几个点，一列扫下来一眼就看出不齐。
    private static let iconWidth: CGFloat = 24

    /// 头像那一格。跟 mac 侧边栏左下角那块一样是圆的；
    /// 36 是 mac 的尺寸，iOS 的行本来就高一档，给它 40。
    /// 头像本身在 `AvatarView` 里 —— 「我的关注」里那一列人也用它。
    private static let avatarSize: CGFloat = 40

    var body: some View {
        NavigationStack {
            List {
                accountSection

                // 账号上的东西一起等登录：没登录时这整块都不画。
                //
                // 这一拨（关注 / 收藏 / 合集 / 追番 / 追剧 / 稍后再看 / 历史记录）
                // 没登录时一个都读不出来，点进去只有一句「读不到」/「还没有登录」——
                // 摆在那儿就是让人白点一趟。mac 那条侧边栏是同一个规矩
                //（见 `MacRootView.sidebarRows`），同一个栏目在两端露不露面得一致。
                if account.isLoggedIn {
                    // 关注**单独一组**，就它一行：它跟下面那串收藏 / 合集 / 追番
                    // 不是一回事 —— 那些点进去都是「一堆视频」，这个点进去是「一群人」，
                    // 再往下才是视频。隔开一段，这条分界才看得出来。
                    followSection

                    // 下面这两组分的是另一个界：上面那四样是**收藏、订阅**来的内容
                    //（都得再点一层才见得到视频），下面那两样是**我自己看过 / 待看**的
                    //（点进去直接就是视频列表）。
                    librarySection

                    watchSection

                    // 退出登录也只在登录后才有意义。它自己一组、摆整页最下面 ——
                    // 跟上面那几组隔开一段，不会在往下翻的时候被顺手点到。
                    logoutSection
                }
            }
            .navigationTitle("我的")
            .sheet(item: $loginMode) { mode in
                LoginSheet(mode: mode)
            }
        }
    }

    // MARK: - 账号

    /// 顶上那一块：登录前是「人形图标 + 登录」，登录后是「头像 + 昵称」。
    ///
    /// 两态共用同一个方框尺寸、同一套内边距，登录前后这一行的高矮一模一样 ——
    /// 登一下录整页跟着跳一格是很明显的毛刺。头像没下回来的时候底下垫的就是
    /// 那个人形图标，所以也不会空一块。
    ///
    /// 摆法跟 mac 侧边栏左下角那一行是同一个样子（见 MacRootView 的 accountRow），
    /// 只是那边点一下是「问一句要不要退出」，这边退出的动作在下面单独一行 ——
    /// 所以**登录之后这一行不是按钮**。一行看着能点、点下去却没反应，
    /// 比明摆着不能点更糟。
    private var accountSection: some View {
        Section {
            if account.isLoggedIn {
                accountLabel(account.displayName, showsAvatar: true)
            } else {
                Button {
                    choosingLoginMode = true
                } label: {
                    // 写「登录解锁更多功能」而不是光一个「登录」：这一页登录前
                    // 就只剩这一行，底下那串入口一个都看不见，得用它说清楚
                    // 登进去是**多出东西**来的，不是「这一页本来就这样」。
                    accountLabel("登录解锁更多功能", showsAvatar: false)
                }
                // 弹窗挂在**按钮自己**身上，不是挂在整页的 List 上。
                //
                // iPad 上宽度够的时候，`confirmationDialog` 不是从底部升起来，
                // 而是变成一个带尖角、指着来源视图的**气泡**。挂在 List 这种
                // 外层容器上时来源就是整页，气泡会缩成一行高，里面的选项露不全
                //（iPhone 没这问题：那一档它一律从底部升起，跟来源是谁无关）。
                // 挂在按钮上，锚点和尺寸才是对的 —— 这个菜单和下面「退出登录」
                // 那个确认框都是这个道理。
                //
                // 点「登录」先问一句走哪条路，再开窗：登录页是左右两栏，
                // 模态窗比它窄，选完只摆对应的那半页才看得清（见 `LoginMode`）。
                .confirmationDialog(
                    "选择登录方式",
                    isPresented: $choosingLoginMode,
                    titleVisibility: .visible
                ) {
                    ForEach(LoginMode.allCases) { mode in
                        Button(mode.title) { loginMode = mode }
                    }
                    Button("取消", role: .cancel) {}
                }
            }

            // 钥匙串存不住登录态时（自签 / 侧载换签名主体之后很常见）说一声。
            // 不说的话，用户看到的只是「每次打开都要重登」，无从下手。
            // 这段原来在设置页的账号那一组里，跟着账号一起搬到这儿来了。
            if let warning = account.keychainWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 账号那一行的内容：头像 + 昵称，名字底下补一行 UID。
    ///
    /// UID 原来在设置页里跟昵称并排摆着（要抄下来、要跟人对的东西，不能缩），
    /// 搬到这儿并排就太挤了 —— 改成名字底下的小字，信息还在，也不抢名字。
    private func accountLabel(_ text: String, showsAvatar: Bool) -> some View {
        HStack(spacing: 12) {
            // 没登录的时候传 nil，出来就是那个人形占位符 ——
            // 跟真头像占同一格，所以登录前后这一行的高矮分毫不差。
            AvatarView(url: showsAvatar ? account.avatarURL : nil, size: Self.avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if showsAvatar, let uid = account.credential?.userId, !uid.isEmpty {
                    Text("UID \(uid)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// 退出登录。**单独一行、红的、字居中**。
    ///
    /// 居中而不是跟着别的行靠左：这一组就它一行，靠左看着像「还有别的设置项」，
    /// 居中才像是这一页的收尾动作。红色由 `role: .destructive` 给
    ///（List 里那套会把它刷成红的），不自己上色。
    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingLogout = true
            } label: {
                Text("退出登录")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 挂在按钮上而不是外层 List 上的理由见上面「登录」那一处
            .confirmationDialog(
                "要退出当前账号吗？",
                isPresented: $confirmingLogout,
                titleVisibility: .visible
            ) {
                Button("退出登录", role: .destructive) {
                    Task { await account.logout() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 入口

    /// 我的关注。分组 → 人 → TA 的投稿，三级往下（见 `FollowGroupsView`）。
    ///
    /// 整块跟着登录态走（调用处包在 `if account.isLoggedIn` 里），
    /// 所以点进去那一页不必自己处理「没登录」—— 它只在登录后才画得出来。
    private var followSection: some View {
        Section {
            // 名字取自那一页自己（同下面那串入口的口径），不在这儿另写一份
            row(title: FollowGroupsView.pageTitle, systemImage: "person.2") {
                FollowGroupsView()
            }
        }
    }

    /// 收藏 / 订阅合集 / 我的追番 / 我的追剧：我收藏、订阅来的那些。
    /// 一张卡片连成一串 —— 它们本来就是同一类东西，而且点法也一样
    ///（都要再往下翻一层才见得到视频）。
    ///
    /// 收藏排第一：它下面那三个都是「一堆视频的集合」，收藏夹是其中最常用的那个。
    /// 这一组也跟登录态走（同 `followSection`）—— 它们本来就全是账号里的东西。
    private var librarySection: some View {
        Section {
            // 收藏夹列表。行上的名字和点进去那页的标题是**同一份**
            //（`LibraryListKind.mineTitle`）—— 这两个从前各写各的，就出过
            // 「行上叫我的收藏、进了页面标题还写着收藏」这种事。
            // 图标也归 `LibraryListKind` 管，这儿不另写一个。
            row(title: LibraryListKind.favorites.mineTitle, systemImage: LibraryListKind.favorites.icon) {
                FavoritesView()
            }

            list(.collections)

            // 追番 / 追剧进的是「一季一季」的列表，再点一层才是分集
            list(.bangumi)
            list(.drama)
        }
    }

    /// 稍后再看 / 历史记录：我自己待看、看过的，也一张卡片连成一串。
    ///
    /// 跟上面那一组分开，分的就是「要不要再翻一层」：这两个点进去
    /// 直接就是视频列表，没有中间那层（见 `entry`）。
    private var watchSection: some View {
        Section {
            entry(.watchLater, systemImage: "clock")
            entry(.history, systemImage: "clock.arrow.circlepath")
        }
    }

    /// 稍后再看 / 历史记录：点进去就是视频列表，没有中间那层。
    ///
    /// 名字取自 `LibrarySource.title`，那也正是点进去那一页自己的标题
    ///（`VideoPickerView` 读的是同一个）—— 行和页面对不上是不可能的。
    private func entry(_ source: LibrarySource, systemImage: String) -> some View {
        row(title: source.title, systemImage: systemImage) {
            VideoPickerView(source: source)
        }
    }

    /// 订阅合集 / 我的追番 / 我的追剧：先是一列条目，点进去才是视频。
    /// 名字和图标都归 `LibraryListKind`（名字见 `mineTitle`，图标跟那一页
    /// 自己的空态图标同一个来源），这儿不再抄一遍 —— 抄一遍就会再有
    /// 「行上叫订阅合集、页面标题写着合集」这种对不上。
    private func list(_ kind: LibraryListKind) -> some View {
        row(title: kind.mineTitle, systemImage: kind.icon) {
            LibraryListView(kind: kind)
        }
    }

    /// 一行入口。左边图标右边字，右边那个箭头由 `NavigationLink` 自己画。
    private func row<Destination: View>(
        title: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Self.iconWidth, alignment: .center)

                Text(title)
            }
            .padding(.vertical, 2)
        }
    }
}

extension LibraryListKind {

    /// iOS 上这个入口的名字。**「我的」里那一行、点进去那一页的标题，读的都是它。**
    ///
    /// 从前这两处各写一份：行上补了「我的」「订阅」几个字，页面标题还留着
    /// `LibraryListKind.title` 那份短的（收藏 / 合集），于是进了页面名字反而变短。
    /// 收成一份之后两边不可能再对不上。
    ///
    /// 名字跟 mac 那条侧边栏**故意不一样**：那边九个词彼此不挨着，光「合集」
    /// 读着像个动词，所以叫「我的合集」；这边是在「我的」页的一张单子上，
    /// 一列全是自己的东西，「订阅合集」说的是「我订阅来的那些」，更有用
    ///（mac 那份见 `MacLibraryList.macWindowTitle`）。
    var mineTitle: String {
        switch self {
        case .favorites: return "我的收藏"
        case .collections: return "订阅合集"
        case .bangumi: return "我的追番"
        case .drama: return "我的追剧"
        }
    }
}
