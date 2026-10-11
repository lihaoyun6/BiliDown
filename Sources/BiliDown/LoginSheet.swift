import SwiftUI
import BiliKit
import WebKit

/// 内嵌 B 站官方登录页。账号密码只进 B 站自己的表单，App 不碰。
struct LoginSheet: View {

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            LoginWebView { credential in
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

    let onCredential: (BiliCredential) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredential: onCredential)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.desktopUserAgent
        webView.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
        return webView
    }

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
