import AppKit

/// iOS 那边是 `UIPasteboard.general.string`，mac 是 NSPasteboard 那套
/// 「先 clear 再 set」的三步走。收敛在这儿，调用点两边写法才一样。
enum MacPasteboard {

    static var string: String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
