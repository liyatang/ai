import Foundation

final class NetworkProbe: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var startedAt = Date()
    private var completion: ((ProbeSample) -> Void)?
    private var requestSent = false
    private var finished = false

    @discardableResult
    func start(_ completion: @escaping (ProbeSample) -> Void) -> Bool {
        guard task == nil,
              let url = URL(string: "https://chatgpt.com/cdn-cgi/trace") else { return false }
        self.completion = completion
        startedAt = Date()
        finished = false
        requestSent = false

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
        guard self.session === session else { completionHandler(.cancel); return }
        let latency = Date().timeIntervalSince(startedAt) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        finish(latencyMs: latency, ok: (200..<300).contains(status), stage: "http", status: status)
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.session === session else { return }
        if !finished { finish(latencyMs: nil, ok: false, stage: Self.failureStage(error, requestSent: requestSent)) }
    }

    static func failureStage(_ error: Error?, requestSent: Bool = false) -> String {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return "unknown" }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "dns"
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet: return "connect"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired: return "tls"
        case NSURLErrorTimedOut: return requestSent ? "response_timeout" : "timeout"
        default: return "unknown"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard self.session === session else { return }
        requestSent = metrics.transactionMetrics.last?.requestEndDate != nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not attribute another host's response to the official probe domain.
        completionHandler(nil)
    }

    private func finish(latencyMs: Double?, ok: Bool, stage: String, status: Int? = nil) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        let sample = ProbeSample(at: Date().timeIntervalSince1970, latency_ms: ok ? latencyMs : nil,
                                 ok: ok, domain: "chatgpt.com", stage: stage, http_status: status)
        DispatchQueue.main.async { callback?(sample) }
    }
}
