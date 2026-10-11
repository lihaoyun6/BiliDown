import SwiftUI
import BiliKit
import WebKit

/// 内嵌 B 站官方登录页。账号密码只进 B 站自己的表单，App 不碰。
/// 跟 iOS 版是同一个做法，只是 WKWebView 换成了 NSViewRepresentable。
struct MacLoginSheet: View {

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            MacLoginWebView { credential in
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
        .frame(minWidth: 520, minHeight: 620)
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

    let onCredential: (BiliCredential) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCredential: onCredential)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
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
