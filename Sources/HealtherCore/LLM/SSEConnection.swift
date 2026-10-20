import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Delegate-based server-sent-events reader. Works on Linux, where `URLSession.bytes` is unavailable.
final class SSEConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let lock = NSLock()
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 0
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var session: URLSession?

    init(request: URLRequest) {
        self.request = request
    }

    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            lock.withLock { continuation = cont }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
            lock.withLock { session = s }
            let task = s.dataTask(with: request)
            cont.onTermination = { [weak self] _ in
                task.cancel()
                self?.lock.withLock { self?.session?.invalidateAndCancel() }
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard status == 200 else {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty { continuation?.yield(line) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let status = self.status
        let body = errorBody
        let rest = buffer
        lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        if let error {
            cont?.finish(throwing: error)
        } else if status != 200 {
            cont?.finish(throwing: LLMError.http(status: status, body: String(decoding: body, as: UTF8.self)))
        } else {
            let tail = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { cont?.yield(tail) }
            cont?.finish()
        }
    }
}
