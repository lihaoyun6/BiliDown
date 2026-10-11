import Foundation

/// 落盘时的文件名处理。iOS 的「文件」和 macOS 的文件夹两条路都要用，
/// 而且是纯函数、没有平台差异，所以单独拎出来放一份。
enum FileNaming {

    /// 文件名里只要有一个路径分隔符，appendingPathComponent 就会把它当子目录，
    /// 那个目录并不存在，写文件会以一个莫名其妙的错误收场。这里兜一道底。
    static func safeName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    /// 重名就加 -2、-3，不覆盖已有的文件
    static func uniqueURL(for url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(index)")
                .appendingPathExtension(ext)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
