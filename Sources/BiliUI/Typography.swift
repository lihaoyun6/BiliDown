import SwiftUI

/// 共享视图里所有字号都从这儿取。
///
/// SwiftUI 那套语义字号在两端映射到的点数是**不一样**的：
/// `.subheadline` 在 iOS 是 15pt，到 macOS 只剩 11pt；`.caption` 是 12 / 10；
/// `.caption2` 是 11 / 10。共享视图照着 iOS 的观感写 `.subheadline`，
/// 同一份代码搬到 mac 上就整整齐齐小一号 —— 单看还行，
/// 跟「系统设置」摆在一块就明显发虚。
///
/// 所以别在共享视图里直接写语义字号，走这儿。数值是按 macOS
/// 系统设置里那几档挑的：正文 13、说明 12、角标 11。
///
/// iOS 那几档给的跟语义字号**逐点相等**，所以 iOS 的观感一点没动。
public enum Typography {

    /// 列表行主标题。
    public static var rowTitle: Font {
        #if os(macOS)
        .system(size: 13, weight: .medium)
        #else
        .subheadline.weight(.medium)
        #endif
    }

    /// 列表行里不加粗的正文。
    public static var body: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .subheadline
        #endif
    }

    /// 空状态里那个大标题。
    ///
    /// macOS 这一档原来给的是 15，比 iOS 那边（`.headline`，17）还小一号 ——
    /// 摆在一个 40 的大图标底下，字被图标压得看不出是「标题」，
    /// 整块看着就是「一个大图标 + 一行灰字」。
    /// 现在拉到 20：mac 上系统自己那些空态（备忘录、音乐）就是这个量级，
    /// 大标题 + 小副标题的层次才立得住。
    /// iOS 不动，还是 `.headline`。
    public static var placeholderTitle: Font {
        #if os(macOS)
        .system(size: 20, weight: .semibold)
        #else
        .headline
        #endif
    }

    /// 次要说明：UP 主名、分 P 副标题、状态行。
    public static var caption: Font {
        #if os(macOS)
        .system(size: 12)
        #else
        .caption
        #endif
    }

    /// 最小那一档：角标、[P1] 标记。
    public static var micro: Font {
        #if os(macOS)
        .system(size: 11)
        #else
        .caption2
        #endif
    }

    /// 压在封面右下角那个小气泡里的字（分辨率、封面、音频）。
    ///
    /// 比 `micro` 再小一点，而且两端取同一个数：它盖在图上，字号一大
    /// 就吃掉封面。这档也比分 P 标记矮半头 —— 那两样东西会挨着出现。
    public static var badge: Font {
        .system(size: 10, weight: .semibold)
    }

    /// 页面主标题下面那句说明。
    public static var callout: Font {
        #if os(macOS)
        .system(size: 13)
        #else
        .callout
        #endif
    }
}
