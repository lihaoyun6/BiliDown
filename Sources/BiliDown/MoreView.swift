import SwiftUI
import BiliUI

/// 「更多」那一页：合集和追番 / 追剧 / 稍后再看 / 历史记录都收在这儿。
///
/// 它们现在摆成**同一个分组**（连成一张卡片），从上到下是：
/// 订阅合集 / 我的追番 / 我的追剧 / 稍后再看 / 历史记录。
/// 一开始是每条各占一张卡片，看着太散 —— 这几条本来就是同一类东西
///（从这一页进另一个列表），一张卡片刚好。
///
/// 图标跟 mac 侧边栏用的是同一批（那边是同一批词），两张皮别各挑各的。
struct MoreView: View {

    /// 图标那一列的宽度。这几个图标宽窄不一（`clock.arrow.circlepath` 比 `film`
    /// 宽出一截），不框住的话几条文字的左边缘会各差几个点，一列扫下来一眼就看出不齐。
    private static let iconWidth: CGFloat = 24

    var body: some View {
        NavigationStack {
            List {
                // 合集排第一。它跟收藏那一格是一对（都是「一堆视频的集合」），
                // 收藏还在标签栏上，合集就摆在最前面对着它；
                // 下面四条是自己一页的追番 / 追剧 / 稍后再看 / 历史记录。
                //
                // 这一行写「订阅合集」而点进去那页的标题是「合集」：
                // 在这张单子上「合集」两个字太素，看不出是「我订阅的那些」。
                list(.collections, title: "订阅合集")

                // 追番 / 追剧进的是「一季一季」的列表，再点一层才是分集
                list(.bangumi, title: "我的追番")
                list(.drama, title: "我的追剧")

                // 这两个没有上一层：点进去直接就是分集列表
                entry(.watchLater, title: "稍后再看", systemImage: "clock")
                entry(.history, title: "历史记录", systemImage: "clock.arrow.circlepath")
            }
            .navigationTitle("更多")
        }
    }

    /// 稍后再看 / 历史记录：点进去就是视频列表，没有中间那层。
    private func entry(_ source: LibrarySource, title: String, systemImage: String) -> some View {
        row(title: title, systemImage: systemImage) {
            VideoPickerView(source: source)
        }
    }

    /// 订阅合集 / 我的追番 / 我的追剧：先是一列条目，点进去才是视频。
    /// 图标归 `LibraryListKind` 管（跟那一页自己的空态图标同一个来源），
    /// 这儿不再抄一遍；行上的名字这一层自己给（有几行跟页标题不叫同一个名）。
    private func list(_ kind: LibraryListKind, title: String) -> some View {
        row(title: title, systemImage: kind.icon) {
            LibraryListView(kind: kind)
        }
    }

    /// 一行入口。左边图标右边字，右边那个箭头由 `NavigationLink` 自己画。
    private func row<Destination: View>(
        title: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Self.iconWidth, alignment: .center)

                Text(title)
            }
            .padding(.vertical, 2)
        }
    }
}
