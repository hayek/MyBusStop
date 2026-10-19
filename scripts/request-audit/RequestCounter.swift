import Foundation
import ObjectiveC

/// Counts every HTTP request the process makes, per phase, and forwards it unchanged.
/// URLSession.shared sees it through registerClass; sessions built from `.default`/`.ephemeral`
/// configurations see it because those factory methods are swapped to prepend this class.
final class RequestCounter: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var phase = "init"
    nonisolated(unsafe) static var records: [(phase: String, method: String, url: String, bytes: Int)] = []
    static let lock = NSLock()
    nonisolated(unsafe) static var forward: URLSession!
    private var forwarded: URLSessionDataTask?

    static func install() {
        // Built before the swap, so forwarded requests are not counted twice.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        forward = URLSession(configuration: configuration)
        URLProtocol.registerClass(RequestCounter.self)
        for selector in [NSSelectorFromString("defaultSessionConfiguration"), NSSelectorFromString("ephemeralSessionConfiguration")] {
            guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else { continue }
            typealias Factory = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
            let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
            let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { me in
                let c = original(me, selector)
                c.protocolClasses = [RequestCounter.self] + (c.protocolClasses ?? [])
                return c
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    static func take() -> [(phase: String, method: String, url: String, bytes: Int)] {
        lock.lock(); defer { lock.unlock() }
        let out = records; records = []; return out
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme, scheme.hasPrefix("http") else { return false }
        return URLProtocol.property(forKey: "counted", in: request) == nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let marked = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "counted", in: marked)
        let phase = Self.phase
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "?"
        forwarded = Self.forward.dataTask(with: marked as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            Self.lock.lock(); Self.records.append((phase, method, url, data?.count ?? 0)); Self.lock.unlock()
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwarded?.resume()
    }

    override func stopLoading() { forwarded?.cancel() }
}
