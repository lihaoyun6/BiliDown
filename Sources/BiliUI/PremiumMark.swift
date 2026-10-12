import SwiftUI

/// 「这条要钱」那枚标记：粉底圆里一个白色实心闪电。
///
/// 一个东西两个摆放，都从这儿出 —— 别在各自的视图里各画一份，改一次要满世界找：
///
/// - **封面左下角**（`CoverThumbnail.premiumMark`）：收藏夹 / 合集 / 解析结果
///   那些列表行。直径给的就是右下角画质气泡的高度，一左一右两颗角标
///   一样大才像一对。
/// - **标题前面**（`JobRowView`）：下载队列那一行。那儿封面归画质气泡用，
///   而且这一行本来就密、封面又小，标记摆在标题前比压在封面上好认；
///   那一档给 12 而不是 14 —— 这一行的尺子换成了标题的字高，
///   14 摆在 13pt 的标题前面，那个圆比字还重，看着像个项目符号。
///
/// 判据（哪种视频算「要钱」）在 `VideoInfo.isPremium`：充电专属、付费合集、
/// PGC 付费、UGC 付费四种说法归一个答案。拉不到这个信息的来源就不画 ——
/// 这枚标记**不猜**，猜错了就是给一条正常视频挂个「要钱」的牌子。
public struct PremiumMark: View {

    /// 圆的直径，也是这一枚占的方框。
    public var diameter: CGFloat

    public init(diameter: CGFloat) {
        self.diameter = diameter
    }

    /// 闪电的字号从直径推，不另外给一个数：圆一大一小两档（14 / 12），
    /// 字号各自钉死的话，两处的比例就对不上了。
    ///
    /// 0.64 是**量出来的**。离屏量过白墨迹在圈里的实际尺寸：
    ///
    /// | 字号 | 闪电 | 占圆的 |
    /// |------|------|--------|
    /// | 8    | 5.83 × 8.92  | 高 64% |
    /// | 9    | 6.50 × 10.08 | 高 72% |
    /// | 10   | 7.25 × 11.25 | 高 80% |
    ///
    /// 取的是 72% 那一档（`bolt.fill` 竖着占满一个字高，所以字号 9 在
    /// 直径 14 的圆里正好量到 10.08 高；9 ÷ 14 = 0.64）。再小细得像根针，
    /// 再大上下就只剩 1pt 粉边了。
    private var boltPointSize: CGFloat { diameter * 0.64 }

    /// B 站那个粉（#FB7299）。不是随手挑的：PGC 接口给分集角标时
    /// `badge_info.bg_color` 报的就是这个色。别换成强调色 ——
    /// 这枚标记说的是「这条要钱」，跟「这儿能点」是两件事。
    static let pink = Color(red: 0.984, green: 0.447, blue: 0.600)

    public var body: some View {
        // 不加描边、不加阴影：B 站自己那枚也是这样，一个纯色圆。
        // 摆在亮封面上确实可能有点糊在一起，但描一圈黑边在深色封面上又会很脏 ——
        // 白闪电本身就够认了。
        Image(systemName: "bolt.fill")
            // semibold 而不是 bold：圆才这么点大，再粗就糊成一团白了
            .font(.system(size: boltPointSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Self.pink, in: Circle())
            // 旁白读封面 / 读这一行时得念出来「这是要钱的」，不然只剩一张图
            .accessibilityLabel("付费或充电专属")
    }
}
