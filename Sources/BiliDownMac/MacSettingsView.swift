import SwiftUI
import AppKit
import BiliCore
import BiliKit
import BiliUI

/// macOS 版的设置。跟 iOS 版差得最多的一页 ——
/// mac 没有相册，所以「保存位置」从一个二选一的下拉变成了一个真的路径。
struct MacSettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var confirmingParallel = false
    @State private var hud: HUD?

    // 账号那一块**不在这一页**：登录 / 退出登录挂在侧边栏最底下，
    // 跟 App Store 一个摆法。它是「当前是谁」，不是一项设置。

    var body: some View {
        Form {
            downloadSection
            parseSection
            shortcutSection
            aboutSection
            cacheSection
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        // 只提一句。数值照改不误 —— 这是个提醒，不是要用户再点一次头才生效。
        .alert("风险提示", isPresented: $confirmingParallel) {
            Button("好", role: .cancel) {}
        } message: {
            Text("并行下载可能会触发风控, 请谨慎使用!")
        }
        .hud($hud)
    }

    // MARK: - 下载设置（存哪儿 + 编成什么）

    private var downloadSection: some View {
        Section {
            Picker("视频编码", selection: $settings.videoCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            Picker("音频格式", selection: $settings.audioFormat) {
                ForEach(AudioFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }

            parallelRow

            // 保存位置就是一条路径。这里不给文本框让人手敲 ——
            // 打错的路径不会立刻报错，要等第一条下载失败才现形，
            // 所以只认 NSOpenPanel 选出来的那个 URL。
            LabeledContent("下载位置") {
                HStack(spacing: 8) {
                    Text(settings.downloadDirectory.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.downloadDirectory.path)

                    Button("选择…") { chooseFolder() }

                    // 「在访达中显示」原来自己占一行，现在收成一个文件夹图标摆在这儿 ——
                    // 它跟「选择…」本来就是同一件事的两头（挑一个 / 去看看那个），
                    // 挤在一处也省掉一整行。
                    Button {
                        showInFinder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("在访达中显示")
                    .disabled(!FileManager.default.fileExists(atPath: settings.downloadDirectory.path))

                    Button {
                        settings.downloadDirectory = AppSettings.defaultDownloadDirectory
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("恢复默认（~/Downloads/BiliDown）")
                    .disabled(settings.downloadDirectory == AppSettings.defaultDownloadDirectory)
                }
            }
        } header: {
            Text("下载设置")
        }
        // 这儿本来有一行「所有成品（视频和纯音频）都存到这个文件夹」的脚注。
        // 上面那行就是「保存位置」加一条完整路径，再补一句是替用户把话念一遍。
    }

    /// 「并行下载」那一行。数摆在步进器左边单独一个 Text，
    /// 不当步进器的标签 —— 当标签的话，数是跟加减号一起画在右边的，
    /// 会跟这一组里其他几行的标签错开一列。
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
    /// 提醒只在「从 1 调上去」这一步出：并行是这一步才引入的，风险也是这一步才有的。
    /// 已经在并行了再从 2 调到 5，人早就看过那句话了 —— 那种一出来就被点掉的提示，
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

    /// 选文件夹。不用 security-scoped bookmark —— 这个 App 不沙盒
    /// （跟 iOS 那边自签侧载的定位一致），拿到的 URL 直接就能写。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择下载文件保存到哪个文件夹"
        panel.directoryURL = settings.downloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url
        }
    }

    private func showInFinder() {
        let url = settings.downloadDirectory
        // 目录不存在时 activateFileViewerSelecting 会指向一个不存在的地方，
        // 开出来是个空窗口。自己先建出来。
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 解析设置

    private var parseSection: some View {
        Section {
            // macOS 读剪贴板不会像 iOS 那样弹「允许粘贴」，
            // 但这个开关保持默认关：不主动碰用户的剪贴板。
            Toggle("自动检测剪贴板", isOn: $settings.autoDetectClipboard)

            // 默认开。关掉是为了少发请求防风控：封面图是唯一「只为好看」的流量。
            Toggle("自动拉取封面", isOn: $settings.autoFetchCovers)

            // 默认关。开了之后收藏夹和合集里那些「已失效视频」就不再出现 ——
            // 它们下不了，点进去也只有一句报错。
            Toggle("隐藏失效内容", isOn: $settings.filterInvalidContent)
        } header: {
            Text("解析设置")
        }
    }

    // MARK: - 快捷指令

    /// 只有两条，跟 iOS 版也不是一组东西。
    ///
    /// 上面那条是**浏览器脚本**，不是 iOS 那种快捷指令：mac 上浏览 B 站的是
    /// 桌面浏览器，Tampermonkey 那类扩展才装得进浏览器里、才看得见页面上的链接。
    /// iOS 版那两条（直装 / LiveContainer）在这儿一条都没有 —— 快捷指令在 mac 上
    /// 唤 app 走的是同一套 scheme（系统按 scheme 直接就能唤起），
    /// 所以「装个快捷指令」这一步在这儿是多余的。
    ///
    /// URL Scheme 前缀也摆在这组末尾 —— 它跟上面那条是一件事：
    /// 都是「怎么让外部把链接递进来」。脚本那头最后也是拼出这个前缀再跳过来。
    ///
    /// **组名不点机制**：这两条一个是浏览器脚本、一个是复制前缀，谁也代表不了谁，
    /// 叫「快捷指令」现在更是名不副实（那已经不是 iOS 的那种快捷指令了）。
    /// 「快速访问」说的是这组真正共有的那件事 —— 从外面把链接递进来。
    private var shortcutSection: some View {
        Section {
            shortcutRow("安装浏览器脚本(Tampermonkey)", url: Self.browserScriptURL)
            urlSchemeRow
        } header: {
            Text("快速访问")
        }
    }

    /// 复制 URL Scheme 前缀。右边只留一个复制图标 ——
    /// 那串前缀摆出来也没人真去读它，点一下复制走才是它唯一的用法。
    @ViewBuilder
    private var urlSchemeRow: some View {
        if let prefix = shortcutPrefix {
            Button {
                MacPasteboard.copy(prefix)
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

    /// 行尾那个小图标。这一组里两条共用它，大小和颜色就统一了。
    ///
    /// 字号跟行里那句话（`body`）一样大。原来写的是 `footnote`，
    /// 比旁边的字矮一截，摆在行尾像没长开。就用系统的字号档，别自己画 ——
    /// 这儿没有顶栏那套「尺寸被盖掉」的脾气，系统符号直接给多大就是多大。
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

    /// 浏览器脚本的安装地址。Greasy Fork 上那个脚本页，点开是浏览器的活。
    /// 脚本干的跟 iOS 那条快捷指令是一回事 —— 把页面上的链接拼成
    /// `bilidown://add?url=…` 再跳过来（前缀见下面 `shortcutPrefix`）。
    private static let browserScriptURL = URL(
        string: "https://greasyfork.org/zh-CN/scripts/599703"
    )!

    /// 快捷指令里直接能用的前缀：后面接上链接就是一条完整的唤起 URL。
    /// 这段里面只有 scheme 是从 Info.plist 读的，剩下的是给人看的约定 ——
    /// 接收端其实只认字符串里的链接，路径和参数名叫什么都不挑。
    private var shortcutPrefix: String? {
        Bundle.main.urlScheme.map { "\($0)add?url=" }
    }

    // MARK: - 关于

    /// 项目主页。「关于程序」那行点开的就是它。
    private static let repositoryURL = URL(string: "https://github.com/lihaoyun6/BiliDown")!

    /// 界面上显示的那个地址：把 scheme 去掉。
    /// 从 `repositoryURL` 上剥，不另写一份 —— 两个常量早晚会有一个忘了改。
    private static var repositoryText: String {
        repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    /// 版权那一行写的字。跟系统「关于 BiliDown」面板底下那句是同一个来源：
    /// Info.plist 的 `NSHumanReadableCopyright`（键在 project.yml 里）——
    /// 那个面板只认 plist，设置页这儿就照着读，不在代码里另抄一份。
    private static var copyrightText: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("版本信息", value: Bundle.main.versionText)

            // 「源代码」是标题，地址是右边的值 —— 跟上面那行一个摆法。
            // 别把地址拼进标题里：拼起来是一长条蓝字，看着不像一行设置。
            //
            // 地址不摆 "https://"：那是纯噪音，没人靠它判断这链接点不点得动。
            // 点下去走的还是上面那条带 scheme 的完整 URL（见 repositoryText）。
            //
            // 整行都是按钮（不只是那个地址）：一行里只有几个字能点，点偏一点
            // 就没反应，是最容易让人以为「这个链接坏了」的一种摆法。
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

            // 版权。**值从 Info.plist 里读**（`NSHumanReadableCopyright`）——
            // 系统那个「关于 BiliDown」面板底下显示的是同一句，键在 project.yml 里。
            // 在这儿再写死一份的话，改了那处忘了这处，两边就开始不一样了。
            LabeledContent("版权", value: Self.copyrightText)
        } header: {
            Text("关于程序")
        } footer: {
            // 跟系统那个「关于 BiliDown」面板中间那行是同一句（见 `MacAppInfo`）。
            // 摆脚注而不是当一行设置：它不是个「值」，是一句说明。
            Text(MacAppInfo.tagline)
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
    /// 摆法：「缓存大小」是标题，多大是数据，动作在最右边 ——
    /// 三样东西各归各位：标题靠左，数值和按钮一起靠右，按钮在最右。
    /// 数值摆在按钮前面，跟上面「版本信息」那行的值落在同一片区域，
    /// 一列扫下来是对齐的。
    private var cacheSection: some View {
        Section {
            HStack {
                Text("缓存大小")
                Spacer()
                Text(Self.sizeText(cacheSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("清理缓存") {
                    Task { await clearCache() }
                }
                .disabled(isClearingCache || cacheSize == 0)
            }
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

    private static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension Bundle {
    /// 「v1.0 (32)」：小写 v 打头的版本号，空格，括号里的构建号。
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
