import Foundation
import CryptoKit

/// B 站 WBI 签名。playurl 这类接口现在必须带 w_rid + wts，
/// 密钥来自 /x/web-interface/nav 返回的两个图片地址。
public struct WBIKeys: Sendable, Equatable {

    public let imgKey: String
    public let subKey: String

    public init(imgKey: String, subKey: String) {
        self.imgKey = imgKey
        self.subKey = subKey
    }

    /// 从 https://i0.hdslb.com/bfs/wbi/xxxx.png 里取出 xxxx
    public init(imgURL: String, subURL: String) {
        self.imgKey = Self.key(fromURL: imgURL)
        self.subKey = Self.key(fromURL: subURL)
    }

    private static func key(fromURL url: String) -> String {
        let last = url.split(separator: "/").last.map(String.init) ?? url
        return last.split(separator: ".").first.map(String.init) ?? last
    }

    /// 官方混淆表，用来把 imgKey + subKey 打乱成 mixin key
    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    public var mixinKey: String {
        let raw = Array(imgKey + subKey)
        guard raw.count >= 64 else { return imgKey + subKey }
        let shuffled = Self.mixinKeyEncTab.prefix(32).map { raw[$0] }
        return String(shuffled)
    }

    /// 补上 wts 和 w_rid，返回可以拼进 URL 的完整参数表。
    public func sign(params: [String: String], timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String] {
        var signed = params
        signed["wts"] = String(timestamp)

        let query = signed
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(Self.encode(key))=\(Self.encode(Self.sanitize(value)))"
            }
            .joined(separator: "&")

        signed["w_rid"] = Self.md5(query + mixinKey)
        return signed
    }

    /// w_rid 是按「过滤掉 !'()* 之后」的值算的，原值照常发。
    private static func sanitize(_ value: String) -> String {
        value.filter { !"!'()*".contains($0) }
    }

    /// 对齐 JS 的 encodeURIComponent：只放行 A-Za-z0-9-_.~
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
