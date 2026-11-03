import Foundation

/// Splits a byte stream into LSP message bodies framed by `Content-Length` headers.
struct MessageFramer {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private var buffer = Data()

    /// Appends received bytes and returns every complete message body now available.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        while let headerEnd = buffer.range(of: Self.headerTerminator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(in: header) else {
                // Not an LSP header (e.g. a stray log line); drop it and resync.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            bodies.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return bodies
    }

    static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private static func contentLength(in header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
