import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Collects response chunks up to a fixed limit, canceling before an oversized body is buffered.
// URLSession delegates and task cancellation share state exclusively through the lock.
final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let redirectDelegate: URLSessionTaskDelegate?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancelled = false

    init(limit: Int, redirectDelegate: URLSessionTaskDelegate?) {
        self.limit = max(0, limit)
        self.redirectDelegate = redirectDelegate
    }

    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (
        Data, HTTPURLResponse
    ) {
        var request = request
        for (name, value) in session.configuration.httpAdditionalHeaders ?? [:] {
            if let name = name as? String, request.value(forHTTPHeaderField: name) == nil {
                request.setValue(String(describing: value), forHTTPHeaderField: name)
            }
        }
        let receiver = BoundedResponse(
            limit: limit, redirectDelegate: session.delegate as? URLSessionTaskDelegate)
        #if canImport(FoundationNetworking)
        // Corelibs doesn't route data callbacks through URLSessionTask.delegate.
        let activeSession = URLSession(
            configuration: session.configuration, delegate: receiver, delegateQueue: nil)
        defer { activeSession.finishTasksAndInvalidate() }
        #else
        let activeSession = session
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = activeSession.dataTask(with: request)
                #if !canImport(FoundationNetworking)
                task.delegate = receiver
                #endif
                receiver.start(task, continuation: continuation)
            }
        } onCancel: {
            receiver.cancel()
        }
    }

    private func start(
        _ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()), cancelTask: true)
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>, cancelTask: Bool = false) {
        lock.lock()
        let continuation = self.continuation, task = self.task
        self.continuation = nil
        self.task = nil
        response = nil
        body = Data()
        lock.unlock()
        if cancelTask { task?.cancel() }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)), cancelTask: true)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            finish(.failure(URLError(.dataLengthExceedsMaximum)), cancelTask: true)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let active = continuation != nil
        if active { self.response = response }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let oversized = data.count > limit - body.count
        if !oversized { body.append(data) }
        lock.unlock()
        if oversized { finish(.failure(URLError(.dataLengthExceedsMaximum)), cancelTask: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = self.response, data = body
        lock.unlock()
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((data, response)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        #if canImport(FoundationNetworking)
        if let redirectDelegate {
            redirectDelegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: completionHandler)
            return
        }
        #else
        if let redirectDelegate,
            redirectDelegate.responds(
                to: #selector(
                    URLSessionTaskDelegate.urlSession(
                        _:task:willPerformHTTPRedirection:newRequest:completionHandler:)))
        {
            redirectDelegate.urlSession?(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: completionHandler)
            return
        }
        #endif
        completionHandler(request)
    }
}
