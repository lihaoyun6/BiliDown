#if canImport(UIKit)
import UIKit
/// 两个平台上「一张图」是不同类型：iOS 是 UIImage，macOS 是 NSImage。
/// 共享层只关心「解出来一张图」，不关心是哪一种，所以在这儿收成一个名字。
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif
