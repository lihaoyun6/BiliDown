import SwiftUI

/// 「列表里没东西」的三种状态 —— 正在读、读失败、空的 ——
/// 一律画成列表里的普通一行，而不是把整个根视图换掉。
///
/// 换根视图（ProgressView → List）会把滚动视图整个重建，重建那一帧安全区
/// 还没传到新视图上，列表内容会先铺满整屏再被顶回去，看起来就是
/// 底部标签栏上面闪了一下。列表一直是同一个 List 就没这回事。
public struct LoadingRow: View {

    @State private var visible = false

    public init() {}

    /// 什么都不画。加载常常几百毫秒就完了，先摆个转圈再被内容顶走反而更闪。
    /// 真的慢了才让它浮出来 —— 就是个光转圈，不带白块、不带行背景。
    public var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .opacity(visible ? 1 : 0)
            Spacer()
        }
        .frame(height: 44)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            visible = true
        }
    }
}

/// 空列表 / 读失败时列表里那一块提示，替代 ContentUnavailableView。
/// 后者是给整屏用的（自己带一大截外边距），塞进列表行里当一行画，
/// 间距立刻散架 —— 这里要的是「列表里的一行」，所以自己画。
public struct ListPlaceholder: View {

    let icon: String
    let title: String
    var message: String?
    var retry: (() -> Void)?

    public init(icon: String, title: String, message: String? = nil, retry: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(title)
                .font(Typography.placeholderTitle)
                .foregroundStyle(.primary)

            if let message {
                Text(message)
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// 「滚到底了，正在拉下一页」的那行转圈。跟 LoadingRow 一个道理：
/// 翻页常常几十毫秒就回来了，立刻画个圈、下一帧又被新内容顶走，
/// 看着就是底部闪一下。所以先等 0.4 秒，真慢才出来。
public struct LoadMoreSpinner: View {

    @State private var visible = false

    public init() {}

    public var body: some View {
        Group {
            if visible {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            visible = true
        }
    }
}
