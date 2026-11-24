import XCTest
@testable import iris

final class MCPHTTPGateTests: XCTestCase {
    let token = String(repeating: "t", count: 43)

    private func head(_ headers: [(String, String)], method: String = "POST", target: String = "/mcp") -> RequestHead {
        RequestHead(method: method, target: target, headers: headers.map { ($0.0.lowercased(), $0.1) })
    }

    private func signed(_ headers: [(String, String)] = [("Content-Length", "2")]) -> [(String, String)] {
        [("Authorization", "Bearer \(token)")] + headers
    }

    func testToken() {
        XCTAssertEqual(gate(head([("Content-Length", "2")]), token: token), .refuse(status: 401))
        XCTAssertEqual(gate(head([("Authorization", "Bearer wrong"), ("Content-Length", "2")]), token: token), .refuse(status: 401))
        XCTAssertEqual(gate(head([("Authorization", "Basic \(token)"), ("Content-Length", "2")]), token: token), .refuse(status: 401))
        XCTAssertEqual(gate(head([("Authorization", token), ("Content-Length", "2")]), token: token), .refuse(status: 401))
        XCTAssertEqual(gate(head(signed(signed())), token: token), .refuse(status: 401), "two Authorization headers")
        XCTAssertEqual(gate(head(signed()), token: token), .accept(bodyLength: 2))
        XCTAssertEqual(gate(head([("Authorization", "bearer \(token)"), ("Content-Length", "2")]), token: token), .accept(bodyLength: 2))
    }

    func testTokenComesFirst() {
        // Everything else wrong too: still 401 and nothing more.
        let bad = head([("Origin", "https://example.com"), ("Transfer-Encoding", "chunked")], method: "DELETE", target: "/other")
        XCTAssertEqual(gate(bad, token: token), .refuse(status: 401))
    }

    func testOrigin() {
        XCTAssertEqual(gate(head(signed([("Origin", "https://example.com"), ("Content-Length", "2")])), token: token), .refuse(status: 403))
        XCTAssertEqual(gate(head(signed([("Origin", "null"), ("Content-Length", "2")])), token: token), .refuse(status: 403))
        XCTAssertEqual(gate(head(signed([("Origin", ""), ("Content-Length", "2")])), token: token), .refuse(status: 403))
    }

    func testPathAndMethod() {
        XCTAssertEqual(gate(head(signed(), target: "/other"), token: token), .refuse(status: 404))
        XCTAssertEqual(gate(head(signed(), target: "/mcp/"), token: token), .refuse(status: 404))
        XCTAssertEqual(gate(head(signed(), target: "/mcp?x=1"), token: token), .accept(bodyLength: 2))
        for method in ["GET", "DELETE", "HEAD", "PUT", "OPTIONS", "BREW"] {
            XCTAssertEqual(gate(head(signed(), method: method), token: token), .refuse(status: 405), method)
        }
    }

    func testAccept() {
        XCTAssertEqual(gate(head(signed([("Accept", "text/event-stream"), ("Content-Length", "2")])), token: token), .refuse(status: 406))
        XCTAssertEqual(gate(head(signed([("Accept", "application/json, text/event-stream"), ("Content-Length", "2")])), token: token),
                       .accept(bodyLength: 2))
    }

    func testFraming() {
        XCTAssertEqual(gate(head(signed([])), token: token), .refuse(status: 400), "no Content-Length")
        XCTAssertEqual(gate(head(signed([("Content-Length", "2"), ("Content-Length", "2")])), token: token), .refuse(status: 400))
        XCTAssertEqual(gate(head(signed([("Content-Length", "²")])), token: token), .refuse(status: 400))
        XCTAssertEqual(gate(head(signed([("Content-Length", "+2")])), token: token), .refuse(status: 400))
        XCTAssertEqual(gate(head(signed([("Content-Length", "")])), token: token), .refuse(status: 400))
        XCTAssertEqual(gate(head(signed([("Content-Length", "2"), ("Transfer-Encoding", "chunked")])), token: token), .refuse(status: 400))
        XCTAssertEqual(gate(head(signed([("Content-Length", "1048577")])), token: token), .refuse(status: 413))
        XCTAssertEqual(gate(head(signed([("Content-Length", String(repeating: "9", count: 5000))])), token: token), .refuse(status: 413))
        XCTAssertEqual(gate(head(signed([("Content-Length", "1048576")])), token: token), .accept(bodyLength: 1048576))
        XCTAssertEqual(gate(head(signed([("Content-Length", "0002")])), token: token), .accept(bodyLength: 2))
    }
}
