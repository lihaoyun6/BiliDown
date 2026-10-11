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

    /// 气泡离封面两条边的距离。别贴着边，也别离太远 ——
    /// 那张图本身不大，缩进多了气泡就飘在画面中间了。
    private static let badgeInset: CGFloat = 4

    @ObservedObject private var covers = CoverImageStore.shared

    public init(
        url: URL?,
        width: CGFloat = ListRowMetrics.coverWidth,
        height: CGFloat = ListRowMetrics.coverHeight,
        placeholderSystemImage: String = "film",
        cornerRadius: CGFloat = 4,
        badge: String? = nil
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.placeholderSystemImage = placeholderSystemImage
        self.cornerRadius = cornerRadius
        self.badge = badge
    }

    /// **视频行**（三行字那种行：添加任务的解析列表、收藏夹 / 合集里的视频列表）
    /// 里那块封面：尺寸比通用那档小一圈，见 `ListRowMetrics.videoCoverWidth`。
    ///
    /// 那三页是来回翻的，尺寸得一模一样，所以收在这一处 —— 别在各自的视图里
    /// 各写一对数，改一次要满世界找。
    public static func videoRow(url: URL?, badge: String? = nil) -> CoverThumbnail {
        CoverThumbnail(
            url: url,
            width: ListRowMetrics.videoCoverWidth,
            height: ListRowMetrics.videoCoverHeight,
            badge: badge
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
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                // 白底封面上白字等于没写，所以自己带一层深色底。
                .background(
                    Color.black.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                )
                .padding(Self.badgeInset)
        }
    }
}
