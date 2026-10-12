import SwiftUI
import UIKit

/// 把标签栏那枚角标往左挪几个点。
///
/// `.badge` 画在哪儿是系统定的，SwiftUI 没有这个参数 —— 它默认把角标摆在
/// 图标外框的右上角，**整个探在图标外面**，看着像挨着图标放着而不是挂在图标上。
/// 想挪只有一个口子：UIKit 的 `UITabBarAppearance.badgePositionAdjustment`。
///
/// **正数是往左**（离屏量过：+4 把角标从 x=80 挪到 76，一比一线性。
/// 图标外框右边缘是 85）。数值见 `RootView.badgeLeftShift`。
///
/// 它自己不画任何东西，只是借「进了视图树」拿到那个 `UITabBar`：
/// 从窗口往上往下找第一个 `UITabBar`。
///
/// **不走响应链**。原来是从自己这个视图顺着 `next` 往上找 `UITabBarController`，
/// 结果一动不动 —— 挂 `.background` 的这个视图在 UITabBarController **外面**
///（TabView 就是那个控制器，背景是它外面又包的一层），响应链上根本没有它。
/// 从窗口里找就没有这个前提，挂在哪儿都行。
///
/// 改的是**它现有那两份 appearance**（改完再赋回去，UIKit 才会重画），
/// 不新建一份盖上去 —— 所以背景、毛玻璃、「有内容钻到它底下才变色」那套行为
/// 一概不动（那几条是 `RootView` 里特意不去碰的）。
struct TabBarBadgeOffset: UIViewRepresentable {

    /// 往左挪几个点。
    let horizontal: CGFloat

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // 视图刚造出来这一下还没进窗口树，等下一帧
        DispatchQueue.main.async { apply(from: view, attempt: 0) }
    }

    private func apply(from view: UIView, attempt: Int) {
        if let tabBar = Self.tabBar(in: view.window) {
            Self.shift(tabBar, by: horizontal)
            return
        }
        // 窗口树的这一趟可能还没建到标签栏。重试几帧就够（0.5 秒内一定建好了）；
        // 真没找到也不出声 —— 这枚角标只是位置差几个点，犯不上为它报错。
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
            guard let view else { return }
            apply(from: view, attempt: attempt + 1)
        }
    }

    /// 窗口里第一个标签栏。整个 App 就一条，不用管是哪一条。
    private static func tabBar(in window: UIWindow?) -> UITabBar? {
        guard let window else { return nil }
        var found: UITabBar?
        func walk(_ view: UIView) {
            if found != nil { return }
            if let bar = view as? UITabBar { found = bar; return }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return found
    }

    private static func shift(_ tabBar: UITabBar, by horizontal: CGFloat) {
        let offset = UIOffset(horizontal: horizontal, vertical: 0)

        func adjusted(_ appearance: UITabBarAppearance) {
            for layout in [
                appearance.stackedLayoutAppearance,
                appearance.inlineLayoutAppearance,
                appearance.compactInlineLayoutAppearance,
            ] {
                // 四个状态都得给：漏掉 selected 的话，切到「下载」这一栏
                //（角标所在的那个标签自己选中了）时，角标会自己蹦回系统那个位置。
                layout.normal.badgePositionAdjustment = offset
                layout.selected.badgePositionAdjustment = offset
                layout.disabled.badgePositionAdjustment = offset
                layout.focused.badgePositionAdjustment = offset
            }
        }

        let standard = tabBar.standardAppearance
        adjusted(standard)
        tabBar.standardAppearance = standard

        if let edge = tabBar.scrollEdgeAppearance {
            adjusted(edge)
            tabBar.scrollEdgeAppearance = edge
        }
    }
}
