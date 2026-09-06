import Foundation

final class NetworkProbe: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startedAt = Date()
    private var completion: ((Double?, Bool) -> Void)?
    private var finished = false

    @discardableResult
    func start(_ completion: @escaping (Double?, Bool) -> Void) -> Bool {
        guard task == nil,
              let url = URL(string: "https://chatgpt.com/cdn-cgi/trace") else { return false }
        self.completion = completion
        startedAt = Date()
        finished = false

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: url)
        request.setValue("AIQuota/1.1", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let latency = Date().timeIntervalSince(startedAt) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        finish(latencyMs: latency, ok: (200..<300).contains(status))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !finished { finish(latencyMs: nil, ok: false) }
    }

    private func finish(latencyMs: Double?, ok: Bool) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async { callback?(latencyMs, ok) }
    }
}

