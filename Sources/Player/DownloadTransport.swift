import Foundation

/// Transport-level download events. `finished` hands over a STAGED file (moved out of
/// URLSession's ephemeral location inside the delegate callback — the original is deleted the
/// moment the callback returns).
enum DownloadEvent: Sendable {
    case preparing(Int64)
    case progress(Int64, Double)
    case finished(Int64, staged: URL, status: Int, contentType: String?, disposition: String?)
    case failed(Int64, message: String, transient: Bool)
}

/// Seam between the download engine and the network (dogfood round 4, I2). V1 is a foreground
/// URLSession: the server ignores Range (no resume data works) and per-file LAN time is seconds,
/// so a background session buys little and costs the full delegate-relaunch machinery. V2 swaps
/// in URLSessionConfiguration.background behind this protocol.
protocol DownloadTransport: Sendable {
    @MainActor func start(tuneID: Int64, url: URL, authHeader: [String: String])
    @MainActor func cancel(tuneID: Int64)
    var events: AsyncStream<DownloadEvent> { get }
}

final class ForegroundTransport: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private var session: URLSession!
    /// tuneID → task, guarded by the delegate queue being serial + MainActor start/cancel.
    private var tasks: [Int64: URLSessionDownloadTask] = [:]
    private let stagingDir: URL

    override init() {
        (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("crates-dl-staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        super.init()
        let config = URLSessionConfiguration.default
        // Conversion is an idle-network window (~0.5s per source-minute, zero bytes flowing) —
        // a 2h mix would trip the default 60s request timeout.
        config.timeoutIntervalForRequest = 180
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    @MainActor func start(tuneID: Int64, url: URL, authHeader: [String: String]) {
        var request = URLRequest(url: url)
        for (key, value) in authHeader { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.downloadTask(with: request)
        task.taskDescription = String(tuneID) // task→tune key; survives relaunch under a bg session (v2)
        tasks[tuneID] = task
        continuation.yield(.preparing(tuneID))
        task.resume()
    }

    @MainActor func cancel(tuneID: Int64) {
        tasks[tuneID]?.cancel()
        tasks[tuneID] = nil
    }

    private static func tuneID(of task: URLSessionTask) -> Int64? {
        task.taskDescription.flatMap(Int64.init)
    }

    // MARK: - URLSessionDownloadDelegate (serial delegate queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = Self.tuneID(of: downloadTask), totalBytesExpectedToWrite > 0 else { return }
        continuation.yield(.progress(id, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = Self.tuneID(of: downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let staged = stagingDir.appendingPathComponent("\(id).part")
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            continuation.yield(.failed(id, message: "Couldn't stage the download.", transient: true))
            return
        }
        continuation.yield(.finished(id,
                                     staged: staged,
                                     status: http?.statusCode ?? 0,
                                     contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                     disposition: http?.value(forHTTPHeaderField: "Content-Disposition")))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = Self.tuneID(of: task) else { return }
        let urlError = error as? URLError
        guard urlError?.code != .cancelled else { return }
        continuation.yield(.failed(id, message: error.localizedDescription, transient: true))
    }
}
