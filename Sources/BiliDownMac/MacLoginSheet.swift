import SwiftUI
import BiliKit
import BiliUI
import WebKit

/// 内嵌 B 站官方登录页。账号密码只进 B 站自己的表单，App 不碰。
/// 跟 iOS 版是同一个做法，只是 WKWebView 换成了 NSViewRepresentable。
///
/// 进来之前用户已经在菜单里挑好了 `mode`（扫码 / 账号），这一页只把对应的
/// 那半页摆出来 —— 另一半由 `LoginPageStyle` 在网页里藏掉。
struct MacLoginSheet: View {

    let mode: LoginMode

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            MacLoginWebView(mode: mode) { credential in
                account.save(credential)
                dismiss()
            }

            if let message {
                Divider()
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }

            Divider()

            HStack {
                Text("在页面里完成登录后会自动读取，也可以点右边的按钮手动确认一次。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("我已登录") { checkNow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // 600 × 430。这两个数是**量出来的**，不是估的。
        //
        // 宽度：控件本体 386（扫码）/ 402（账号），居中由 `LoginPageStyle` 现算
        // —— 它把 `#app` 收到控件宽、再给一个 (窗口宽 - 控件宽) / 2 的左边距，
        // 页面跟着一起重排。所以**窗口多宽控件都在正中间**，这个宽度本身不再是
        // "够不够装下"的问题。600 是按观感定的：两侧各让出约 100（量出来
        // 99 / 107），两边对称。
        //
        // 高度：控件量出来是 y=40…340（扫码）/ 318（账号）—— 卡片自带的那 20
        // 顶留白被归零之后是从 10 起，再加上上面给的 30 定留白（见调用处的
        // `appTopMargin`）。底下再留一截，网页那部分给 385；加上最下面那排
        // 按钮的 45，就是 430。文档高度正好 385，不会滚。
        //
        // 窗口窄到比控件本体还窄（比如 386 以下）时会两边各切一点，那是控件
        // 本身就装不下，没别的办法 —— 排版本身已经不会横向溢出了。
        .frame(minWidth: 600, minHeight: 430)
    }

    private func checkNow() {
        isChecking = true
        Task {
            defer { isChecking = false }
            if let credential = await BiliCookieStore.currentCredential() {
                account.save(credential)
                dismiss()
            } else {
                message = "还没读到登录 Cookie，请先在页面里完成登录。"
            }
        }
    }
}

/// 包一层 WKWebView。每次导航结束都顺手查一下 Cookie，
/// 登录成功后 B 站会跳转，这时就能直接拿到底。
private struct MacLoginWebView: NSViewRepresentable {

    let mode: LoginMode
    let onCredential: (BiliCredential) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredential: onCredential)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // 登录页那点样式调整，跟 iOS 那份是同一段脚本 —— 见 `LoginPageStyle`。
        // 两处跟 iOS 不一样：
        //   · "输入框字号抬到 16px"这里不要 —— mac 上点输入框不会自动放大；
        //   · 网页顶上留 30px —— 这扇窗的网页上面**没有标题栏**，不留的话
        //     控件贴着窗口上沿（iOS 那头顶着导航栏，不用再留）。
        configuration.userContentController.addUserScript(
            LoginPageStyle.userScript(for: mode, raisesInputFont: false, appTopMargin: 30))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 内容不满一屏时底下那条是 webView 自己在涂，默认那个灰跟页面 body
        // 一个色 —— 钉成白的，见 `pinContentBackgroundToWhite`
        webView.pinContentBackgroundToWhite()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 桌面 UA 本来就是 mac 的原生身份，不用像 iOS 那样假装
        webView.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}


    final class Coordinator: NSObject, WKNavigationDelegate {

        private let onCredential: (BiliCredential) -> Void
        private var hasDelivered = false

        init(onCredential: @escaping (BiliCredential) -> Void) {
            self.onCredential = onCredential
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
        }

        private func checkCookies() {
            Task { @MainActor in
                guard !hasDelivered, let credential = await BiliCookieStore.currentCredential() else { return }
                hasDelivered = true
                onCredential(credential)
            }
        }
    }
}
