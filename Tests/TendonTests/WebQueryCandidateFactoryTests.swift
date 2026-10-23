import Foundation
import XCTest
@testable import Tendon

final class WebQueryCandidateFactoryTests: XCTestCase {
    func testWebURLsOpenDirectlyAndPreserveTheirDestination() throws {
        let inputs = [
            "https://example.com/path?q=a%20b&other=1#section",
            "http://localhost:3000/path",
            "HTTPS://example.com/path",
            "https://例え.jp/検索?q=日本語",
            "http://[::1]:8080/path"
        ]

        for input in inputs {
            let candidate = try XCTUnwrap(WebQueryCandidateFactory.candidate(for: input))
            XCTAssertEqual(candidate.targetKind, .webURL, input)
            XCTAssertEqual(candidate.url, URL(string: input), input)
            XCTAssertTrue(candidate.name.hasPrefix("URL を開く: "), input)
            XCTAssertEqual(candidate.subtitle, candidate.url?.absoluteString, input)
        }
    }

    func testAddressesWithoutSchemeUseHTTPS() throws {
        let inputs = [
            "example.com",
            "www.example.com/path?q=value#section",
            "example.com:8443/path",
            "example.com/?next=https://other.example/path",
            "localhost:3000",
            "127.0.0.1:8080/path",
            "[::1]:3000/path",
            "例え.jp/検索"
        ]

        for input in inputs {
            let candidate = try XCTUnwrap(WebQueryCandidateFactory.candidate(for: input))
            XCTAssertEqual(candidate.targetKind, .webURL, input)
            XCTAssertEqual(candidate.url, URL(string: "https://\(input)"), input)
        }
    }

    func testPlainTextAndMalformedAddressesStillSearchGoogle() throws {
        let inputs = [
            "swift",
            "日本語の検索",
            "example.com documentation",
            "C++ & Swift #1",
            "1.2",
            "999.0.0.1",
            "example..com",
            "https://",
            "https:///path",
            "https://example.com:invalid",
            "ftp://example.com/file",
            "mailto:user@example.com",
            "user@example.com",
            "/Applications/Safari.app"
        ]

        for input in inputs {
            let candidate = try XCTUnwrap(WebQueryCandidateFactory.candidate(for: input))
            XCTAssertEqual(candidate.targetKind, .webSearch, input)
            let components = try XCTUnwrap(candidate.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            })
            XCTAssertEqual(components.host, "www.google.com", input)
            XCTAssertEqual(components.path, "/search", input)
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: input)], input)
        }
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let candidate = try XCTUnwrap(WebQueryCandidateFactory.candidate(for: " \nhttps://example.com/path\t"))
        XCTAssertEqual(candidate.targetKind, .webURL)
        XCTAssertEqual(candidate.url?.absoluteString, "https://example.com/path")

        let search = try XCTUnwrap(WebQueryCandidateFactory.candidate(for: "  search terms\n"))
        XCTAssertEqual(search.targetKind, .webSearch)
        XCTAssertEqual(search.name, "Google 検索: search terms")
    }

    func testEmptyInputHasNoWebCandidate() {
        XCTAssertNil(WebQueryCandidateFactory.candidate(for: ""))
        XCTAssertNil(WebQueryCandidateFactory.candidate(for: " \t\n"))
    }
}
