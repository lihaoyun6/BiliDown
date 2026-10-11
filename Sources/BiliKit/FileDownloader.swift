import Foundation

/// 带进度的单文件下载器。用 URLSessionDownloadTask 而不是逐字节迭代，
/// 大文件下才不会慢成幻灯片。
public final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    public enum DownloadError: LocalizedError {
        case http(Int)
        case notMoved

        public var errorDescription: String? {
            switch self {
            case .http(let code): return "下载失败（HTTP \(code)）"
            case .notMoved: return "下载完成但文件没落地"
            }
        }
    }

    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var moveError: Error?

    /// onCancel 在任意线程上调，跟 delegate 队列里的读写得错开
    private let lock = NSLock()
    private var _task: URLSessionDownloadTask?

    private var currentTask: URLSessionDownloadTask? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set { lock.lock(); defer { lock.unlock() }; _task = newValue }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // 大文件慢慢下，别因为整体超时被掐断
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public func download(
        from url: URL,
        headers: [String: String],
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        self.destination = destination
        self.progressHandler = onProgress
        self.moveError = nil

        try? FileManager.default.removeItem(at: destination)

        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                currentTask = task
                task.resume()
                // 取消比这里早一步发生的话，onCancel 里 currentTask 还是 nil，
                // 补一刀，否则这一下停止会被吞掉、整段还是照下
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            // 用户点了停止：掐掉底层 task，回调会以 URLError.cancelled 收尾
            currentTask?.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        currentTask = nil
        guard let continuation else { return }
        self.continuation = nil
        self.progressHandler = nil
        continuation.resume(with: result)
    }

    // 回调都在同一个串行 delegateQueue 上跑，所以这里不需要额外加锁。

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = DownloadError.http(http.statusCode)
            return
        }
        guard let destination else {
            moveError = DownloadError.notMoved
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 代理给的是临时文件，方法返回后就会被删，必须在这里挪走
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        if let moveError {
            finish(.failure(moveError))
            return
        }
        guard let destination else {
            finish(.failure(DownloadError.notMoved))
            return
        }
        finish(.success(destination))
    }
}
