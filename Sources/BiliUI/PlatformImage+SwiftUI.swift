import SwiftUI
import BiliKit

/// BiliKit 那边只承诺「解出来一张图」，是哪一种它不关心（`PlatformImage`
/// 在 iOS 是 UIImage，在 macOS 是 NSImage）。要画到屏幕上就得落到 SwiftUI
/// 认的那个类型上，于是有这么一层适配 —— 两个平台各一个 init，
/// 调用点一律写 `Image(platformImage:)`，看不见平台分支。
extension Image {
    public init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
