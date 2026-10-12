import SwiftUI
import BiliKit
import BiliUI
import WebKit

/// 内嵌 B 站官方登录页。账号密码只进 B 站自己的表单，App 不碰。
///
/// 进来之前用户已经在菜单里挑好了 `mode`（扫码 / 账号），这一页只把对应的
/// 那半页摆出来 —— 另一半由 `LoginPageStyle` 在网页里藏掉。
struct LoginSheet: View {

    let mode: LoginMode

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            LoginWebView(mode: mode) { credential in
                account.save(credential)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("登录 B 站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Button("我已登录") { checkNow() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
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
private struct LoginWebView: UIViewRepresentable {

    let mode: LoginMode
    let onCredential: (BiliCredential) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredential: onCredential)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // **两端都走移动内容模式**，这条是关键。
        //
        // 这一档的默认值是 `.recommended`，意思是"按当前有多宽自己挑"——
        // 结果 iPad 上挑到**桌面**模式：忽略页面的 `width=device-width`，
        // 按桌面宽度（~1000px）排版，再整页缩进容器里。看着"完整"，
        // 但那字小得没法用，而且跟我们下面的提示逻辑对不上。
        //
        // 钉成 `.mobile` 之后，iPad 跟 iPhone 就是同一套：
        // 排版宽度 = 容器宽，桌面版那份 HTML 塞不下就只露左边一列。
        //
        // 注意这跟下面那个 `customUserAgent` 是**两码事**：UA 决定服务端
        // 发哪份 HTML（两边都发桌面版，没变），这一档决定排版和缩放规则。
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        // 「只留选中的那半页」那段脚本，跟 mac 那份是同一份
        // —— 归在 `LoginPageStyle` 里，只此一处。
        //
        // 这边多要一样东西：把输入框字号抬到 16px。iOS 上点进字号小于 16 的
        // 输入框会自动把页面放大一点，这页的框正好是 14px（见 `script` 第 3 条）。
        //
        // 顶留白不要：这页头顶就是导航栏，跟 mac 那边不一样（见 `appTopMargin`）。
        configuration.userContentController.addUserScript(
            LoginPageStyle.userScript(for: mode, raisesInputFont: true, appTopMargin: 0))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 内容不满一屏时底下那条是 webView 自己在涂，默认那个灰跟页面 body
        // 一个色 —— 钉成白的，见 `pinContentBackgroundToWhite`
        webView.pinContentBackgroundToWhite()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.desktopUserAgent
        webView.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
        return webView
    }

    /// 每次刷新界面都要实现，但这里**没活可干**：宽度变化网页自己盯着
    ///（`LoginPageStyle` 里挂了 resize），不靠外面推。
    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// B 站登录页在桌面 UA 下更稳定，短信/扫码两条路都通。
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"


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
