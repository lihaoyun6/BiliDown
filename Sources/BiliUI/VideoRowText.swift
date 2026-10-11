import SwiftUI
import BiliCore

/// 列表行右边那三行字：**标题 / BV 号 / person + UP 主**。
///
/// 三处共用这一份：添加任务那页解析出来的视频行、收藏夹和合集里的视频行
/// （两端各一处）。这几页是来回翻的，三行怎么排（谁上谁下、缝多宽、
/// 挤不下时缩谁）得一模一样，各写各的迟早走样。
///
/// 行里那三行的缝和高度走 `ListRowMetrics` —— 三行在封面那 56 里排开，
/// 两块信息（标题、下面那两行）之间缝宽一点，BV 号和 UP 主这两行凑成一组。
///
/// 字号走 `Typography` 而不是语义字号：那套在 mac 上要矮一档，
/// 同一个视频在「添加任务」和「收藏夹 > 视频列表」里会差出一圈 ——
/// 点开看的是同一批视频。
public struct VideoRowText: View {

    let title: String
    var titleColor: Color = .primary
    /// 第二行左边那串号：视频是 BV 号，整批来源是 UID / 合集 ID
    let identifier: String
    /// 第二行**最右头**那句话（多 P 的「已选 3 P」、整批的「共 N 个视频 · 已选 N 个」）
    var trailing: String?
    /// 第三行的 UP 主名。没有就不画字（整批来源没有这个概念），
    /// 但**这一行的地方照样留着**，见 `ListRowMetrics.infoLineHeight`。
    var ownerName: String?

    public init(
        title: String,
        titleColor: Color = .primary,
        identifier: String,
        trailing: String? = nil,
        ownerName: String? = nil
    ) {
        self.title = title
        self.titleColor = titleColor
        self.identifier = identifier
        self.trailing = trailing
        self.ownerName = ownerName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(titleColor)
                .lineLimit(1)

            Spacer(minLength: 0).frame(maxHeight: ListRowMetrics.videoTitleGap)

            identifierLine

            // 下面这两行凑成一组，缝比上面那道窄（见 `ListRowMetrics.videoInfoGap`）
            Spacer(minLength: 0).frame(maxHeight: ListRowMetrics.videoInfoGap)

            ownerLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 三行字**整块**在封面里居中：`Alignment.leading` 是
        // 「横着贴左、竖着居中」，块比封面矮的时候余量上下平分。
        // 高度取的是视频行那一档（iOS 比 mac 矮一点），跟旁边那块封面同高。
        .frame(height: ListRowMetrics.videoCoverHeight)
    }

    /// BV 号那一行：左边一串号，右边顶一句 `trailing`。
    private var identifierLine: some View {
        HStack(spacing: 4) {
            Text(identifier)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 挤不下的时候**先缩左边**：`fixedSize` 让这句按原样占够地方，
            // 左边那串号被压短也不许动它。「已选 3 P」短，缩它就等于没显示；
            // 号短一截照样认得出是什么。
            if let trailing {
                Text(trailing)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .frame(height: ListRowMetrics.infoLineHeight, alignment: .leading)
    }

    /// UP 主那一行：person 图标 + 名字，跟上面那行同一个写法。
    private var ownerLine: some View {
        HStack(spacing: 4) {
            if let ownerName, !ownerName.isEmpty {
                Image(systemName: "person")
                    .font(Typography.micro)
                Text(ownerName)
                    .lineLimit(1)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .frame(height: ListRowMetrics.infoLineHeight, alignment: .leading)
    }
}
