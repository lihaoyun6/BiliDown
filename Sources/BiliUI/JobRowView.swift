import SwiftUI
import BiliCore
import BiliKit

public struct JobRowView: View {

    let job: DownloadJob

    public init(job: DownloadJob) { self.job = job }

    /// 整行高度跟着封面走：三行字合成一块摆在行里，中间那一档留给进度条。
    /// 高度定死，切状态的时候行高才不会一跳一跳。
    /// 高度得按「标题 + 分 P 副标题 + 状态」三行来留，不然下载完那一下会挤。
    ///
    /// 这个数不是这一页自己的 —— 全 App 的列表行都按 `ListRowMetrics` 那一档来，
    /// 而且这一行（三行字，要求最高）正是那个尺寸的出处。
    private static var rowHeight: CGFloat { ListRowMetrics.coverHeight }

    /// 三行字之间那两道缝的**上限**。跟全 App 别的三行字的行（添加任务、
    /// 收藏夹里那些视频行）取的是同一对数，见 `ListRowMetrics`。
    ///
    /// 三道高度（标题 16 / 中间 16 / 状态 16）全钉死之后，缝就是个定数，
    /// 这两道还得分开写：中间那行和下面那行说的是同一件事的两半
    /// （分 P 副标题和状态），贴着点看才是一组；标题是另一回事，让它宽一点。
    ///
    /// 原来这两道都是 4，整块正好 56 把行撑满、一点余量不剩 —— 现在下面那道
    /// 收 1 点，块变 55，比行矮 1 点，余下那点由整块居中分掉
    /// （见下面 `.frame` 那段）。iOS 那边字号大一档，缝被压得更紧一些。
    private static var titleGap: CGFloat { ListRowMetrics.titleGap }
    private static var statusGap: CGFloat { ListRowMetrics.infoGap }

    /// 中间那一档（进度条 / 分 P 副标题）和底下状态行那一档的高度。**两档一样高。**
    ///
    /// 这一行的三行字（标题 / 中间 / 状态）高度全钉死 —— 高度是钉死的，
    /// 而且中间那一档**永远有东西**（见 `middleSlot`）：光钉高度不够，
    /// 里头空着的时候这一行看着还是「标题 + 状态」两行，跟别的行不齐。
    ///
    /// 16 是这两行里最高的那个（`Typography.caption` 在 mac 上量出来 15）：
    /// 字号两边已经一样了（副标题也是 `caption`），高度再对齐，落点才一样。
    /// 全 App 的小字行都是这一档，数值在 `ListRowMetrics.infoLineHeight`。
    private static var lineHeight: CGFloat { ListRowMetrics.infoLineHeight }

    /// 状态行里那个图标占的方框。
    ///
    /// SF Symbol 每个符号的高矮都不一样（箭头矮，那个立体层叠高），
    /// `Image(systemName:)` 会按符号自己的高度撑开，状态行就跟着长高一点点 ——
    /// 多出来的高度由上面那两个 Spacer 分掉，于是这一行自己不动、字往上顶，
    /// 看着就是「合并中」三个字往上跳了一下。行高（`lineHeight`）和这个框
    /// 都钉死，两个一起才真正稳。
    private static let statusIconBox: CGFloat = 14

    /// BV 号和它后面那截「P3 第三话」之间空的距离。
    /// 见 `identifierLine` 那段：这不是行距，是「一句话里断开的两半」。
    private static let identifierGap: CGFloat = 10

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 气泡（画质 / 「音频」/「封面」）由缩略图自己画，字从任务那边来
            // （见 `DownloadJob.coverBadge`）。
            // 尺寸走 `CoverThumbnail` 的默认值，也就是 `ListRowMetrics` 那一档 ——
            // 跟别的列表行同一把尺子。
            CoverThumbnail(
                url: job.coverURL,
                placeholderSystemImage: stateIcon,
                badge: job.coverBadge
            )

            VStack(alignment: .leading, spacing: 0) {
                // 纯音频就不再另外挂个音符了 —— 封面角标上那个「音频」
                // 说的是同一件事，一个信息摆两遍只会把标题挤短。
                Text(job.displayTitle)
                    .font(Typography.rowTitle)
                    .lineLimit(1)

                Spacer(minLength: 0).frame(maxHeight: Self.titleGap)
                // 中间这一档**永远占这么高、也永远有东西**（是条，或者是 BV 号）——
                // 见 `lineHeight` 和 `middleSlot` 那两段
                middleSlot
                    .frame(height: Self.lineHeight)
                // 下面这道缝比上面那道窄一点：中间那行和状态行是一组，见 `statusGap`
                Spacer(minLength: 0).frame(maxHeight: Self.statusGap)

                statusRow
            }
            // 三行字**整块**在行里居中。`Alignment.leading` 是「横着贴左、
            // 竖着居中」—— 块比行矮的时候余量上下平分（现在矮 1 点，上下各 0.5），
            // 不是顶着上沿。
            .frame(height: Self.rowHeight, alignment: .leading)
        }
        // 行与行之间那点缝**归列表自己管**，这一行不另外垫 —— 垫了这一层，
        // 队列里两颗封面之间就比收藏夹那些视频行多出 4pt（上下各 2），
        // 一列扫下来能一眼看出队列更松。所有列表用的都是同一个 List 默认间距。
    }

    /// 进度条占的那一档。
    ///
    /// 还没下完的那些行里，这一档**永远画条**，不能空着 —— 空着的时候
    /// （排在队里、刚停、刚失败）看着就是「标题 + 状态」两行，跟下着的
    /// 那些行摆在一起高矮不齐。
    ///
    /// 这一档不画条的只有下完的那种：那儿摆的是 BV 号（见 `identifierLine`）。
    @ViewBuilder
    private func progressBar(_ value: Double) -> some View {
        // 一点进度都没有时自己画槽（见 `emptyBar`），有进度才交给原生那个
        if value > 0 {
            ProgressView(value: value)
                .progressViewStyle(.linear)
        } else {
            emptyBar
        }
    }

    /// mac 原生那根槽多高。量出来的：`ProgressView(value:)` 的轨道在 mac 上
    /// 是 6pt（里面那条进度本身 4pt），iOS 上整个都是 4pt。
    private static let nativeBarHeight: CGFloat = 6

    /// 一点进度都没有的那根槽。
    ///
    /// **mac 上不能用 `ProgressView(value: 0)`**：它起始处会留下一个蓝点
    /// （填充块那个圆头，宽度压到 0 也还剩 7pt 宽、4pt 高），一列扫下来
    /// 每条停着的任务都像「下了一丁点」。所以自己画一根槽：高度和颜色照
    /// 原生那根量出来的值（6pt、黑 5%~8%），看着就是一根空槽。
    ///
    /// iOS 原生就是一根干净的灰槽（0 的时候不画那个点），不动它。
    @ViewBuilder
    private var emptyBar: some View {
        #if os(macOS)
        Capsule()
            // `primary` 而不是写死黑：深色模式下槽是白的
            .fill(Color.primary.opacity(0.08))
            .frame(height: Self.nativeBarHeight)
        #else
        ProgressView(value: 0)
            .progressViewStyle(.linear)
        #endif
    }

    /// 中间这一档。
    ///
    /// 三种写法：下完的摆 BV 号、停了的摆一根空条、其它按进度摆条。
    @ViewBuilder
    private var middleSlot: some View {
        switch job.state {
        case .finished:
            // 下完了，标题已经在上面那行，这一档就摆 BV 号 ——
            // 那串号是回 B 站找它的凭据，比一根拉满的条有用。
            identifierLine

        case .stopped:
            // 停了条也留着，只是归零：不显示它下到哪儿了（那个数已经不作数了），
            // 状态行那边也只报「已停止」，不带百分比。
            progressBar(0)

        default:
            // 排队中 / 解析中都是 0（空条），下着的是实时进度，
            // 失败的就冻在它断掉的那一格。
            progressBar(job.progress)
        }
    }

    /// 下完的那一行中间摆的东西：BV 号，后面可能还跟着分 P。
    ///
    /// 是某个多 P 视频的其中一 P 的话，BV 号后面**空一段**再写「P3 第三话」——
    /// 隔开是为了让人一眼看出后半截是「这个视频里的哪一 P」，而不是 BV 号的一部分。
    /// 位置不够时缩的是后半截（BV 号整串永远给全，那是查回去用的）。
    private var identifierLine: some View {
        HStack(spacing: Self.identifierGap) {
            // 预取展开短链后会填上真 BV 号，没填上就退回 ref 自己的 key
            // （跟文件名取的是同一个，见 `DownloadJob.fileName`）
            Text(job.resolvedBVID ?? job.refKey)
                // 整串不许截
                .fixedSize()

            if let subtitle = job.subtitle {
                Text(subtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
    }

    /// 状态行。下着的过程中分 P 只在这儿挂个 [P1]，
    /// 副标题要等进度条腾出地方才显示，免得同一个信息出现两遍。
    private var statusRow: some View {
        HStack(spacing: 8) {
            statusLabel
                // 状态文字先占位置，剩下的才轮到分 P 标记
                .layoutPriority(1)

            if let badge = job.pageBadge, !showsSubtitleInMiddle {
                Text(badge)
                    .font(Typography.micro)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // 内容贴着底边摆：底下这排不管里面装的是箭头还是立体层叠，
        // 位置都不许动
        .frame(height: Self.lineHeight, alignment: .bottom)
    }

    /// 分 P 副标题是不是已经挪到中间那一档去了
    private var showsSubtitleInMiddle: Bool {
        job.state == .finished && job.subtitle != nil
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch job.state {
        case .queued:
            statusText("排队中", icon: "clock")

        case .resolving:
            statusText("解析中", icon: "link")

        case .downloading:
            statusText(stateText, icon: "arrow.down")

        case .remuxing, .saving:
            statusText(stateText, icon: stateIcon)

        case .stopped:
            statusText("已停止", icon: "stop.fill")

        case .finished:
            statusText("已完成", icon: "checkmark.circle.fill", color: .green)

        case .failed(let message):
            // 报错只显示一行，想看全的点开条目看弹窗
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Typography.micro)
                    .frame(width: Self.statusIconBox, height: Self.statusIconBox)
                Text(message)
                    .font(Typography.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.red)
        }
    }

    /// 图标和文字贴紧，整行钉在左边 —— 用 Label 的话两者都会飘。
    /// 图标套一个固定方框：符号本体照旧按自己的大小画在框里居中，
    /// 但占的地方永远是框那么大，换符号不会把旁边的字顶来顶去。
    private func statusText(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(Typography.micro)
                .frame(width: Self.statusIconBox, height: Self.statusIconBox)
            Text(text)
                .font(Typography.caption)
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }

    private var stateText: String {
        switch job.state {
        case .downloading: return "下载中 \(Int(job.progress * 100))%"
        case .remuxing: return job.kind == .audioOnly ? "转换中…" : "合并中…"
        case .saving: return "保存中…"
        default: return ""
        }
    }

    private var stateIcon: String {
        switch job.state {
        case .queued: return "clock"
        case .resolving: return "link"
        case .downloading: return "arrow.down"
        case .remuxing: return "square.stack.3d.down.right"
        case .saving: return "square.and.arrow.down"
        case .stopped: return "stop.fill"
        case .finished: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

#Preview {
    List {
        JobRowView(job: DownloadJob(ref: .bvid("BV1xx411c7mD")))

        JobRowView(job: {
            var job = DownloadJob(ref: .bvid("BV1xx411c7mD"), pageNumber: 3)
            job.title = "【4K修复】某个很长的视频标题在这里，长到需要被截断"
            job.pageTitle = "第三话"
            job.pageCount = 12
            job.state = .downloading
            job.progress = 0.42
            job.qualityID = 32
            return job
        }())

        JobRowView(job: {
            // 多 P 选 P1：状态行挂 [P1]，不能看着像普通视频
            var job = DownloadJob(ref: .bvid("BV1xx411c7mD"), pageNumber: 1)
            job.title = "多 P 视频只下第一 P"
            job.pageTitle = "开场"
            job.pageCount = 12
            job.state = .downloading
            job.progress = 0.77
            job.qualityID = 116
            return job
        }())

        JobRowView(job: {
            // 下完之后进度条让位给分 P 副标题
            var job = DownloadJob(ref: .bvid("BV1xx411c7mD"), pageNumber: 3)
            job.title = "下完的多 P 视频"
            job.pageTitle = "第三话 这个名字长到需要被截断才行"
            job.pageCount = 12
            job.state = .finished
            job.progress = 1
            return job
        }())

        JobRowView(job: {
            var job = DownloadJob(ref: .avid(123456), kind: .audioOnly)
            job.title = "只下音频的那个视频"
            job.state = .stopped
            return job
        }())

        JobRowView(job: {
            var job = DownloadJob(ref: .avid(123456), kind: .cover)
            job.title = "只要封面的那个"
            job.state = .finished
            return job
        }())

        JobRowView(job: {
            var job = DownloadJob(ref: .avid(123456))
            job.title = "已经下完的那个"
            job.state = .finished
            return job
        }())

        JobRowView(job: {
            var job = DownloadJob(ref: .avid(123456))
            job.title = "失败的那个"
            job.state = .failed("取流失败：需要登录后才能下载该画质")
            return job
        }())
    }
}
