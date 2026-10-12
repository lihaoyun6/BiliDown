import SwiftUI
import BiliCore
import BiliKit

/// 添加任务列表行左边那块图。视频和合集都是封面，UP 主是头像。
public enum InputThumbnail {
    case cover(URL?)
    case avatar(URL?)
}

/// 添加任务列表的通用行：左边一块图，右边几行字，
/// 有东西可挑的话尾巴上再挂个按钮。
/// 三种来源（视频 / 主页 / 合集）共用，省得各写一套还对不齐。
public struct InputRow: View {

    /// 左边那块图多大。就是**视频行**那一档（见 `ListRowMetrics.videoCoverWidth`）——
    /// 这一行跟收藏夹里那些视频行一样大，只是比下载队列那行在 iOS 上小一圈。
    private static var thumbSize: CGSize {
        CGSize(
            width: ListRowMetrics.videoCoverWidth,
            height: ListRowMetrics.videoCoverHeight
        )
    }

    let thumbnail: InputThumbnail
    let title: String
    var titleColor: Color = .primary
    /// 第二行的 UP 主名（视频行才有，整批来源没有这个概念）。
    /// **没有也得留着这一行的位置** —— 见 `VideoRowText`。
    var ownerName: String?
    /// 第三行：视频是 BV 号，整批来源是 UID / 合集 ID
    let identifier: String
    /// 封面上那个气泡里的字（单 P 视频的时长、多 P 视频的总 P 数）。
    /// 头像那种没有封面，用不上。
    var badge: String?
    /// 付费 / 充电专属：封面左下角挂枚粉色标记（见 `CoverThumbnail`）。
    /// 整批来源那两条不是「一个视频」，一直是 false。
    var isPremium: Bool = false
    /// 第三行**最右头**那句话（多 P 视频的「已选 3 P」）。
    var trailing: String?
    /// 有内容可挑才给按钮
    var onPick: (() -> Void)?

    @ObservedObject private var covers = CoverImageStore.shared

    public init(
        thumbnail: InputThumbnail,
        title: String,
        titleColor: Color = .primary,
        ownerName: String? = nil,
        identifier: String,
        badge: String? = nil,
        isPremium: Bool = false,
        trailing: String? = nil,
        onPick: (() -> Void)? = nil
    ) {
        self.thumbnail = thumbnail
        self.title = title
        self.titleColor = titleColor
        self.ownerName = ownerName
        self.identifier = identifier
        self.badge = badge
        self.isPremium = isPremium
        self.trailing = trailing
        self.onPick = onPick
    }

    /// 分 P 按钮上那个图标的大小。
    ///
    /// 不能写 `.body` 这类语义字号：mac 上 `.body` 是 13，iOS 上是 17，
    /// 同一个词在两端差出一大截，而这个按钮是要对齐着看的。
    /// 写死一个数，两端一样大，也好调。
    private static let pickIconSize: CGFloat = 26

    public var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            textBlock

            if let onPick {
                Button(action: onPick) {
                    Image(systemName: "p.square.fill")
                        .font(.system(size: Self.pickIconSize))
                        // 得写死 accent。iOS 那边 borderless 按钮本来就按 accent 画，
                        // mac 上是按**标签色**画的 —— 黑的，摆在行尾像块死图标，
                        // 看不出是个能点的按钮。写死之后两边一样是蓝的。
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("选择下载内容")
            }
        }
    }

    // MARK: - 右边那三行字

    /// **三行：标题 / person + UP 主 / touchid + BV 号**，两端、全 App 的
    /// 列表行全一样 —— 排版本身在 `VideoRowText` 里（收藏夹、合集、历史记录
    /// 那些视频列表也用同一份）。
    ///
    /// 分 P 那个计数挂在 **BV 号那一行的最右头**（不是中间那行）：它说的是
    /// 「这个 BV 号底下的哪几 P」，跟号挨着才对。
    private var textBlock: some View {
        VideoRowText(
            title: title,
            titleColor: titleColor,
            ownerName: ownerName,
            identifier: identifier,
            trailing: trailing
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        switch thumbnail {
        case .cover(let url):
            CoverThumbnail.videoRow(url: url, badge: badge, isPremium: isPremium)

        case .avatar(let url):
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = covers.image(for: url) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: Self.thumbSize.height * 0.34, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .task(id: url) { covers.load(url) }
        }
    }
}
