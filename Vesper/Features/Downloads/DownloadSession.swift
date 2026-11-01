import Foundation
import UIKit
import VesperCore

/// A serial delegate stages verified files before handing ownership to the app's transaction queue.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var lastProgress: [Int: TimeInterval] = [:]
    private var rejected: Set<Int> = []

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let key = DownloadTaskKey(downloadTask.taskDescription),
            !rejected.contains(downloadTask.taskIdentifier)
        else { return }
        let response = downloadTask.response as? HTTPURLResponse
        if let status = response?.statusCode, status != 200 && status != 206 {
            rejected.insert(downloadTask.taskIdentifier)
            let after = response?.value(forHTTPHeaderField: "Retry-After")
            downloadTask.cancel()
            DispatchQueue.main.async {
                DownloadManager.shared.receiveHTTPFailure(key, status: status, code: 0, retryAfter: after)
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastProgress[downloadTask.taskIdentifier] ?? 0) >= 1 else { return }
        lastProgress[downloadTask.taskIdentifier] = now
        let etag = response?.value(forHTTPHeaderField: "ETag")
        let modified = response?.value(forHTTPHeaderField: "Last-Modified")
        let total =
            DownloadPolicy.totalBytes(
                contentRange: response?.value(forHTTPHeaderField: "Content-Range"),
                contentLength: response?.expectedContentLength ?? -1) ?? totalBytesExpectedToWrite
        DispatchQueue.main.async {
            DownloadManager.shared.receiveProgress(
                key, written: totalBytesWritten, expected: total, etag: etag, modified: modified)
        }
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let key = DownloadTaskKey(downloadTask.taskDescription) else { return }
        DispatchQueue.main.async {
            DownloadManager.shared.receiveResumed(key, offset: fileOffset, total: expectedTotalBytes)
        }
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let key = DownloadTaskKey(downloadTask.taskDescription),
            !rejected.contains(downloadTask.taskIdentifier)
        else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            DispatchQueue.main.async {
                DownloadManager.shared.receiveHTTPFailure(
                    key, status: nil, code: NSURLErrorBadServerResponse, retryAfter: nil)
            }
            return
        }
        let status = response.statusCode
        if status != 200 && status != 206 {
            let after = response.value(forHTTPHeaderField: "Retry-After")
            rejected.insert(downloadTask.taskIdentifier)
            DispatchQueue.main.async {
                DownloadManager.shared.receiveHTTPFailure(key, status: status, code: 0, retryAfter: after)
            }
            return
        }
        do {
            do {
                try HTTPDownloadPolicy.validateCompletion(
                    status: status,
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: response.expectedContentLength, actualBytes: DownloadFiles.size(location),
                    encoding: response.value(forHTTPHeaderField: "Content-Encoding"),
                    mime: response.mimeType, prefix: DownloadFiles.prefix(location))
            } catch DownloadFailure.unsupported {
                rejected.insert(downloadTask.taskIdentifier)
                DispatchQueue.main.async { DownloadManager.shared.receiveRejection(key, status: status) }
                return
            } catch {
                rejected.insert(downloadTask.taskIdentifier)
                let code =
                    error is HTTPDownloadError ? NSURLErrorBadServerResponse : NSURLErrorNetworkConnectionLost
                DispatchQueue.main.async {
                    DownloadManager.shared.receiveHTTPFailure(key, status: nil, code: code, retryAfter: nil)
                }
                return
            }
            let destination = DownloadFiles.stagingURL(key)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try DownloadFiles.protect(destination)
            let total =
                HTTPDownloadPolicy.isIdentityEncoding(response.value(forHTTPHeaderField: "Content-Encoding"))
                ? DownloadPolicy.totalBytes(
                    contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                    contentLength: response.expectedContentLength) : nil
            let receipt = DownloadReceipt(
                location: destination, status: status, mime: response.mimeType, total: total)
            DispatchQueue.main.async { DownloadManager.shared.receiveCompletion(key, receipt: receipt) }
        } catch {
            DispatchQueue.main.async {
                DownloadManager.shared.receiveFailure(key, code: NSURLErrorCannotWriteToFile, resumeData: nil)
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastProgress[task.taskIdentifier] = nil
        let wasRejected = rejected.remove(task.taskIdentifier) != nil
        guard !wasRejected, let error, let key = DownloadTaskKey(task.taskDescription) else { return }
        let response = task.response as? HTTPURLResponse
        let status = response.flatMap { $0.statusCode == 200 || $0.statusCode == 206 ? nil : $0.statusCode }
        let after = response?.value(forHTTPHeaderField: "Retry-After")
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let code = (error as NSError).code
        DispatchQueue.main.async {
            DownloadManager.shared.receiveHTTPFailure(
                key, status: status, code: code, retryAfter: after, resumeData: data)
        }
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let key = DownloadTaskKey(task.taskDescription) else { return }
        DispatchQueue.main.async { DownloadManager.shared.receiveWaiting(key) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { DownloadManager.shared.finishBackgroundEvents() }
    }
}

@MainActor final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.sessionID else { completionHandler(); return }
        DownloadManager.shared.backgroundCompletion = completionHandler
        DownloadManager.shared.start()
    }
}
