import SwiftUI

extension View {

    /// `onChange(of:) { 旧值, 新值 in }` 这个两参数写法是 macOS 14 才有的，
    /// 而 macOS 那头的下限钉在 13。
    ///
    /// 语义上我们要的从来只有新值（全工程没有一处用到旧值），所以在这儿
    /// 收成一个口子，平台差异不散到每一个视图里去 —— 不然以后每写一个
    /// 共享视图都得记着「别用 onChange」，早晚踩。
    ///
    /// 调用点一律写 `onChangeCompat`。
    @ViewBuilder
    public func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            // 单参数那版从 macOS 14 起标了 deprecated，但在 13 上它才是
            // 可用的那个。部署下限是 13，编译器不会为这个分支报警告。
            onChange(of: value, perform: action)
        }
        #else
        // iOS 那边下限是 17，这个 API 一直都在，没什么好分支的
        onChange(of: value) { _, new in action(new) }
        #endif
    }
}
