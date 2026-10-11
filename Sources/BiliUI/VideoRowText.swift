import SwiftUI
import BiliCore

/// 列表行右边那三行字：**标题 / person + UP 主 / touchid + BV 号**。
///
/// 全 App 的列表行共用这一份：添加任务那页解析出来的行、收藏夹 / 合集 /
/// 一季番剧 / 稍后再看 / 历史记录里的视频行。这几页是来回翻的，三行怎么排
///（谁上谁下、缝多宽、挤不下时缩谁）得一模一样，各写各的迟早走样。
///
/// 第三行有个例外：给了 `playedAt`（**只有历史记录那条路给**）就不摆 BV 号，
/// 改摆 **clock + 上次看的时间** —— 历史那一页上，什么时候看的是那一行
/// 唯一有用的信息。上面两行一个字都不动。
///
/// 三行**永远都占着位置**，没有 UP 主名也照样空着那一行（见
/// `ListRowMetrics.infoLineHeight`）：添加任务那页里整批来源和视频是混在一张
/// 单子上的，谁少一行，谁的第一行就跟隔壁错开半个行高，一列扫下来是歪的。
///
/// 行里那三行的缝和高度走 `ListRowMetrics` —— 三行在封面那 56 里排开，
/// 两块信息（标题、下面那两行）之间缝宽一点，下面那两行凑成一组。
///
/// 字号走 `Typography` 而不是语义字号：那套在 mac 上要矮一档，
/// 同一个视频在「添加任务」和「收藏夹 > 视频列表」里会差出一圈 ——
/// 点开看的是同一批视频。
public struct VideoRowText: View {

    let title: String
    var titleColor: Color = .primary
    /// 第二行的 UP 主名。整批来源没有这个概念（主页那条自己就是 UP 主，
    /// 合集那条接口不给名字），给 nil —— 那一行的地方照样留着。
    var ownerName: String?
    /// 第三行那串号：视频是 BV 号，整批来源是 UID / 合集 ID。
    /// 给了 `playedAt` 的时候这一串不画。
    let identifier: String
    /// 上次看这条的时间。**只有历史记录那条路给**。
    var playedAt: Date?
    /// 第三行**最右头**那句话（多 P 的「已选 3 P」、整批的「共 N 个视频 · 已选 N 个」）
    var trailing: String?

    public init(
        title: String,
        titleColor: Color = .primary,
        ownerName: String? = nil,
        identifier: String,
        playedAt: Date? = nil,
        trailing: String? = nil
    ) {
        self.title = title
        self.titleColor = titleColor
        self.ownerName = ownerName
        self.identifier = identifier
        self.playedAt = playedAt
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(titleColor)
                .lineLimit(1)

            Spacer(minLength: 0).frame(maxHeight: ListRowMetrics.videoTitleGap)

            ownerLine

            // 下面这两行凑成一组，缝比上面那道窄（见 `ListRowMetrics.videoInfoGap`）
            Spacer(minLength: 0).frame(maxHeight: ListRowMetrics.videoInfoGap)

            identifierLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 三行字**整块**在封面里居中：`Alignment.leading` 是
        // 「横着贴左、竖着居中」，块比封面矮的时候余量上下平分。
        // 高度取的是视频行那一档（iOS 比 mac 矮一点），跟旁边那块封面同高。
        .frame(height: ListRowMetrics.videoCoverHeight)
    }

    /// 第二行：person 图标 + UP 主名。没有名字就只留着这一行的高度。
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

    /// 第三行：平时是 touchid + 那串号，右边顶一句 `trailing`；
    /// 历史那页把它换成 clock + 上次看的时间。
    ///
    /// 两个图标字号都取 `Typography.micro`，跟上面 person 那个同一个 ——
    /// 一列下来图标那一栏才是齐的。
    private var identifierLine: some View {
        HStack(spacing: 4) {
            if let playedAt {
                Image(systemName: "clock")
                    .font(Typography.micro)
                Text(Self.playedText(playedAt))
                    .lineLimit(1)
            } else {
                Image(systemName: "touchid")
                    .font(Typography.micro)
                Text(identifier)
                    .lineLimit(1)
            }

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

    // MARK: - 上次看的时间

    /// 「上次看的时间」怎么写：近的报得细、远的报得粗 ——
    /// 今天 / 昨天 / 今年（只报月日）/ 更早（带上年份）。
    ///
    /// 没写成「3 天前」那种纯相对的：历史一屏里大半是前几天看的，
    /// 「3 天前 4 天前 5 天前」一列扫下来反而看不出究竟是哪天。
    /// 固定成 `HH:mm` / `MM-dd` 这种定宽写法还有个好处 ——
    /// 一列下来那几行不会因为字数不同而左右乱跳。
    private static func playedText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInYesterday(date) { return "昨天 \(time)" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return "\(monthDayFormatter.string(from: date)) \(time)"
        }
        return dateFormatter.string(from: date)
    }

    /// 三个格式都是写死的，不跟系统区域走 —— 这个 App 只有中文一套皮，
    /// 跟着区域变会出现「10/09」和「10-09」两种写法混着的局面。
    private static let timeFormatter = formatter("HH:mm")
    private static let monthDayFormatter = formatter("MM-dd")
    private static let dateFormatter = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }
}
