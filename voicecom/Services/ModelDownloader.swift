import Foundation

/// Downloads a file to a destination URL while reporting progress.
///
/// Uses `URLSessionDownloadDelegate` so we get `didWriteData` progress callbacks —
/// `URLSession.download(from:)` (the async convenience API) reports no progress, which
/// makes large model downloads look stalled. The completed temp file is moved to
/// `destination` synchronously inside the delegate callback, since URLSession deletes it
/// once the callback returns.
///
/// Progress callbacks are throttled to whole-percent changes to avoid flooding the UI.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    /// Receives a 0.0–1.0 fraction, or nil when the total size is unknown.
    /// Called on the session's (serial) delegate queue.
    private let onProgress: @Sendable (Double?) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReportedPercent = -1

    init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads `url` into `destination`. Throws on HTTP error, network failure,
    /// task cancellation, or if the completed file can't be moved into place.
    func download(from url: URL, resourceTimeout: TimeInterval = 1200) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = resourceTimeout // whole-download budget
        config.timeoutIntervalForRequest = 60                // max gap between chunks
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            onProgress(nil)
            return
        }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        onProgress(Double(percent) / 100.0)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = TranscriptionError.modelDownloadFailed
            return
        }
        do {
            // Remove any partial file from a previous attempt, then move into place.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume(returning: ())
        }
        continuation = nil
    }
}
