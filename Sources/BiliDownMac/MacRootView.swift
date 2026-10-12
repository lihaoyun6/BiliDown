import SwiftUI
import BiliCore
import BiliKit
import BiliUI

/// macOS 版的壳：一条侧边栏 + 右边一整块内容。
/// 侧边栏是下载 / 收藏 / 合集 / 追番 / 追剧 / 稍后 / 历史 / 设置，
/// 中间那六个登录后才出现 —— 跟 iOS 那边标签栏是同一套规矩，只是换了个摆法
///（iOS 把追番那四个收进了「更多」那一页，标签栏摆不下八个）。
///
/// 账号不放在「设置」里，挂在侧边栏最底下（App Store 就这个摆法）：
/// 它是「当前是谁」这件事，不是一项设置。
struct MacRootView: View {

    enum Section: Hashable {
        case downloads
        case followings
        case favorites
        case collections
        case bangumi
        case drama
        case watchLater
        case history
        case settings

        /// 这一栏的名字。**侧边栏那一行和右边的窗口标题读的是同一个** ——
        /// 改一处两处跟着走。
        ///
        /// 以前是各写一份：侧边栏挂着「下载管理」「我的收藏」「偏好设置」，
        /// 右边那页标题还留着老版本的「下载」「收藏」「设置」。同一件事在
        /// 同屏幕上写两样，看着就是没做完。名字收在这儿之后，
        /// 页面那边写 `MacRootView.Section.favorites.title` 就够了。
        ///
        /// 「我的」这个前缀是 mac 这份自己的：这条栏上九个词彼此不挨着，
        /// 省掉「我的」换不来什么，光秃秃的「收藏」「合集」读着像几个动词。
        /// iOS 那几页是标签栏 / 「我的」里点进去的，标题就短一档，不受这儿管。
        var title: String {
            switch self {
            case .downloads: return "下载管理"
            case .followings: return "我的关注"
            case .favorites: return "我的收藏"
            case .collections: return "我的合集"
            case .bangumi: return "我的追番"
            case .drama: return "我的追剧"
            // 「稍后再看」：B 站自己就叫这个，iOS 那份也只这么叫。
            // 侧边栏原来写的是「稍后在看」，跟着这一趟一起正过来 ——
            // 它跟右边那页标题本来就该是同一个词。
            case .watchLater: return "稍后再看"
            case .history: return "历史记录"
            case .settings: return "偏好设置"
            }
        }

        /// 这一栏非登录不可（侧边栏上也就登录后才画得出来）。
        /// 用来处理「正站在这一栏上退出登录」—— 那几页没了内容，得退回下载去。
        var needsAccount: Bool {
            switch self {
            case .downloads, .settings: return false
            case .followings, .favorites, .collections, .bangumi, .drama, .watchLater, .history: return true
            }
        }
    }

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var queue: DownloadQueue
    @EnvironmentObject private var settings: AppSettings
    /// 当前停在哪个栏目。存在外面那个对象里而不是 @State ——
    /// 菜单栏那条「设置…」也得能改它（见 MacNavigator）。
    @EnvironmentObject private var navigator: MacNavigator
    /// 队列那四个批量操作和添加页。触发它在下载页（右上角那排按钮、空白处右键），
    /// 但它要摆的那几样（确认框 / 提示 / 添加页）挂在**这一层**：
    /// 下载页会随栏目切换整个重建（detail 挂着 `.id(section)`，加号丢失那次就是
    /// 这个重建干的），把 sheet、alert 挂在一个会被拆掉重建的视图上不稳妥。
    @EnvironmentObject private var actions: MacQueueActions

    private var section: Section { navigator.section }

    /// 选好登录方式之后才开登录窗：有值就说明该弹窗了（`sheet(item:)`）。
    /// 跟 iOS 那边同一个流程、同一个类型（见 `LoginMode`）。
    @State private var loginMode: LoginMode?
    /// 「二维码登录 / 账号登录」那个菜单开了没有。
    @State private var choosingLoginMode = false
    @State private var confirmingLogout = false

    /// 侧边栏宽度。显隐归系统，宽度给个上下限，中间让用户自己拖。
    ///
    /// 最窄 200：这条栏里最多四个词，再窄几行字就要折成两行。
    /// 最宽 260：再多就是白白吃掉正文的地方。
    private static let sidebarMinWidth: CGFloat = 200
    private static let sidebarIdealWidth: CGFloat = 210
    private static let sidebarMaxWidth: CGFloat = 260
    /// 侧边栏每一项的字号和图标大小。
    ///
    /// 都比系统默认那档大一截：mac 的 List 默认一行只有 11pt 字、24pt 高，
    /// 四个词排下来挤成一条。文字 15、图标 17 —— 图标比文字再大两号，
    /// SF Symbol 画在同样的字号下看着比汉字小，不给它补回来就显小。
    private static let sidebarRowFontSize: CGFloat = 15
    private static let sidebarRowIconSize: CGFloat = 15
    /// 侧边栏里图标那一列的宽度。几个标题要左对齐就得框住它 ——
    /// SF Symbol 各人宽窄不一，让它自己排会差出好几个点。
    /// 图标在这一列里居中，所以这个数比图标大多少，图标两边就各空多少。
    private static let iconWidth: CGFloat = 22
    /// 图标那一列和文字之间留多少。要它们再近一点就减这个数。
    ///
    /// 原来是 4，看着图标和字挨得太紧，**加 2 点**到现在这个数（见图标那列
    /// `iconWidth`：框是 22、图标 15，图标两边本身各空 3.5，所以字离图标本体
    /// 其实有 3.5 + 6 ≈ 9.5）。再要宽就往 8 走，别一次跨太多 ——
    /// 这一栏本来就窄，图标一飘出去那几个标题就看着散。
    private static let sidebarRowIconTextGap: CGFloat = 6
    /// 侧边栏那几行自己摆的边距。以前这几笔是 `List` 给的（而且是在布局阶段
    /// 才补上的，见 `sidebarRows`），现在全是我们写死的常量。
    ///
    /// 两笔横向的边分开看：`rowInset` 是行离栏位边缘的距离（贴着走，别白占地方），
    /// `contentInset` 是行里图标文字离行边的距离 —— 这两笔之差
    /// （12 - 6 = 6）就是**选中底色里那圈内边距**，也就是图标不贴着底色边的余量。
    private static let sidebarRowInset: CGFloat = 4
    private static let sidebarRowContentInset: CGFloat = 12
    /// 选中底色离行边的距离。比 `contentInset` 小，底色才比内容宽出一圈。
    private static let sidebarRowHighlightInset: CGFloat = 6
    /// 选中底色的圆角。连续曲率 —— 跟系统画圆角那一套一致，别用正圆角。
    private static let sidebarSelectionCornerRadius: CGFloat = 7
    /// 选中高亮压多深（0…1）。见 `sidebarSelectionFill`。
    ///
    /// 0.14 这个数：正常背景下的深浅跟以前那块调过的实色灰差不多，
    /// 压着纯黑窗口时大约还留 0.09~0.10 的差（以前是 0——整块化进去）。
    /// 嫌浅往 0.18 走，嫌重回 0.10。
    private static let sidebarSelectionOpacity: CGFloat = 0.14
    /// 选中高亮铺的那一层：**半透明的黑**（深色外观下是白），不是一块实色灰。
    ///
    /// 这条栏是 `.behindWindow` 的毛玻璃，它自己的明度跟着窗口后面那个窗口走。
    /// 窗口后面压一个纯黑窗口的时候，整条栏会落到某个灰上 —— 连系统那个选中材质
    /// （`NSVisualEffectView.material = .selection`）都一起落在那儿：本机试过，
    /// 选中那块整块化进去，肉眼就是「完全没有选中」。所以问题不是「哪个灰对」：
    /// 只要是个**绝对值**，就总有一个背景明度能让它撞上。
    ///
    /// 改成半透明就绕开了这件事：压出来的差是底下那层明度的**固定比例**
    /// （0.14 上下），底下亮就压得暗、底下暗就提得亮，任何背景上都留着一档差。
    ///
    /// 顺带一个好处：半透明意味着高亮底下的毛玻璃**照样透出来**，它只是把这一块
    /// 稍微压暗／提亮一点，不是盖一张贴纸上去 —— 这条栏还是那条栏。
    ///
    /// 深色外观下用白不是随手写的：方向跟这一行的字色一致（浅色字黑、深色字白），
    /// 字在选中块上不会反过来发闷。
    private static let sidebarSelectionFill = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(sidebarSelectionOpacity)
    })
    /// 一行上下各留多少 —— 行高主要就是这个数加字号。
    private static let sidebarRowVerticalPadding: CGFloat = 9
    private static let sidebarRowSpacing: CGFloat = 2
    private static let sidebarRowTopInset: CGFloat = 8
    /// 「有几个任务在下」那枚小红胶囊：数字的字号，还有胶囊最矮多高。
    ///
    /// 字号比侧边栏那几个名字小得多（11 对 15）：它是一枚角标，不是这一行的
    /// 内容 —— 跟名字一样大的话，「下载管理」旁边就多出一个词来抢地方。
    /// 16 是最矮高度：一位数的时候出来的就是个圆，两位数是条胶囊。
    private static let activityPillFontSize: CGFloat = 11
    private static let activityPillMinHeight: CGFloat = 16
    /// 侧边栏底下那行账号里的图标。比上面四个导航项的图标大一号 ——
    /// 这一行是「当前是谁」，跟导航项不是一类东西，尺寸上就该分得开。
    /// 图标大、文字小，是这一行的主次关系，不是「图标跟文字一样大」。
    private static let accountIconSize: CGFloat = 36
    /// 账号那一行左右各留多少。两边同一个数，否则整行看着是歪的。
    private static let accountInset: CGFloat = 12

    var body: some View {
        splitView
            .hud($actions.hud)
            .task {
                // 先补登录态，再喂给队列 —— 顺序反了队列拿到的就是空的
                await account.restoreFromCookiesIfNeeded()
                await queue.setCredential(account.credential)
                await account.refreshProfile()

                // 剪贴板自动检测（设置里开关，默认关）。
                // macOS 读剪贴板不会像 iOS 那样弹「允许粘贴」，
                // 但这个开关是跟 iOS 对齐的：默认不主动碰用户的剪贴板。
                if settings.autoDetectClipboard, let text = MacPasteboard.string {
                    present(MacLinkIntake.entries(from: text), quiet: true)
                }
            }
            .onChangeCompat(of: account.credential) { credential in
                Task { await queue.setCredential(credential) }
            }
            .onChangeCompat(of: account.isLoggedIn) { loggedIn in
                // 正站在收藏/合集页时退出登录，那一页就没内容了，退回下载去
                if !loggedIn, section.needsAccount {
                    navigator.section = .downloads
                }
            }
            // bilidown://add?url=... —— 跟 iOS 版同一个 scheme，
            // 快捷指令那条路两端通用
            .onOpenURL { url in
                guard let link = MacLinkIntake.link(in: url) else {
                    actions.hud = HUD(icon: "questionmark.circle.fill", text: "这个链接认不出来")
                    return
                }
                present(MacLinkIntake.entries(from: link), quiet: false)
            }
            // 登录窗：`mode` 是用户在菜单里选的那一种，`item:` 天然保证
            // "选完了"和"选的是哪种"是同一件事。
            .sheet(item: $loginMode) { mode in
                MacLoginSheet(mode: mode)
            }
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
            // 添加页只有这一个出口：顶栏那排按钮里的加号、右键「读取剪贴板」、
            // 快捷指令带进来的链接，走的都是 `actions.addSheet`。
            // 内容由它自己带着（空着开 = 让用户填），所以用 item 而不是 Bool。
            .sheet(item: $actions.addSheet) { sheet in
                MacAddTargetsSheet(initialEntries: sheet.entries)
                    .environmentObject(queue)
                    .environmentObject(settings)
            }
            // 那四个要问一句才做的操作。框挂在这一层（见 `actions` 的说明），
            // 答完由 actions 那边动手。
            .alert(
                actions.pending?.title ?? "",
                isPresented: pendingBinding,
                presenting: actions.pending
            ) { choice in
                Button(choice.confirmTitle, role: .destructive) {
                    actions.perform(choice, queue: queue)
                }
                Button("取消", role: .cancel) {}
            } message: { choice in
                Text(choice.message)
            }
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

    // MARK: - 骨架

    /// 骨架：系统的 `NavigationSplitView`，左边一条侧边栏，右边一整块内容。
    ///
    /// 这是原生那一套：顶栏是分栏的（左边归侧边栏，右边归正文），
    /// 所以标题、搜索框、页内按钮都能各就各位；侧边栏的材质、开合、拖宽
    /// 也全是系统在管，我们只管内容。
    ///
    /// 试过不用它、自己用 `HStack` 摆（那样能躲开系统侧边栏展开时内容蹿一下
    /// 那个毛病），但顶栏随之变成整窗一条 —— 标题和「返回」只能落在最左边，
    /// 也就是侧边栏头上，成了另一团乱。不值得，回到原生的。
    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // `.id(section)` 这一句不能省。收藏 / 合集 / 追番 / 追剧四栏都是
            // `MacLibraryList`，只差一个 kind —— **类型相同，SwiftUI 就当成同一个
            // 视图接着用**，里面那些翻到第几页、搜了什么字的状态也跟着留着。
            // 钉一个跟栏目走的身份，切一次重建一次，各栏目的状态各归各的。
            detailContent.id(section)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .followings:
            // 关注是三级（分组 → 人 → TA 的投稿），里头那两个层次归它自己切，
            // 所以这里只摆一个入口视图。
            MacFollowingsView()
        case .favorites:
            MacLibraryList(kind: .favorites)
        case .collections:
            MacLibraryList(kind: .collections)
        // 追番 / 追剧也是「先挑一季，再挑分集」，跟收藏夹 / 合集是同一个形状，
        // 所以也过 MacLibraryList 那一层。
        case .bangumi:
            MacLibraryList(kind: .bangumi)
        case .drama:
            MacLibraryList(kind: .drama)
        // 稍后和历史没有上一层列表：侧边栏点进来就是视频列表本身，
        // 直接把详情页摆上。
        case .watchLater:
            MacLibraryDetailView(source: .watchLater)
        case .history:
            MacLibraryDetailView(source: .history)
        case .settings:
            MacSettingsView()
        case .downloads:
            MacDownloadsView()
        }
    }

    /// 有东西可加就把添加页摆出来，让用户自己确认。
    /// `quiet` 是剪贴板那条路用的：剪贴板里常年躺着各种各样的东西，
    /// 认不出来的时候不该拿一句「认不出来」去烦人 —— 那条路只在真认出来了才出声。
    private func present(_ entries: [InputEntry], quiet: Bool) {
        guard !entries.isEmpty else {
            if !quiet {
                actions.hud = HUD(icon: "questionmark.circle.fill", text: "这段内容里没有能下载的链接")
            }
            return
        }
        // 外面递进来的链接多半是想马上下的，先把人带到下载页，再把添加页摆出来
        navigator.section = .downloads
        actions.addTask(entries: entries)
    }

    /// 确认框的开关。答完（点确认或取消）都得把它放回 nil，
    /// 否则同一个操作第二次点不出来。
    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { actions.pending != nil },
            set: { if !$0 { actions.pending = nil } }
        )
    }

    // MARK: - 侧边栏

    /// 侧边栏。材质、分隔线、开合、拖宽，全归系统 —— 我们只放内容。
    private var sidebar: some View {
        sidebarContent
            .navigationSplitViewColumnWidth(
                min: Self.sidebarMinWidth,
                ideal: Self.sidebarIdealWidth,
                max: Self.sidebarMaxWidth
            )
    }

    /// 侧边栏的内容：上面四行，下面账号那一块，中间用 Spacer 顶开。
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarRows
            Spacer(minLength: 0)
            sidebarFooter
        }
    }

    /// 侧边栏里那四行。
    ///
    /// **不用 `List`。** 这里原来是个 List —— 侧边栏里摆 List 是本能反应，
    /// 可这个侧边栏压根不需要 List 提供的东西：选中底色自己画、图标颜色自己定、
    /// 四个格子从来不需要滚。List 留下的全是副作用，而嫌疑最大的就是这一条：
    ///
    /// List 底下是 `NSScrollView`，**内容的边距是系统在布局阶段补上去的**，
    /// 不是我们写死的值。栏位一收一放，侧边栏这棵子树被重建，
    /// 头一两帧那个边距还没补上 —— 四行就整体贴着栏位左边缘站一下，
    /// 下一帧补上了才回到正常位置。用户报的「向右展开、里面的东西却先往左
    /// 蹿一下再恢复」正是这个形状：蹿的距离不大，但很显眼。
    ///
    /// 换成手摆的 `VStack`，每一行的边距都是我们自己写死的常量，
    /// 没有任何东西会在布局阶段去改它。行距、行高、左边距见下面几个常量。
    ///
    /// 顺带：不给 List 挂 selection 那条规矩也一并作废了 —— 没有 List 可挂。
    private var sidebarRows: some View {
        // 「有几个任务还没了结」—— 挂在「下载管理」那一行的右边（见下面那枚胶囊）。
        // 口径跟 iOS 那个标签栏角标是同一个：读的都是 `DownloadQueue.inFlightCount`
        //（排队中的也算，只数在跑的话「全部开始」之后角标会是 0）。
        let activity = queue.inFlightCount

        return VStack(spacing: Self.sidebarRowSpacing) {
            // 名字归 `Section.title` 管，这儿只给图标 —— 图标是「这一栏长什么样」
            // 的局部选择，名字得跟右边那页的标题是一个词，所以收在一处。
            sidebarRow(.downloads, systemImage: "arrow.down.circle", activity: activity)

            // 这一组都是自己账号里的东西，一起等登录。
            // 追番那四个跟 iOS 的「我的」是同一批，图标也用同一批 ——
            // 两端各挑各的，同一件事在两个平台上会长成两个样子。
            //
            // 关注排在最前（紧挨着下载管理）：它跟下面那六个不是一回事 ——
            // 那些点进去都是「一堆视频」，这个点进去是「一群人」，再往下才是视频。
            if account.isLoggedIn {
                sidebarRow(.followings, systemImage: "person.2")
                sidebarRow(.favorites, systemImage: "star")
                sidebarRow(.collections, systemImage: "rectangle.stack")
                sidebarRow(.bangumi, systemImage: "sparkles.tv")
                sidebarRow(.drama, systemImage: "film")
                sidebarRow(.watchLater, systemImage: "clock")
                sidebarRow(.history, systemImage: "clock.arrow.circlepath")
            }

            sidebarRow(.settings, systemImage: "gearshape")
        }
        .padding(.horizontal, Self.sidebarRowInset)
        .padding(.top, Self.sidebarRowTopInset)
    }

    // MARK: - 侧边栏里的一行

    /// 侧边栏里的一行。字号、图标和行高都比系统默认那档大一截 ——
    /// mac 的 List 默认一行只有 11pt 字、24pt 高，四个词排下来挤成一条，
    /// 跟 App Store 那条侧边栏摆一块就不像一家的。字号和图标大小见上面几个常量。
    ///
    /// 选中态那三样东西各归各的：底色是**半透明的一层灰**（见
    /// `sidebarSelectionFill`），图标一律强调色，文字一律标准色。
    /// 这三样系统那套凑不齐：它一律是强调色底 + 白字。
    ///
    /// 图标**不跟选中走**：选中与否都是那个蓝。侧边栏这几个图标是「这是哪一页」
    /// 的标识，不是状态，跟着选中变灰会让整条栏看着像忽明忽暗。
    ///
    /// `activity` 是「有几个任务在下」，只有「下载管理」那一行给（别的行是 0，
    /// 也就不画）。摆在这一行的**行尾**，见下面那枚胶囊。
    private func sidebarRow(_ tag: Section, systemImage: String, activity: Int = 0) -> some View {
        let isSelected = section == tag

        return Button {
            navigator.section = tag
        } label: {
            // 用 `HStack` 而不是 `Label`：Label 图标和文字之间那个间距是系统定死的，
            // 调不了。这儿要的是一个能写出来的数。
            HStack(spacing: Self.sidebarRowIconTextGap) {
                Image(systemName: systemImage)
                    .font(.system(size: Self.sidebarRowIconSize))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Self.iconWidth, alignment: .center)

                Text(tag.title)
                    .font(.system(size: Self.sidebarRowFontSize))
                    .foregroundStyle(.primary)

                if activity > 0 {
                    // 这一行是「图标 + 名字」靠左，胶囊顶到行尾 —— 中间那片空
                    // 由这个 Spacer 吃掉。不摆它的话胶囊会紧跟在名字后面，
                    // 离名字忽远忽近（名字长就顶到边上、短就缩在中间）。
                    Spacer(minLength: 8)
                    activityPill(activity)
                }
            }
            // 左右同一个数，文字那一列看着才不歪。这几个数是手摆出来的，
            // 跟系统那套无关 —— 以前那个是 List 自己给的边距，现在归我们管，看图调。
            .padding(.horizontal, Self.sidebarRowContentInset)
            .padding(.vertical, Self.sidebarRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 选中底色铺在行的内容底下。以前是 `listRowBackground` ——
            // 那个是 List 的插槽，现在没有 List 了，直接挂背景上。
            //
            // 左右各留一点：系统给侧边栏画选中时也是缩进一块，
            // 铺满整行会顶到栏位边缘，看着像另一个控件。
            // 底色比行内容少缩进几笔，图标才不贴着底色边（那圈余量见上面几个常量）。
            //
            // 画它的不是一块实色灰（那块在深色背景下会跟栏撞成一片，见
            // `sidebarSelectionFill`），是半透明的一层 —— 毛玻璃从它底下透出来。
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.sidebarSelectionCornerRadius, style: .continuous)
                        .fill(Self.sidebarSelectionFill)
                        .padding(.horizontal, Self.sidebarRowHighlightInset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 窗口一开，第一项会顶着一圈系统给的蓝色焦点光晕。见 noFocusRing()。
        .noFocusRing()
    }

    /// 「有几个任务在下」。红底白字一个纯数字 —— 跟 iOS 标签栏上系统画的那枚
    /// 角标说的是同一件事，连样子都对齐（红胶囊、白字、只要数字）。
    ///
    /// 自己画而不是找系统要：mac 这儿不是标签栏，没有 `.badge` 可用，
    /// 这一行是我们手摆的 Button。红用 `Color.red`（就是系统红），
    /// 别调成暗红 —— 角标要的就是「一眼看见」。
    private func activityPill(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: Self.activityPillFontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: Self.activityPillMinHeight, minHeight: Self.activityPillMinHeight)
            .background(Color.red, in: Capsule())
            // 旁白读这一行时得念出来这是什么 —— 不然那儿只有一个数字
            .accessibilityLabel("\(count) 个任务进行中")
    }

    /// 侧边栏底下那一块：只有账号了。
    ///
    /// 队列概况（「N 个任务进行中」）原来摆在这上面，现在挂在「下载管理」那一行
    /// 的右边（见 `activityPill`）—— 那句话说的是队列，而队列就是那一栏；
    /// 摆在这儿还多一个毛病：它是**有任务才出现**的，一有任务账号那块就被顶着
    /// 往下走一格，侧边栏底下会跳。
    ///
    /// **不给底色**。之前铺了一层 `.bar`，结果这一条被刷成一条比侧边栏更白的
    /// 横带，下半截跟上面明显不是一个色。这块本来就是贴在侧边栏材质上的，
    /// 不铺东西它自然就是同一个灰。
    /// 底下留 4pt：这块紧贴着窗口下沿，够把头像从边上抬起来一点就行 ——
    /// 账号那一行自己上下还各留了 10，两笔加起来已经不少了。
    /// 上面**不加分隔线** —— 这块跟侧边栏是同一片材质，横一道线把它切成
    /// 「两个区域」，而它本来就只是侧边栏的另一头。
    private var sidebarFooter: some View {
        accountRow
            .padding(.bottom, 4)
    }

    // MARK: - 账号

    /// 账号那一行。登录前是「人形图标 + 登录」，登录后是「头像 + 昵称」。
    ///
    /// 两态共用同一个方框尺寸、同一套内边距，登录前后这一行的高矮和左边距
    /// 一模一样 —— 登一下录整条侧边栏跟着跳一格是很明显的毛刺。
    /// 头像没下回来的时候底下垫的就是那个人形图标，所以也不会空一块。
    /// 直接一个按钮，**不再套 Menu**。
    ///
    /// 之前套 Menu 是为了「点头像弹一个『退出登录』」。可这一行只有这一个动作，
    /// 中间隔一层菜单等于多点一下；而且 Menu 会把标签的字体环境整个换掉，
    /// 图标大小那笔糊涂账就是从这儿来的。
    /// 现在：没登录就进登录页，登录了就弹那句二次确认 —— 一步到位，
    /// 确认框还在，误点也退不出去。
    private var accountRow: some View {
        Button {
            if account.isLoggedIn {
                confirmingLogout = true
            } else {
                // 先问走哪条路再开窗：登录页是左右两栏，选完只摆对应的那半页
                //（见 `LoginMode`）。跟 iOS 那边同一个流程。
                choosingLoginMode = true
            }
        } label: {
            // 没登录时写全「登录解锁更多功能」，跟 iOS 的「我的」那一页一致：
            // 那一行底下再没有别的东西了，得用它说清楚登进去是**多出东西**来的。
            accountLabel(account.isLoggedIn ? account.displayName : "登录解锁更多功能",
                         showsAvatar: account.isLoggedIn)
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .help(account.isLoggedIn ? "退出登录" : "登录")
    }

    /// 用户头像：圆形，跟人形图标占同一个方框，所以登录前后这一行高矮不变。
    ///
    /// 人形图标只在**没有头像可用**的时候才画：没拿到地址，或者图下回来失败了。
    /// 原来是无论有没有都垫在底下，结果点这一行时整个标签被按暗一档，
    /// 底下的图标就从头像里透出来，成了两个叠影。
    private var accountAvatar: some View {
        Group {
            if let url = account.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        accountPlaceholderIcon
                    default:
                        // 还在下：留空。这张图迟早会盖满这一格，
                        // 底下垫什么都会被看见一下再消失。
                        Color.clear
                    }
                }
            } else {
                accountPlaceholderIcon
            }
        }
        .frame(width: Self.accountIconSize, height: Self.accountIconSize)
        .clipShape(Circle())
    }

    /// 没有头像时那个人形图标。头像和登录前那一行共用它，两处才对得上。
    private var accountPlaceholderIcon: some View {
        Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }

    /// 账号那一行的内容：图标 + 一行字。两态共用，尺寸和边距只写一份。
    ///
    /// 左右各 12（同一个数，两边对称），上下各 10。
    /// 这一块的左边距跟侧边栏里那几行导航是**差不多对齐**的：
    /// 导航行自己有 List 的缩进，这一块在 List 外面，得自己补上。
    private func accountLabel(_ text: String, showsAvatar: Bool) -> some View {
        HStack(spacing: 10) {
            // 走 `.resizable()` 而不是 `.font(size:)`。
            //
            // 给 SF Symbol 调大小本来该用 `.font()`，但在这儿它不管用 ——
            // 之前这一行包在 `Menu` 里，菜单会把标签的字体环境整个换掉，
            // 字号怎么改，符号都还是跟旁边的文字一样高。
            // 现在 Menu 拿掉了，但这条规矩留着：`.resizable()` + 写死的 frame
            // 是从图片那条路走的，不经过字体环境，谁覆盖都覆盖不掉。
            Group {
                if showsAvatar {
                    accountAvatar
                } else {
                    accountPlaceholderIcon
                        .frame(width: Self.accountIconSize, height: Self.accountIconSize)
                }
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.accountInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

extension View {
    /// 不要那圈蓝光。
    ///
    /// 窗口一开，SwiftUI 会把第一颗能拿到焦点的控件设成焦点控件，
    /// 侧边栏第一项于是就顶着一圈蓝色光晕 —— 那圈东西跟侧边栏自己的选中底色
    /// 是两套，叠在一起像两个选中态打架。键盘操作本身是好事，坏的是这圈光晕。
    ///
    /// macOS 14 起有现成的 `.focusEffectDisabled()`：焦点还在，只是不画光晕。
    /// 13 上没这个东西，退而求其次把这几行移出焦点链（鼠标点击不受影响）。
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            focusable(false)
        }
    }
}
