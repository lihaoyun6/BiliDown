import SwiftUI

/// 列表顶上的「全选」。三态：一个没选、选了一部分、全选上。
/// 分 P 选择器、合集选择器、收藏夹都用这一个，样式保持一致。
public struct SelectAllRow: View {

    public enum State {
        case none
        case partial
        case all
    }

    let state: State
    /// 「全选」后面跟的一句小字，用来交代这页是什么（收藏夹名 / 合集名）。
    /// 放这儿是为了省掉一整行表头 —— 挑视频时那一行字其实只占地方。
    /// 不传就什么都不显示，别的调用点不受影响。
    var trailingText: String?
    /// 选择框的字号。得跟下面那些行的选择框调成一样大 ——
    /// 圆点的大小不只是粗细差别，大一号的 ink 左边会多出一点，
    /// 两行的圆点就串不成一条竖线，看着像没对齐。
    /// 各页的行高不一样（收藏夹那页带封面，行更高），所以做成参数。
    var symbolFont: Font = .body
    let action: () -> Void

    public init(
        state: State,
        trailingText: String? = nil,
        symbolFont: Font = .body,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.trailingText = trailingText
        self.symbolFont = symbolFont
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(symbolFont)
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)

                Text("全选")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    // 挤的时候先截右边那句说明，别把「全选」截了
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // 小字、灰色：它是句说明，不该跟「全选」抢注意力。
                // 靠右摆，长名字在自己这头截尾（保留开头那截，
                // 收藏夹名认的就是开头几个字）。
                if let trailingText {
                    Text(trailingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }
}
