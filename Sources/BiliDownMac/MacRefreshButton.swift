import SwiftUI

/// 顶栏那颗刷新按钮。收藏 / 合集列表页，和它们里面那层视频列表，用的是同一颗。
///
/// 抽出来是为了那点顶栏的脾气只写一遍 —— 各抄一份的话，下次要调必然只改到一处。
struct MacRefreshButton: View {

    let isLoading: Bool
    let action: () -> Void

    // MARK: - 这颗按钮要调的就下面三个数

    /// 图标多大 —— 符号的点数。
    ///
    /// 12.5 是量出来的：画出来墨迹 11×13，跟系统原来给这颗画的一样大。
    /// 换这条路不是为了改它的大小（原来那个大小没毛病），是为了把那一格钉住 ——
    /// 见下面 `cell`。
    private static let pointSize: CGFloat = 14

    /// 笔画多粗。加粗**只用这个**，别去动 `pointSize` —— 字重只让笔画变厚，
    /// 墨迹的大小不变（量过：regular 墨量 141 → semibold 192，墨迹都是 11×13），
    /// 而调 `pointSize` 是连大小一起变的。
    private static let weight: Font.Weight = .semibold

    /// 画布多大（正方形）。**要比墨迹大得多。**
    ///
    /// 画布装不下的部分会被裁掉，而顶栏还会按自己那套把这个格子缩放一下 ——
    /// 墨迹贴着画布边的时候就是上下被切（`doc.on.doc` 那颗踩过这个坑）。
    /// 现在墨迹 13 高，画布 20，四周各留 3.5 有富余。
    private static let box: CGFloat = 20

    /// 图标（和转圈）占的那一格，15×15，**跟旁边那几颗圈一样大**。
    ///
    /// 这一格原来是 `ZStack` 自己推的（取图标和转圈里大的那个 ≈ 15×16），
    /// 于是这颗按钮比邻居胖一点。钉死之后两边一样宽，一条线排下来就齐了。
    private static let cell: CGFloat = 15

    // MARK: - 视图

    /// 图标和转圈**从头到尾都在**，靠透明度切，不是二选一地换上换下 ——
    /// 两个都占着同一格，ZStack 的尺寸在两种状态下就都是 15×15，按下去顶栏不会缩。
    var body: some View {
        Button(action: action) {
            ZStack {
                Self.symbol
                    .opacity(isLoading ? 0 : 1)

                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.cell, height: Self.cell)
                    .opacity(isLoading ? 1 : 0)
                    // 藏着的时候别让读屏念它 —— 按钮自己的名字是「刷新」，
                    // 多念一个「进度指示器」出来只是噪音
                    .accessibilityHidden(true)
            }
        }
        .disabled(isLoading)
        .help("重新读取")
        .accessibilityLabel("刷新")
    }

    /// 符号画成一整张图。
    ///
    /// 走这张图是为了能定尺寸：顶栏 item 里那颗符号多大，是顶栏按自己那套样式
    /// 定的 —— `Label` / `Image` 上写 `.font`、`.imageScale`、`.resizable`
    /// 递过去都会被它盖掉。
    ///
    /// 画法是把它当**文字**画，不是当图片：`resolve` 收 `Image` 的那条路字重没处写，
    /// 而 `Image(nsImage:)` 那条配得出字重却会丢掉前景色（画出来是白的，
    /// 浅色外观下跟隐形一样）。当文字画，`Text` 本来就认这些，也照常跟前景色走。
    private static var symbol: some View {
        let canvas = CGSize(width: box, height: box)
        return Image(size: canvas) { context in
            let text = context.resolve(
                Text(Image(systemName: "arrow.clockwise"))
                    .font(.system(size: pointSize, weight: weight))
            )
            // 文字按 rect 的左上角排，不缩不放 —— 想居中得先量出来，再自己算那块 rect
            let measured = text.measure(
                in: CGSize(width: canvas.width * 4, height: canvas.height * 4)
            )
            context.draw(text, in: CGRect(
                x: (canvas.width - measured.width) / 2,
                y: (canvas.height - measured.height) / 2,
                width: measured.width,
                height: measured.height
            ))
        }
        // **钉死符号那一档**，别删。`Text` 里那颗符号还受**环境**的 `.imageScale`
        // 管，而环境是顶栏给的：它第一遍渲染递过来的是「大号符号」那一档，画出来
        // 就偏大（剪贴板那颗就是这么在启动第一眼冒出去、切个栏目才缩回来的）。
        // 钉死之后顶栏哪一遍来都画同一张。
        .environment(\.imageScale, .medium)
        // 画布 20，这一格按 15 报出去：跟旁边那几颗圈占的地方一样大，
        // 多出来的 5 是透明的余量（见上面 `box` 那段）
        .frame(width: cell, height: cell)
    }
}
