import CoreGraphics

/// 列表行的几把尺子：封面多大、行多高、行里那两行字之间那道缝。
///
/// **全 App 的列表行都按这几个数来** —— 下载队列、添加任务解析出来的那几个视频、
/// 收藏夹 / 合集里点进去的视频列表，还有它们外面那层夹子列表：封面一样大、
/// 行一样高、字缝一样宽。这几页是来回翻的，尺寸不统一，翻进翻出就一跳一跳。
///
/// 两端共用这一把尺子（字号各用各的，见 `Typography`）。
///
/// ### 这几个数是怎么定下来的
///
/// 96 × 56 是从**下载队列那一行**反推的：那一行要塞三行东西
/// （标题 + 进度条 / 分 P 副标题 + 状态），量下来 54 打底，56 才不挤。
/// 它是全 App 要求最高的一行，所以拿它当基准，别的列表长到这个尺寸 ——
/// 反过来把队列压到 45 是压不住的。
///
/// 调大小就改下面这几个数，别在各自的视图里另写一份。
public enum ListRowMetrics {

    /// 封面多宽多高。一块 16:9 的封面铺满这一格（`fill`，裁掉一点边）。
    public static let coverWidth: CGFloat = 96
    public static let coverHeight: CGFloat = 56

    /// 行里那两行字之间那道缝。
    ///
    /// 以前两端各写各的（iOS 拿 Spacer 把两行撑到封面的上下沿，mac 写死一个数），
    /// 现在是同一个值：两行字合成一块，整块在那 56 里居中 ——
    /// 标题不再顶着上沿、信息行不再吊在下沿。
    ///
    /// **只给两行字的行用**（收藏夹 / 合集那层夹子列表）。三行字的行
    /// （视频行、队列里的任务行）用下面那两道缝，见 `titleGap` / `infoGap`。
    public static let textSpacing: CGFloat = 9

    // MARK: - 三行字的行

    /// 三行字的行（标题 / BV 号 / UP 主，队列里是标题 / 进度 / 状态）里，
    /// 第一道缝：标题和**下面那一块**之间。
    ///
    /// 三行挤在 56 里，缝得比两行那种（9）窄得多 —— mac 上 16 + 15 + 15 已经
    /// 占掉 46，两道缝加起来只剩 10 点。
    public static let titleGap: CGFloat = 4

    /// 第二道缝：下面那两行**之间**（BV 号和 UP 主、副标题和状态）。
    ///
    /// 比上面那道再窄一点：这两行说的是同一件事的两半，凑成一组看才对。
    public static let infoGap: CGFloat = 3

    /// 行里那种**小字一行**的高度（BV 号那行、UP 主那行；队列里是
    /// 进度条 / 分 P 副标题那一档和底下状态那一档）。
    ///
    /// 钉死不是为了好看，是为了**对齐**：某一行没字可写的时候（整批来源没有
    /// UP 主名、排着队的任务中间那档空着）也得占着这么高，不然那一行的几行字
    /// 会整体往下掉一截，夹在有字的行中间一眼就看出来。
    ///
    /// 16 是两端 `Typography.caption` 里高的那个（mac 量出来 15，iOS 16）。
    public static let infoLineHeight: CGFloat = 16

    // MARK: - 视频行那一档

    /// 三行字的**视频行**的封面。就是上面那档，**但 iOS 上小一圈**。
    ///
    /// 手机上横向本来就紧：96 宽的封面一摆，右边那三行字只剩半截，
    /// BV 号这种一个字符都不能少的还得缩着写。mac 窗口宽，没这个毛病，
    /// 所以这一档只在 iOS 上收 —— 收的是「手机屏幕窄」这件事，不是这一行本身。
    ///
    /// 高只压到 54：那三行字自己就有 54.9（iOS 的标题 15 号量出来 17.9，
    /// 加下面那两道缝和两个 16）—— 比封面高不到 1 点，余量上下平分，
    /// 字不会从封面底下探出来。这两道缝各让出 1 点（见下面），封面正好矮得下这 2 点。
    /// 宽按这个高度配，块看着还是 16:9 那副样子。
    public static var videoCoverWidth: CGFloat {
        #if os(macOS)
        coverWidth
        #else
        88
        #endif
    }

    public static var videoCoverHeight: CGFloat {
        #if os(macOS)
        coverHeight
        #else
        54
        #endif
    }

    /// 视频行第一道缝（标题 ↔ 下面那一块）。iOS 比上面那档窄 1 点。
    ///
    /// 56 那口锅里挤着三行字，iOS 的字号还大一档（14 + 12 + 12），
    /// 缝不收一点整块就顶到封面的上下沿了。mac 不动。
    public static var videoTitleGap: CGFloat {
        #if os(macOS)
        titleGap
        #else
        3
        #endif
    }

    /// 视频行第二道缝（BV 号 ↔ UP 主）。同样只在 iOS 收 1 点。
    public static var videoInfoGap: CGFloat {
        #if os(macOS)
        infoGap
        #else
        2
        #endif
    }

    // MARK: - mac 的行边距

    /// mac 上列表行上下各垫这么多，**iOS 不用**。
    ///
    /// iOS 那套 `List`（insetGrouped）自己会给行留上下边距，mac 这套基本是贴着的 ——
    /// 同一批视频，mac 上一列扫下来密得多，行与行像是粘在一起。
    /// 这个数只写在这一处：用它的地方是 mac 的收藏夹 / 合集列表、
    /// 点进去的那个视频列表、添加任务那页的解析列表。
    public static let macRowVerticalPadding: CGFloat = 2
}
