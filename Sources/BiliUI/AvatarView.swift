import SwiftUI

/// 一个圆形头像。iOS 的「我的」页、关注列表，mac 的关注列表，都用它。
///
/// 用的是 `AsyncImage` 而不是 App 里下载封面那套 `CoverImageStore`：
/// 头像跟封面不是一回事 —— 封面归「自动拉取封面」那个开关管（那是**只为好看**的
/// 流量，关掉是为了少发请求防风控），头像要是跟着关掉，满屏就是一个个人形占位符，
/// 那就不是省流量是没法看了。头像走 URLSession 自己的缓存，翻回去不会重下。
public struct AvatarView: View {

    let url: URL?
    var size: CGFloat

    public init(url: URL?, size: CGFloat = 48) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        // 还在下：留空。这张图迟早会盖满这一格，
                        // 底下垫什么都会被看见一下再消失。
                        Color.clear
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// 没有头像时那个人形图标。没登录的账号那一行、（不该出现但总会出现的）
    /// 图挂了的人，都落到这儿 —— 大小跟真头像占同一格，所以行高不会跟着变。
    private var placeholder: some View {
        Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
}
