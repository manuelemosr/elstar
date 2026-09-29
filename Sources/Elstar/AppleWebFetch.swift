import Foundation

// MARK: - IP classification

/// Pure IPv4/IPv6 parsing and "is this a globally routable destination?" test.
/// This is the enforcement boundary for web fetch: a request may only leave
/// the device for a public host, and every redirect hop is revalidated.
public nonisolated enum AppleIPAddress {
    /// Returns true when `literal` parses as an IP address that is NOT a
    /// loopback, private, link-local, CGNAT, metadata, multicast, reserved, or
    /// otherwise non-global target. Unknown text is treated as not-literal.
    public static func isPublicLiteral(_ literal: String) -> Bool? {
        if let v4 = parseIPv4(literal) { return isPublicIPv4(v4) }
        if let v6 = parseIPv6(literal) { return isPublicIPv6(v6) }
        return nil
    }

    public static func isPublicIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1]
        switch a {
        case 0: return false                 // "this network" / unspecified
        case 10: return false                // private
        case 100 where (64...127).contains(b): return false // CGNAT 100.64/10
        case 127: return false               // loopback
        case 169 where b == 254: return false // link-local + cloud metadata
        case 172 where (16...31).contains(b): return false  // private
        case 192 where b == 168: return false // private
        case 192 where b == 0 && octets[2] == 0: return false // IETF protocol assignments
        case 198 where (18...19).contains(b): return false  // benchmarking
        case 198 where b == 51 && octets[2] == 100: return false // TEST-NET-2
        case 203 where b == 0 && octets[2] == 113: return false // TEST-NET-3
        case 192 where b == 0 && octets[2] == 2: return false // TEST-NET-1
        case 255: return false               // broadcast
        default:
            if (224...239).contains(a) { return false } // multicast
            if a >= 240 { return false }                // reserved
            return true
        }
    }

    public static func isPublicIPv6(_ groups: [UInt16]) -> Bool {
        guard groups.count == 8 else { return false }
        // Unspecified ::
        if groups.allSatisfy({ $0 == 0 }) { return false }
        // Loopback ::1
        if groups[0...6].allSatisfy({ $0 == 0 }) && groups[7] == 1 { return false }
        let first = groups[0]
        if (first & 0xFE00) == 0xFC00 { return false } // fc00::/7 unique-local
        if (first & 0xFFC0) == 0xFE80 { return false } // fe80::/10 link-local
        if (first & 0xFF00) == 0xFF00 { return false } // ff00::/8 multicast
        // IPv4-mapped ::ffff:a.b.c.d
        if groups[0...4].allSatisfy({ $0 == 0 }) && groups[5] == 0xFFFF {
            let octets: [UInt8] = [
                UInt8(groups[6] >> 8), UInt8(groups[6] & 0xFF),
                UInt8(groups[7] >> 8), UInt8(groups[7] & 0xFF),
            ]
            return isPublicIPv4(octets)
        }
        return true
    }

    public static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part), part.allSatisfy(\.isNumber), !part.isEmpty else { return nil }
            octets.append(value)
        }
        return octets
    }

    public static func parseIPv6(_ text: String) -> [UInt16]? {
        var raw = text
        if raw.hasPrefix("[") && raw.hasSuffix("]") { raw = String(raw.dropFirst().dropLast()) }
        guard raw.contains(":") else { return nil }
        // Reject zone IDs on the literal.
        if let percent = raw.firstIndex(of: "%") { raw = String(raw[..<percent]) }
        let halves = raw.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ s: String) -> [UInt16]? {
            if s.isEmpty { return [] }
            var out: [UInt16] = []
            for part in s.split(separator: ":", omittingEmptySubsequences: false) {
                if part.contains(".") {
                    guard let v4 = parseIPv4(String(part)) else { return nil }
                    out.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
                    out.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
                } else {
                    guard let value = UInt16(part, radix: 16), part.count <= 4 else { return nil }
                    out.append(value)
                }
            }
            return out
        }
        if halves.count == 1 {
            guard let all = groups(halves[0]), all.count == 8 else { return nil }
            return all
        }
        guard let head = groups(halves[0]), let tail = groups(halves[1]), head.count + tail.count <= 8 else { return nil }
        let fill = Array(repeating: UInt16(0), count: 8 - head.count - tail.count)
        return head + fill + tail
    }
}

// MARK: - Fetch limits and transport

public nonisolated struct AppleWebFetchLimits: Sendable {
    public var maxBytes = 512 * 1024
    public var timeout: TimeInterval = 15
    public var maxRedirects = 5
    public var maxLinks = 40
    public var maxTextCharacters = 12_000

    public static let standard = AppleWebFetchLimits()

    public init(maxBytes: Int = 512 * 1024, timeout: TimeInterval = 15, maxRedirects: Int = 5, maxLinks: Int = 40, maxTextCharacters: Int = 12_000) {
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.maxRedirects = maxRedirects
        self.maxLinks = maxLinks
        self.maxTextCharacters = maxTextCharacters
    }

}

/// One HTTP hop with redirects disabled, so the fetcher can revalidate every
/// Location before following it.
public nonisolated struct AppleHTTPHop: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var location: String?

    public init(status: Int, headers: [String: String], body: Data, location: String?) {
        self.status = status
        self.headers = headers
        self.body = body
        self.location = location
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public nonisolated protocol AppleWebFetchHTTPClient: Sendable {
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> AppleHTTPHop
}

/// Resolves a host name to its numeric addresses. Injected so tests can drive
/// SSRF decisions deterministically.
public nonisolated protocol AppleHostResolving: Sendable {
    func resolve(host: String) async throws -> [String]
}

// MARK: - Public fetcher

/// Fetches exactly one public HTTPS page: bounded bytes and time, redirects
/// revalidated hop by hop, no cookies or credentials, no JavaScript. The
/// extracted text is untrusted data for the model — never instructions.
public nonisolated final class ApplePublicWebFetcher: AppleWebFetchService, @unchecked Sendable {
    private let client: any AppleWebFetchHTTPClient
    private let resolver: any AppleHostResolving
    private let limits: AppleWebFetchLimits

    public init(
        client: any AppleWebFetchHTTPClient,
        resolver: any AppleHostResolving,
        limits: AppleWebFetchLimits = .standard
    ) {
        self.client = client
        self.resolver = resolver
        self.limits = limits
    }

    public func fetch(_ request: AppleFetchWebPageRequest) async throws -> AppleFetchedPage {
        let url = try await validatedURL(request.url)
        var current = url
        var hops = 0
        while true {
            let hop = try await client.get(current, timeout: limits.timeout, maxBytes: limits.maxBytes)
            if (300...399).contains(hop.status) {
                guard hops < limits.maxRedirects, let location = hop.location else {
                    throw AppleToolError.network("The page redirected too many times.")
                }
                guard let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw AppleToolError.network("The page returned an invalid redirect.")
                }
                current = try await validatedURL(next)
                hops += 1
                continue
            }
            guard (200...299).contains(hop.status) else {
                throw AppleToolError.network("The page returned an error (\(hop.status)).")
            }
            let contentType = hop.header("Content-Type")?.lowercased() ?? ""
            guard contentType.isEmpty || contentType.contains("text/html") || contentType.contains("text/plain") else {
                throw AppleToolError.unsupportedFormat("This page isn't plain HTML or text, so I can't read it. Try a page that shows its content as text.")
            }
            let body = hop.body.prefix(limits.maxBytes)
            let html = String(decoding: body, as: UTF8.self)
            let extracted = AppleHTMLTextExtractor.extract(html: html, baseURL: current, maxLinks: limits.maxLinks, maxCharacters: limits.maxTextCharacters)
            return AppleFetchedPage(sourceURL: current, title: extracted.title, text: extracted.text, links: extracted.links)
        }
    }

    /// Validates one URL: HTTPS only, no embedded credentials, no blocked
    /// scheme, and every resolved address must be public.
    public func validatedURL(_ url: URL) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw AppleToolError.blocked("Only public https addresses can be fetched.")
        }
        guard url.user == nil, url.password == nil else {
            throw AppleToolError.blocked("Addresses with embedded credentials are not allowed.")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw AppleToolError.blocked("That address has no host.")
        }
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") || lower.hasSuffix(".internal") || lower.hasSuffix(".localhost") {
            throw AppleToolError.blocked("Only public internet addresses can be fetched.")
        }
        // A literal IP must itself be public; otherwise resolve and require
        // every address to be public.
        if let isPublic = AppleIPAddress.isPublicLiteral(lower) {
            guard isPublic else { throw AppleToolError.blocked("Only public internet addresses can be fetched.") }
            return url
        }
        let addresses: [String]
        do {
            addresses = try await resolver.resolve(host: host)
        } catch {
            throw AppleToolError.network("That address could not be resolved.")
        }
        guard !addresses.isEmpty else { throw AppleToolError.network("That address could not be resolved.") }
        for address in addresses {
            guard let isPublic = AppleIPAddress.isPublicLiteral(address), isPublic else {
                throw AppleToolError.blocked("That address resolves to a private or local network, which can't be fetched.")
            }
        }
        return url
    }
}

// MARK: - HTML text extraction

/// Deterministic, bounded readable-text extraction. Strips scripts, styles,
/// and tags, decodes a small entity set, and collects anchor links. Never
/// interprets HTML as instructions.
public nonisolated enum AppleHTMLTextExtractor {
    public struct Extracted: Equatable, Sendable {
        var title: String?
        var text: String
        var links: [AppleFetchedLink]
    }

    public static func extract(html: String, baseURL: URL, maxLinks: Int, maxCharacters: Int) -> Extracted {
        let title = firstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>")
            .map { decodeEntities(stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
        var links: [AppleFetchedLink] = []
        if maxLinks > 0 {
            let anchorPattern = "(?is)<a\\s+[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
            if let regex = try? NSRegularExpression(pattern: anchorPattern) {
                let ns = html as NSString
                let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
                for match in matches where links.count < maxLinks {
                    guard match.numberOfRanges >= 3 else { continue }
                    let href = ns.substring(with: match.range(at: 1))
                    let label = decodeEntities(stripTags(ns.substring(with: match.range(at: 2))))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty,
                          let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
                    links.append(AppleFetchedLink(text: String(label.prefix(120)), url: url))
                }
            }
        }
        var body = html
        body = removingBlocks(body, tag: "script")
        body = removingBlocks(body, tag: "style")
        body = removingBlocks(body, tag: "noscript")
        let text = decodeEntities(stripTags(body))
        let collapsed = text
            .replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extracted(title: title, text: String(collapsed.prefix(maxCharacters)), links: links)
    }

    public static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<[^>]*>", with: " ", options: .regularExpression)
    }

    public static func removingBlocks(_ html: String, tag: String) -> String {
        html.replacingOccurrences(of: "(?is)<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
    }

    public static func decodeEntities(_ text: String) -> String {
        var result = text
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in map { result = result.replacingOccurrences(of: entity, with: value) }
        // Numeric entities.
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard match.numberOfRanges == 2, let scalar = UInt32(ns.substring(with: match.range(at: 1))),
                      let unicode = Unicode.Scalar(scalar) else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(unicode)))
            }
        }
        return result
    }

    public static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}