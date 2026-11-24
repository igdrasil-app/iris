import CryptoKit
import Foundation

// What `iris mcp --http` decides from a request's head alone, before it reads the body. Functions of
// bytes and strings with no socket, so the rules can be tested without a server.

let maxHeadLine = 8192
let maxHeaders = 64
let maxBody = 1024 * 1024

/// Browser origins allowed to call. Empty: a request that carries any Origin is refused.
let allowedOrigins: [String] = []

/// The request line and headers of one HTTP/1.x request.
struct RequestHead {
    let method: String
    let target: String
    /// In the order sent, names lowercased. A repeated header stays repeated, so it can be refused.
    let headers: [(name: String, value: String)]

    func values(_ name: String) -> [String] {
        headers.filter { $0.name == name }.map(\.value)
    }
}

/// The head without its closing blank line, read in the narrowest grammar: printable ASCII and tabs,
/// CRLF line ends, a request line of an upper-case method, a target starting with / and HTTP/1.0 or
/// HTTP/1.1, then at most `maxHeaders` lines of `name: value`. Anything else is nil, answered 400.
/// The system's parser, CFHTTPMessage, is not used: it takes bare LF, NUL and folded lines, and drops
/// a header line without a colon without saying so.
func parseHead(_ bytes: [UInt8]) -> RequestHead? {
    guard bytes.allSatisfy({ $0 == 0x09 || $0 == 0x0D || $0 == 0x0A || (0x20...0x7E).contains($0) }) else { return nil }
    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
    guard lines.count <= maxHeaders + 1,
          lines.allSatisfy({ $0.utf8.count <= maxHeadLine && !$0.utf8.contains(0x0D) && !$0.utf8.contains(0x0A) }),
          let requestLine = lines.first else { return nil }

    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
          (1...16).contains(parts[0].utf8.count), parts[0].utf8.allSatisfy({ (0x41...0x5A).contains($0) }),
          parts[1].hasPrefix("/"), parts[1].utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
          parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }

    var headers: [(name: String, value: String)] = []
    for line in lines.dropFirst() {
        // A line that starts with a space or tab continues the one before it (obs-fold): refused.
        guard let colon = line.firstIndex(of: ":"), let first = line.utf8.first, first != 0x20, first != 0x09 else { return nil }
        let name = line[..<colon]
        guard !name.isEmpty, name.utf8.allSatisfy(isTokenCharacter) else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        headers.append((name.lowercased(), value))
    }
    return RequestHead(method: parts[0], target: parts[1], headers: headers)
}

private func isTokenCharacter(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        || "!#$%&'*+-.^_`|~".utf8.contains(byte)
}

enum Gate: Equatable {
    case refuse(status: Int)
    case accept(bodyLength: Int)
}

/// Every parsed request passes this before its body is read, in this order: the token, Origin, path,
/// method, Accept, Expect, and the body's framing. Without the right token the answer is 401 whatever else is
/// wrong. The honest exception: a head `parseHead` refuses is answered 400 before its token is seen.
func gate(_ head: RequestHead, token: String) -> Gate {
    guard authorized(head, token: token) else { return .refuse(status: 401) }
    guard head.values("origin").allSatisfy(allowedOrigins.contains) else { return .refuse(status: 403) }
    guard head.target.prefix(while: { $0 != "?" }) == "/mcp" else { return .refuse(status: 404) }
    guard head.method == "POST" else { return .refuse(status: 405) }

    let accept = head.values("accept")
    if !accept.isEmpty && !["application/json", "application/*", "*/*"].contains(where: accept.joined(separator: ",").contains) {
        return .refuse(status: 406)
    }
    // A client that sent Expect waits for 100 Continue before its body, and none is ever sent.
    guard head.values("expect").isEmpty else { return .refuse(status: 417) }

    // One Content-Length of ASCII digits and no Transfer-Encoding: a body framed two ways is refused.
    let lengths = head.values("content-length")
    guard lengths.count == 1, head.values("transfer-encoding").isEmpty,
          let digits = lengths.first, !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
        return .refuse(status: 400)
    }
    // Judged by its digits before it is converted, so an enormous number never is.
    let significant = digits.drop(while: { $0 == "0" })
    guard significant.count <= String(maxBody).count, let length = Int(significant.isEmpty ? "0" : String(significant)),
          length <= maxBody else { return .refuse(status: 413) }
    return .accept(bodyLength: length)
}

private func authorized(_ head: RequestHead, token: String) -> Bool {
    let values = head.values("authorization")
    guard values.count == 1 else { return false }
    let parts = values[0].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
    return sameSecret(String(parts[1]), token)
}

/// Compared as SHA-256 digests, every byte without stopping early, so the time taken says nothing about the token.
func sameSecret(_ given: String, _ token: String) -> Bool {
    let a = Array(SHA256.hash(data: Data(given.utf8)))
    let b = Array(SHA256.hash(data: Data(token.utf8)))
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
}
