import SwiftUI
import BiliKit

/// 队列和收藏夹共用的封面缩略图。
public struct CoverThumbnail: View {

    let url: URL?
    /// 默认那对尺寸就是全 App 列表行的尺寸（见 `ListRowMetrics`）——
    /// 只有挑视频那种弹窗里的行自己另给一对小的（那边行矮）。
    var width: CGFloat = ListRowMetrics.coverWidth
    var height: CGFloat = ListRowMetrics.coverHeight
    var placeholderSystemImage: String = "film"
    /// 封面都待在 insetGrouped 的分组里，分组圆角大概 10 出头，
    /// 封面离分组边缘还内缩了一大截，所以这里得小一号才显得是同心缩进的。
    var cornerRadius: CGFloat = 4
    /// 右下角那个小气泡里的字（时长、分辨率、音频…）。不给就不画。
    var badge: String?
    /// 付费 / 充电专属的视频：左下角挂一枚粉色的标记（见 `premiumMark`）。
    ///
    /// 判据在 `VideoInfo.isPremium` 那一处（各接口的付费字段都在那儿归一）。
    /// 拉不到这个信息的来源就一直是 false —— 这枚标记**不猜**。
    var isPremium: Bool = false

    /// 气泡离封面两条边的距离。别贴着边，也别离太远 ——
    /// 那张图本身不大，缩进多了气泡就飘在画面中间了。
    private static let badgeInset: CGFloat = 4

    /// 右下角那个气泡的高度，**也是**左下角那枚付费标记的直径。
    ///
    /// 这两个数得一样（一左一右两颗角标，一样大才像一对），所以只写这一处：
    /// 气泡那边显式 `.frame(height:)` 钉死，圆这边直接拿它当直径（见
    /// `premiumMark`），走不散。
    ///
    /// 14 就是气泡原来的**实测高度**：里面一行 `Typography.badge`（10pt semibold）
    /// 大概 12 高，加上原来那圈 1pt 的上下内边距正好 14。改字号就得重新量一次。
    private static let badgeHeight: CGFloat = 14

    @ObservedObject private var covers = CoverImageStore.shared

    public init(
        url: URL?,
        width: CGFloat = ListRowMetrics.coverWidth,
        height: CGFloat = ListRowMetrics.coverHeight,
        placeholderSystemImage: String = "film",
        cornerRadius: CGFloat = 4,
        badge: String? = nil,
        isPremium: Bool = false
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.placeholderSystemImage = placeholderSystemImage
        self.cornerRadius = cornerRadius
        self.badge = badge
        self.isPremium = isPremium
    }

    /// **视频行**（三行字那种行：添加任务的解析列表、收藏夹 / 合集里的视频列表）
    /// 里那块封面：尺寸比通用那档小一圈，见 `ListRowMetrics.videoCoverWidth`。
    ///
    /// 那三页是来回翻的，尺寸得一模一样，所以收在这一处 —— 别在各自的视图里
    /// 各写一对数，改一次要满世界找。
    public static func videoRow(
        url: URL?,
        badge: String? = nil,
        isPremium: Bool = false
    ) -> CoverThumbnail {
        CoverThumbnail(
            url: url,
            width: ListRowMetrics.videoCoverWidth,
            height: ListRowMetrics.videoCoverHeight,
            badge: badge,
            isPremium: isPremium
        )
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)

            if let image = covers.image(for: url) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: height * 0.35, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        // 角标画在裁圆角之前：气泡自己收在框里，裁不裁都够不着边，
        // 但顺序这么摆，万一哪天气泡变大了也不至于先被切成方的。
        .overlay(alignment: .bottomTrailing) { badgeView }
        // 付费标记在另一个角，跟右下角那个气泡对称着摆（同一圈边距、一样高）
        .overlay(alignment: .bottomLeading) { premiumMark }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            covers.load(url)
        }
        // 把「自动拉取封面」从关拨到开时，已经挂在屏幕上的这几行也得跟着去取 ——
        // .task 只在 url 变了才重跑，光靠它这几行会一直停在占位图上。
        .onChangeCompat(of: covers.isFetchEnabled) { _ in
            covers.load(url)
        }
    }

    /// 右下角那个小气泡。
    ///
    /// 字是调用方给的（时长、画质、音频…），这一层只管摆位置和长相 ——
    /// 缩略图不该知道「480P」是什么意思，也不用为每种内容各留一个参数。
    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(Typography.badge)
                .monospacedDigit()
                // 一行截断，不给它换行也不给它超出封面：这里面最长的是
                // 「1080P60」和「1:02:33」，正常都放得下，写这一笔是为了万一。
                .lineLimit(1)
                .truncationMode(.tail)
                // 高度钉死成 `badgeHeight`（原来是上下各 1pt 的内边距，
                // 出来正好也是这么高）—— 左下角那枚圆的直径要跟它一般大，
                // 就得有个写死的数给两边共用。
                .frame(height: Self.badgeHeight)
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                // 白底封面上白字等于没写，所以自己带一层深色底。
                .background(
                    Color.black.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
                .padding(Self.badgeInset)
        }
    }

    /// 左下角那枚「这条要钱」的标记：粉色的圆，里面一个白色的实心闪电
    /// （长什么样、为什么是这个色，都在 `PremiumMark` 里）。
    ///
    /// 边距跟气泡同一个 `badgeInset`、直径就是气泡的高度 `badgeHeight` ——
    /// 两颗角标一左一右、一样大、一样离边，扫过去是一对。
    ///
    /// 下载队列那一行**不走这儿**：那儿的标记摆在标题前面（见 `JobRowView`），
    /// 参数也就各给各的。
    @ViewBuilder
    private var premiumMark: some View {
        if isPremium {
            PremiumMark(diameter: Self.badgeHeight)
                .padding(Self.badgeInset)
        }
    }
}
