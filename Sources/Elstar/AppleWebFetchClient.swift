//
//  AppleWebFetchClient.swift
//  Elstar
//
//  URLSession-based public-page fetch client plus DNS resolution, feeding the
//  pure `ApplePublicWebFetcher` whose destination validation is the SSRF
//  boundary. Redirects are handled by the fetcher so every hop is revalidated.
//

import Foundation

/// One-hop GET with redirects disabled and no cookies or credentials.
public final class AppleURLSessionWebFetchClient: NSObject, AppleWebFetchHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> AppleHTTPHop {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Elstar/1.0 (iPhone; public page reader)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        return AppleHTTPHop(
            status: http.statusCode,
            headers: headers,
            body: data.prefix(maxBytes),
            location: http.value(forHTTPHeaderField: "Location")
        )
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never follow redirects here; the fetcher revalidates each Location.
        completionHandler(nil)
    }
}

/// Resolves a host name to its numeric addresses. Uses the system resolver;
/// the pure fetcher then rejects any private result.
public final class SystemHostResolver: AppleHostResolving, @unchecked Sendable {

    public init() {}
    public func resolve(host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                guard status == 0, let head = result else {
                    continuation.resume(throwing: URLError(.cannotFindHost))
                    return
                }
                defer { freeaddrinfo(head) }
                var addresses: [String] = []
                var pointer: UnsafeMutablePointer<addrinfo>? = head
                while let current = pointer {
                    if let sockaddr = current.pointee.ai_addr {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        let length = socklen_t(current.pointee.ai_addrlen)
                        if getnameinfo(sockaddr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            addresses.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                        }
                    }
                    pointer = current.pointee.ai_next
                }
                continuation.resume(returning: addresses)
            }
        }
    }
}