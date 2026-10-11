import Foundation
import BiliCore

#if canImport(UIKit)
import UIKit
#endif

/// 失败任务的「复制报告」：这一单的下、报错和环境打成一段 JSON，
/// 用户直接粘给我就能定位问题。
public enum FailureReport {

    public static func json(for job: DownloadJob) -> String {
        let info = Bundle.main.infoDictionary

        var report: [String: Any] = [:]
        report["time"] = ISO8601DateFormatter().string(from: Date())

        report["app"] = [
            "name": info?["CFBundleName"] as? String ?? "BiliDown",
            "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown"
        ]

        report["system"] = [
            "name": systemName,
            "version": systemVersion,
            "model": systemModel,
            "machine": machineIdentifier()
        ]

        report["network"] = NetworkStatus.shared.snapshot

        report["task"] = [
            "source": job.ref.key,
            "url": job.ref.webURL,
            "kind": job.kind.rawValue,
            "title": job.title,
            "page": job.pageNumber ?? 1
        ]

        report["error"] = message(for: job)

        guard let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func message(for job: DownloadJob) -> String {
        if case .failed(let message) = job.state { return message }
        return "未知错误"
    }

    // MARK: - 环境信息
    //
    // 这几样 iOS 和 macOS 取值的地方都不一样。报告本身是给人看的，
    // 字段名和含义保持一致，取值各问各的。

    private static var systemName: String {
        #if canImport(UIKit)
        return UIDevice.current.systemName
        #else
        return "macOS"
        #endif
    }

    private static var systemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    private static var systemModel: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    /// 机型代号（iPhone17,1、MacBookPro18,3 这种），比「iPhone」有用得多
    private static func machineIdentifier() -> String {
        #if os(macOS)
        // macOS 上 uname(2) 给的是架构（arm64 / x86_64），不是机型 ——
        // 要机型得去问 sysctl 的 hw.model。
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        #endif
    }
}
