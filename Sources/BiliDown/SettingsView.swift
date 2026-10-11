import SwiftUI
import UIKit
import BiliCore
import BiliKit
import BiliUI

struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openURL) private var openURL
    @State private var isLoggingIn = false
    @State private var confirmingLogout = false
    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var confirmingParallel = false
    @State private var hud: HUD?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                downloadSection
                parseSection
                shortcutSection
                aboutSection
                cacheSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $isLoggingIn) {
                LoginSheet()
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
            // 只提一句。数值照改不误 —— 这是个提醒，不是要用户再点一次头才能生效。
            .alert("风险提示", isPresented: $confirmingParallel) {
                Button("好", role: .cancel) {}
            } message: {
                Text("并行下载可能会触发风控, 请谨慎使用!")
            }
        }
        .hud($hud)
    }

    // MARK: - 账号

    /// 账号区块里两行图标共用的列宽。
    /// 不写成「图标 + 自动间距」是因为两个符号的宽度并不相等，
    /// 各排各的，下面那行文字就会跟用户名错开一截。
    private static let accountIconWidth: CGFloat = 24

    private var accountSection: some View {
        Section {
            if account.isLoggedIn {
                HStack(spacing: 8) {
                    // 带勾的：这行是「已经登上了」，状态得写在图标上
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .frame(width: Self.accountIconWidth, alignment: .leading)
                    Text(account.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if let uid = account.credential?.userId, !uid.isEmpty {
                        // 正常字号（不缩）：UID 是要抄下来、要跟人对的东西，
                        // 缩成 footnote 比用户名还小一号，读起来得凑近
                        Text("UID \(uid)")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.green)

                // 退出登录也得带个人形图标（带叉的那个），跟上面那行是一对。
                // 图标列宽跟上面钉的是同一个数，两行文字才齐 —— 这俩符号
                // 宽度本来不一样（带 badge 的那个更宽），靠 Label 自己排会错开。
                Button(role: .destructive) {
                    confirmingLogout = true
                } label: {
                    HStack(spacing: 8) {
                        // 非 fill 版，跟上面那个带勾的是一对（描边的配描边的）
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .frame(width: Self.accountIconWidth, alignment: .leading)
                        Text("退出登录")
                    }
                }
            } else {
                Button {
                    isLoggingIn = true
                } label: {
                    Label("登录 B 站账号", systemImage: "person.crop.circle.badge.plus")
                }
                Text("登录后可下载高清视频")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // 钥匙串存不住登录态时（自签 / 侧载换签名主体之后很常见）说一声。
            // 不说的话，用户看到的只是「每次打开都要重登」，无从下手。
            if let warning = account.keychainWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("账号登录")
        }
    }

    // MARK: - 下载设置（存哪儿 + 编成什么）

    private var downloadSection: some View {
        Section {
            Picker("视频编码", selection: $settings.videoCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }
            .pickerStyle(.menu)

            Picker("音频格式", selection: $settings.audioFormat) {
                ForEach(AudioFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)

            parallelRow

            // 还是用系统的下拉菜单，跟上面两个一样。
            // 之前自己拼分段控件，是因为分段样式会把 Label 的图标整个丢掉；
            // 菜单样式不丢 —— 收起来时是「图标 + 当前值」，点开是每项一个图标，
            // 所以带图标这件事交给 Label 就行，不用再造轮子。
            Picker("保存位置", selection: $settings.saveDestination) {
                ForEach(SaveDestination.allCases) { destination in
                    Label {
                        Text(destination.displayName)
                    } icon: {
                        Self.menuIcon(destination.systemImage)
                    }
                    .tag(destination)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("下载设置")
        } footer: {
            // 组外注释：说的是这一组存到哪儿的事，但它既不是选项也不是提示标题，
            // 挂在组底下比在组里再占一行干净。图标跟着注释一起走，
            // 认脸比认字快 —— 一眼就知道这是句说明。
            Label("下载的纯音频将始终保存到「文件」", systemImage: "info.circle")
        }
    }

    /// 「并行下载」那一行。数摆在步进器左边，不是当步进器的标签 ——
    /// 当标签的话数是跟加减号一起画在右边的，跟上面几行「标签在左、值在右」
    /// 对不齐。单独一个 Text，位置跟 Picker 收起来时那个值落在同一列。
    private var parallelRow: some View {
        LabeledContent("并行下载") {
            HStack(spacing: 8) {
                Text("\(settings.maxConcurrentDownloads)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(
                    "并行下载",
                    value: parallelBinding,
                    in: AppSettings.concurrentRange
                )
                .labelsHidden()
            }
        }
    }

    /// 并行任务数那个步进器的绑定。
    ///
    /// 提醒只在「从 1 调上去」这一步出：并行是这一步才引入的，
    /// 风险也是这一步才有的。已经在并行了再从 2 调到 5，人早就看过那句话了，
    /// 每动一格弹一次只会变成碍事的东西 —— 那种一出来就被点掉的提示，
    /// 到真出事的时候也没人看。
    private var parallelBinding: Binding<Int> {
        Binding(
            get: { settings.maxConcurrentDownloads },
            set: { newValue in
                if settings.maxConcurrentDownloads <= 1, newValue > 1 {
                    confirmingParallel = true
                }
                settings.maxConcurrentDownloads = newValue
            }
        )
    }

    // MARK: - 解析设置

    private var parseSection: some View {
        Section {
            // 默认关。开着的时候每次打开 App 都会读一次剪贴板，
            // 而读剪贴板系统会弹「允许粘贴」—— 得让用户自己点头开这个功能。
            // 这两个不给图标：开关的说明全在名字里，
            // 再挂个图标只是多一个要认的东西。
            Toggle("自动检测剪贴板", isOn: $settings.autoDetectClipboard)

            // 默认开。关掉是为了少发请求防风控：封面图是唯一「只为好看」的流量。
            Toggle("自动拉取封面", isOn: $settings.autoFetchCovers)

            // 默认关。开了之后收藏夹和合集里那些「已失效视频」「该合集已失效」
            // 就不再出现 —— 它们下不了，点进去也只有一句报错。
            Toggle("隐藏失效内容", isOn: $settings.filterInvalidContent)
        } header: {
            Text("解析设置")
        }
    }

    // MARK: - 快捷指令

    /// 装快捷指令的两个入口，都跳到 iCloud 链接去装。
    /// 分开两条是因为唤起方式不一样：直装的用普通那条就行，
    /// 装在 LiveContainer 里的得走带中转的那条，普通那条唤不动 guest app。
    /// 自己编快捷指令要用的前缀也摆在这组末尾 ——
    /// 它跟这两条是一件事：都是「怎么让外部把链接递进来」。
    private var shortcutSection: some View {
        Section {
            shortcutRow("安装快捷指令", url: Self.directShortcutURL)
            shortcutRow("安装快捷指令(LiveContainer)", url: Self.containerShortcutURL)
            urlSchemeRow
        } header: {
            Text("快捷指令")
        }
    }

    /// 复制 URL Scheme 前缀。右边只留一个复制图标 ——
    /// 那串前缀摆出来也没人真去读它，点一下复制走才是它唯一的用法。
    @ViewBuilder
    private var urlSchemeRow: some View {
        if let prefix = shortcutPrefix {
            Button {
                UIPasteboard.general.string = prefix
                hud = HUD(icon: "doc.on.doc.fill", text: "已复制 \(prefix)")
            } label: {
                HStack {
                    Text("复制URL Scheme")
                        .foregroundStyle(.primary)
                    Spacer()
                    // 该是黑的就得是黑的。Button 会把自己那套强调色刷到整个 label 上，
                    // 光在里面的 Text 上写 .foregroundStyle(.primary) 压不住它 ——
                    // 得把按钮样式换成 plain，标签才按自己写的颜色走。
                    trailingIcon("doc.on.doc")
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 行尾那个小图标。这一组里三个（两个装快捷指令 + 复制前缀）都用它，
    /// 大小和颜色就统一了 —— 之前一个 footnote 一个默认字号，
    /// 摆在一起一个粗一个细，看着像两个不同的控件。
    ///
    /// 字号跟行里那句话（`body`）一样大：`footnote` 比旁边的字矮一截，
    /// 摆在行尾像没长开。就用系统的字号档，别自己画。
    private func trailingIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(.secondary)
    }

    private func shortcutRow(_ title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                // 点了是跳出去装东西，不是进下一级，所以不用 chevron
                trailingIcon("arrow.up.forward.app")
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本信息", value: Bundle.main.versionText)

            // 「源代码」是标题，地址是右边的值 —— 跟这一组其他几行一个摆法。
            // 别把地址拼进标题里：拼起来是一长条蓝字，看着不像一行设置。
            //
            // 地址不摆 "https://"：那是纯噪音，没人靠它判断这链接点不点得动。
            // 点下去走的还是上面那条带 scheme 的完整 URL（见 repositoryText）。
            //
            // 整行都是按钮（不只是那个地址）：一行里只有几个字能点，点偏一点
            // 就没反应，是最容易让人以为「这个链接坏了」的一种摆法。
            // 样式得写 plain —— 默认那套会把强调色刷满整个 label，
            // 标题就不是主色了（见下面 urlSchemeRow 里那段）。
            Button {
                openURL(Self.repositoryURL)
            } label: {
                HStack {
                    Text("源代码")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Self.repositoryText)
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("关于程序")
        }
        .task { cacheSize = CacheCleaner.totalSize() }
    }

    /// 清理缓存。**自己一组，摆在整页最下面。**
    ///
    /// 原来它跟版本信息同属「关于程序」，但这两件事没关系：上面那组是
    /// 「这是哪个版本、代码在哪」，这一行是「占了我多少地方、清掉」。
    /// 分组标题只管上面那件事，所以这一行得拎出来单独摆 ——
    /// 不要组标题：一个人一行的组，标题只会让人以为下面还有别的东西。
    ///
    /// 这条就保持蓝色。默认的按钮样式会把强调色刷到标签上，
    /// 正是这儿想要的效果 —— 别学上面那条加 .buttonStyle(.plain)，
    /// 也别在 Text 上写 .foregroundStyle，压不住也没意义。
    private var cacheSection: some View {
        Section {
            Button {
                Task { await clearCache() }
            } label: {
                HStack {
                    Text("清理缓存")
                    Spacer()
                    if isClearingCache {
                        ProgressView()
                    } else if cacheSize > 0 {
                        Text(Self.sizeText(cacheSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isClearingCache)
        }
    }

    private func clearCache() async {
        isClearingCache = true
        let start = Date()

        CacheCleaner.clearAll()
        cacheSize = CacheCleaner.totalSize()

        // 清得太快的话转圈会一闪而过，看不到任何反馈，给个最短显示时间
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.4 {
            try? await Task.sleep(nanoseconds: UInt64((0.4 - elapsed) * 1_000_000_000))
        }
        isClearingCache = false
    }

    /// 两条快捷指令的安装地址。走 iCloud 链接，用户点一下就能进「快捷指令」
    /// App 里安装，我们不用自己维护分发。
    private static let directShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/1da6111cab4f47b08956fe03fea9b8f1"
    )!
    private static let containerShortcutURL = URL(
        string: "https://www.icloud.com/shortcuts/ec9089b10db44b5bb32a292b94e2516e"
    )!

    /// 项目主页。「关于程序」那行点开的就是它。
    private static let repositoryURL = URL(string: "https://github.com/lihaoyun6/BiliDown")!

    /// 界面上显示的那个地址：把 scheme 去掉。
    /// 从 `repositoryURL` 上剥，不另写一份 —— 两个常量早晚会有一个忘了改。
    private static var repositoryText: String {
        repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// 快捷指令里直接能用的前缀：后面接上链接就是一条完整的唤起 URL。
    /// 这段里面只有 scheme 是从 Info.plist 读的，剩下的是给人看的约定 ——
    /// 接收端其实只认字符串里的链接，路径和参数名叫什么都不挑。
    private var shortcutPrefix: String? {
        Bundle.main.urlScheme.map { "\($0)add?url=" }
    }

    /// 下拉里那个小图标。
    ///
    /// 尺寸得在**造这张图的时候**定死：菜单项和收起后的当前值都是交给 UIKit 画的
    /// （一个 UIAction 的 image），UIKit 按图片自己的尺寸摆，跟旁边文字多大没关系。
    /// 所以 .font / .imageScale 那套到这儿不作数 —— 那是 SwiftUI 侧的，
    /// 转成 UIAction 的时候就丢了，图标依旧按默认字号（17pt）画出来，
    /// 跟行里的字一比就显得大。
    ///
    /// 13pt 是照着菜单里那行文字的视觉重量挑的，比默认小一号但不至于缩成一点。
    private static func menuIcon(_ symbol: String) -> Image {
        let size = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return Image(uiImage: UIImage(systemName: symbol, withConfiguration: size) ?? UIImage())
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private extension Bundle {
    /// 「v1.0 (30)」：小写 v 打头的版本号，空格，括号里的构建号。
    /// 两个号都从 Info.plist 读，不在这儿再写死一份。
    var versionText: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    /// 界面上显示的前缀从 Info.plist 里读，不在这儿再写死一遍 ——
    /// 写死两处，早晚有一处会忘记跟着改。
    var urlScheme: String? {
        let types = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        let schemes = types?.first?["CFBundleURLSchemes"] as? [String]
        guard let scheme = schemes?.first else { return nil }
        return "\(scheme)://"
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
        .environmentObject(AccountStore())
}
