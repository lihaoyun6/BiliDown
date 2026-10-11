import Foundation
import Network

/// 出错报告要带上当时的网络状态，所以常驻一个监听，
/// 别等到要写报告了才现开——那会儿读到的永远是空的。
public final class NetworkStatus: @unchecked Sendable {

    public static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _path: NWPath?

    /// pathUpdateHandler 在后台队列上跑，读的这边可能在主线程，用锁护着
    private var path: NWPath? {
        get { lock.lock(); defer { lock.unlock() }; return _path }
        set { lock.lock(); defer { lock.unlock() }; _path = newValue }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.path = path
        }
        monitor.start(queue: DispatchQueue(label: "com.lihaoyun6.BiliDown.network"))
    }

    /// 直接就是要写进 JSON 的那几个字段
    public var snapshot: [String: Any] {
        guard let path else {
            return ["status": "unknown", "interface": "unknown", "expensive": false, "constrained": false]
        }
        return [
            "status": Self.statusText(path.status),
            "interface": Self.interfaceText(path),
            "expensive": path.isExpensive,
            "constrained": path.isConstrained
        ]
    }

    private static func statusText(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "online"
        case .unsatisfied: return "offline"
        case .requiresConnection: return "requiresConnection"
        @unknown default: return "unknown"
        }
    }

    private static func interfaceText(_ path: NWPath) -> String {
        var names: [String] = []
        if path.usesInterfaceType(.wifi) { names.append("wifi") }
        if path.usesInterfaceType(.cellular) { names.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { names.append("ethernet") }
        if path.usesInterfaceType(.loopback) { names.append("loopback") }
        if path.usesInterfaceType(.other) { names.append("other") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }
}
