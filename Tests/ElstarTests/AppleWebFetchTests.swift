import Testing
import Foundation
@testable import Elstar

@Suite("Web fetch boundary")
struct AppleWebFetchTests {

    @Test("IP classification blocks private, loopback, link-local, and metadata")
    func ipClassification() {
        #expect(AppleIPAddress.isPublicLiteral("93.184.216.34") == true)
        #expect(AppleIPAddress.isPublicLiteral("127.0.0.1") == false)
        #expect(AppleIPAddress.isPublicLiteral("10.0.0.1") == false)
        #expect(AppleIPAddress.isPublicLiteral("192.168.1.1") == false)
        #expect(AppleIPAddress.isPublicLiteral("172.16.0.1") == false)
        #expect(AppleIPAddress.isPublicLiteral("169.254.169.254") == false)
        #expect(AppleIPAddress.isPublicLiteral("100.64.0.1") == false)
        #expect(AppleIPAddress.isPublicLiteral("::1") == false)
        #expect(AppleIPAddress.isPublicLiteral("fe80::1") == false)
        #expect(AppleIPAddress.isPublicLiteral("not-an-ip") == nil)
    }

    @Test("Validation rejects non-https, credentials, local hosts, and private resolution")
    func validation() async throws {
        let fetcher = ApplePublicWebFetcher(client: FakeHTTPClient(), resolver: FakeHostResolver())

        await #expect(throws: AppleToolError.self) {
            try await fetcher.validatedURL(URL(string: "http://example.com")!)
        }
        await #expect(throws: AppleToolError.self) {
            try await fetcher.validatedURL(URL(string: "https://user:pass@example.com")!)
        }
        await #expect(throws: AppleToolError.self) {
            try await fetcher.validatedURL(URL(string: "https://localhost")!)
        }
        await #expect(throws: AppleToolError.self) {
            try await fetcher.validatedURL(URL(string: "https://10.0.0.5")!)
        }

        let privateResolver = FakeHostResolver()
        privateResolver.addresses = ["192.168.0.10"]
        let privateFetcher = ApplePublicWebFetcher(client: FakeHTTPClient(), resolver: privateResolver)
        await #expect(throws: AppleToolError.self) {
            try await privateFetcher.validatedURL(URL(string: "https://internal.example.com")!)
        }

        let publicURL = URL(string: "https://example.com/page")!
        #expect(try await fetcher.validatedURL(publicURL) == publicURL)
    }

    @Test("Fetch extracts title, text, and links from a bounded page")
    func fetchPage() async throws {
        let client = FakeHTTPClient()
        let url = URL(string: "https://example.com/page")!
        let html = """
        <html><head><title>Hello &amp; Welcome</title>
        <style>.x{}</style><script>alert('x')</script></head>
        <body><h1>Hi</h1><a href="/next">Next page</a></body></html>
        """
        client.hops[url] = AppleHTTPHop(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8), location: nil)

        let fetcher = ApplePublicWebFetcher(client: client, resolver: FakeHostResolver())
        let page = try await fetcher.fetch(AppleFetchWebPageRequest(url: url))
        #expect(page.title == "Hello & Welcome")
        #expect(page.text.contains("Hi"))
        #expect(!page.text.contains("alert"))
        #expect(page.links.first?.text == "Next page")
        #expect(page.links.first?.url.absoluteString == "https://example.com/next")
    }

    @Test("Redirects are followed and revalidated; private redirect targets are blocked")
    func redirects() async {
        let client = FakeHTTPClient()
        let url = URL(string: "https://example.com/start")!
        client.hops[url] = AppleHTTPHop(status: 302, headers: [:], body: Data(), location: "https://10.0.0.1/secret")

        let fetcher = ApplePublicWebFetcher(client: client, resolver: FakeHostResolver())
        await #expect(throws: AppleToolError.self) {
            _ = try await fetcher.fetch(AppleFetchWebPageRequest(url: url))
        }
    }

    @Test("A non-HTML response is declined as an unsupported format")
    func unsupportedFormat() async {
        let client = FakeHTTPClient()
        let url = URL(string: "https://example.com/image")!
        client.hops[url] = AppleHTTPHop(status: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50]), location: nil)

        let fetcher = ApplePublicWebFetcher(client: client, resolver: FakeHostResolver())
        await #expect(throws: AppleToolError.self) {
            _ = try await fetcher.fetch(AppleFetchWebPageRequest(url: url))
        }
    }

    @Test("Too many redirects is refused rather than looping")
    func tooManyRedirects() async {
        let client = FakeHTTPClient()
        let fetcher = ApplePublicWebFetcher(client: client, resolver: FakeHostResolver())
        var url = URL(string: "https://example.com/0")!
        for index in 0..<8 {
            let next = URL(string: "https://example.com/\(index + 1)")!
            client.hops[url] = AppleHTTPHop(status: 301, headers: [:], body: Data(), location: next.absoluteString)
            url = next
        }
        await #expect(throws: AppleToolError.self) {
            _ = try await fetcher.fetch(AppleFetchWebPageRequest(url: URL(string: "https://example.com/0")!))
        }
    }
}
