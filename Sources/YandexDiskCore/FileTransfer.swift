import Foundation

public struct TransferFailure: Error {
    public let underlying: Error
    public let resumeData: Data?
}
public struct TransferPaused: Error { public let resumeData: Data? }

/// One URLSessionDownloadTask; delegates stream bytes to disk, never into RAM.
public final class FileTransfer: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var task: URLSessionTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var paused = false
    private var cancelled = false
    private var finished = false
    private var result: Result<URL, Error>?
    private var watchdog: DispatchSourceTimer?
    private var lastProgress = Date()
    private var timedOut = false
    private let idleTimeout: TimeInterval
    private let streaming: Bool
    private var streamFile: URL?
    private var streamHandle: FileHandle?
    private var streamedBytes: Int64 = 0
    private let progress: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    public init(configuration: URLSessionConfiguration = .default, idleTimeout: TimeInterval = 45, streaming: Bool = false, progress: @escaping @Sendable (Int64) -> Void) {
        self.configuration = configuration; self.idleTimeout = idleTimeout; self.streaming = streaming; self.progress = progress
    }
    public func pause() {
        lock.lock(); defer { lock.unlock() }
        guard !paused, !finished else { return }; paused = true
        if let download = task as? URLSessionDownloadTask { download.cancel(byProducingResumeData: { _ in }) } else { task?.cancel() }
    }
    public func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; task?.cancel() }
    public func download(url: URL, resumeData: Data? = nil) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                guard !paused else { continuation.resume(throwing: TransferPaused(resumeData: nil)); return }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 7 * 24 * 3600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                if streaming {
                    task = session.dataTask(with: url)
                } else if let resumeData { task = session.downloadTask(withResumeData: resumeData) }
                else { var request = URLRequest(url: url); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding"); task = session.downloadTask(with: request) }
                task?.resume()
                lastProgress = Date()
                let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                watchdog.schedule(deadline: .now() + idleTimeout, repeating: 1)
                watchdog.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    guard !self.finished, !self.paused, !self.cancelled, !self.timedOut,
                          Date().timeIntervalSince(self.lastProgress) >= self.idleTimeout else { return }
                    self.timedOut = true
                    if let download = self.task as? URLSessionDownloadTask { download.cancel(byProducingResumeData: { _ in }) } else { self.task?.cancel() }
                }
                self.watchdog = watchdog; watchdog.resume()
            }
        }, onCancel: { self.cancel() })
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); lastProgress = Date(); lock.unlock(); progress(totalBytesWritten)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
    // A streaming fallback handles OS/CDN combinations where download tasks stall.
    // Data is written in delegate-sized chunks, not accumulated in memory.
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw DiskError.invalidResponse }
            guard http.statusCode == 200 else { throw DiskError.http(http.statusCode, RetryPolicy.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ydd-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DiskError.fileSystem("Cannot create temporary download file.") }
            streamFile = file; streamHandle = try FileHandle(forWritingTo: file)
            completionHandler(.allow)
        } catch { result = .failure(error); completionHandler(.cancel) }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try streamHandle?.write(contentsOf: data); streamedBytes += Int64(data.count)
            lock.lock(); lastProgress = Date(); lock.unlock(); progress(streamedBytes)
        } catch { result = .failure(error); dataTask.cancel() }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw DiskError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw DiskError.http(response.statusCode, RetryPolicy.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) }
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ydd-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: kept)
            result = .success(kept)
        } catch { result = .failure(error) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }; finished = true
        watchdog?.cancel(); watchdog = nil
        if streaming {
            do { try streamHandle?.close() } catch { result = .failure(error) }; streamHandle = nil
            if error == nil, result == nil, let streamFile { result = .success(streamFile) }
            if error != nil || cancelled || paused || timedOut { if let streamFile { try? FileManager.default.removeItem(at: streamFile) } }
            if case .failure = result, let streamFile { try? FileManager.default.removeItem(at: streamFile) }
        }
        if cancelled {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            continuation?.resume(throwing: CancellationError())
        } else if paused {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation?.resume(throwing: TransferPaused(resumeData: data))
        } else if timedOut {
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation?.resume(throwing: TransferFailure(underlying: URLError(.timedOut), resumeData: data))
        } else if case .failure(let failure) = result {
            continuation?.resume(throwing: failure)
        } else if let error {
            let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation?.resume(throwing: TransferFailure(underlying: error, resumeData: data))
        } else { continuation?.resume(with: result ?? .failure(DiskError.invalidResponse)) }
        continuation = nil; self.task = nil; self.session = nil; session.finishTasksAndInvalidate()
    }
}

public enum ErrorMessage {
    public static func safe(_ error: Error) -> String {
        if let failure = error as? TransferFailure { return safe(failure.underlying) }
        if let error = error as? DiskError { return error.localizedDescription }
        if let error = error as? URLError { return "Network error (\(error.code.rawValue)): \(URLError(error.code).localizedDescription)" }
        if error is DecodingError { return "The API response could not be decoded." }
        if (error as NSError).domain == NSCocoaErrorDomain { return "File operation failed (\((error as NSError).code)). Check disk space and permissions." }
        return "Operation failed. Check connection and destination permissions."
    }
}
