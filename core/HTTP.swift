import Foundation

/// HTTPS requests for the network sources (the OpenRouter catalog and activity, Toggl Track), with the
/// rules of the Python engine's `urllib` calls: a status outside 200-299 is an error, redirects are refused
/// unless asked for, and a body over the size limit is an error.
enum HTTP {
    struct Response {
        let status: Int
        let body: Data
        /// Header names in lower case.
        let headers: [String: String]
    }

    enum Failure: Error {
        /// A status outside 200-299 (a redirect too, when redirects are refused), with the first KiB of the body.
        case status(Int, body: Data)
        /// The body was larger than the limit.
        case tooLarge
        /// No response: the host could not be reached, the connection failed or timed out.
        case transport(String, timedOut: Bool)

        /// What Python prints for the same `urllib` error (`str(error)`).
        var pythonText: String {
            switch self {
            case let .status(code, _): "HTTP Error \(code): \(HTTP.reason(code))"
            case .tooLarge: "Response exceeds the size limit"
            case let .transport(message, timedOut): timedOut ? "timed out" : "<urlopen error \(message)>"
            }
        }
    }

    /// `TRACKER_HTTP_ROOT` (like `http://127.0.0.1:8000`) replaces the scheme and host, so the parity check can
    /// serve both engines the same responses offline (Python's `openrouter.endpoint`).
    static func endpoint(_ url: String) -> String {
        guard let root = ProcessInfo.processInfo.environment["TRACKER_HTTP_ROOT"], !root.isEmpty else { return url }
        let rest = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
        var base = root
        while base.hasSuffix("/") { base.removeLast() }
        guard let slash = rest.firstIndex(of: "/") else { return base }
        return base + rest[slash...]
    }

    /// `urllib.parse.urlencode`: `quote_plus` on each key and value.
    static func query(_ pairs: [(String, String)]) -> String {
        func quote(_ text: String) -> String {
            var out = ""
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "."),
                     UInt8(ascii: "-"), UInt8(ascii: "~"):
                    out.append(Character(Unicode.Scalar(byte)))
                case UInt8(ascii: " "):
                    out += "+"
                default:
                    out += String(format: "%%%02X", byte)
                }
            }
            return out
        }
        return pairs.map { quote($0.0) + "=" + quote($0.1) }.joined(separator: "&")
    }

    /// Sends one request and waits for the whole response.
    static func send(_ url: String, method: String = "GET", headers: [String: String], body: Data? = nil,
                     timeout: TimeInterval, limit: Int, redirects: Bool, useTestEndpoint: Bool = true) throws -> Response {
        guard let address = URL(string: useTestEndpoint ? endpoint(url) : url) else {
            throw Failure.transport("unknown url type: \(url)", timedOut: false)
        }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let collector = Collector(limit: limit, redirects: redirects)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        session.dataTask(with: request).resume()
        collector.done.wait()
        session.finishTasksAndInvalidate()

        if let response = collector.response, !(200..<300).contains(response.statusCode) {
            throw Failure.status(response.statusCode, body: collector.data.prefix(1024))
        }
        if collector.overflow { throw Failure.tooLarge }
        if let error = collector.error {
            let code = (error as? URLError)?.code
            throw Failure.transport(error.localizedDescription, timedOut: code == .timedOut)
        }
        guard let response = collector.response else {
            throw Failure.transport("no response", timedOut: false)
        }
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { fields[name.lowercased()] = value }
        }
        return Response(status: response.statusCode, body: collector.data, headers: fields)
    }

    /// Python's `http.HTTPStatus` phrases, which `HTTPError` prints.
    static func reason(_ code: Int) -> String {
        let phrases = [
            300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
            402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
            408: "Request Timeout", 409: "Conflict", 410: "Gone", 413: "Request Entity Too Large",
            422: "Unprocessable Entity", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
            502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
        ]
        if let phrase = phrases[code] { return phrase }
        return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }

    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let limit: Int
        let redirects: Bool
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        var overflow = false

        init(limit: Int, redirects: Bool) {
            self.limit = limit
            self.redirects = redirects
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            if self.data.count > limit {
                overflow = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(redirects ? request : nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            self.error = error
            done.signal()
        }
    }
}
