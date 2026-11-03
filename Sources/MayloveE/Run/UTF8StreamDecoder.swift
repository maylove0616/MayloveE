import Foundation

/// Decodes UTF-8 arriving in arbitrary chunks, holding back a multi-byte character split across reads.
struct UTF8StreamDecoder {
    private var pending = Data()

    mutating func decode(_ data: Data) -> String {
        pending.append(data)
        let complete = pending.count - Self.incompleteSuffixLength(of: pending)
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending = Data(pending.suffix(from: pending.startIndex + complete))
        return text
    }

    /// Bytes at the end that start a character whose remaining bytes have not arrived yet.
    private static func incompleteSuffixLength(of data: Data) -> Int {
        let bytes = Array(data.suffix(3))
        for (offset, byte) in bytes.reversed().enumerated() {
            let available = offset + 1
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte; keep looking for the lead
            let needed: Int
            switch byte {
            case 0b1111_0000...: needed = 4
            case 0b1110_0000...: needed = 3
            case 0b1100_0000...: needed = 2
            default: needed = 1
            }
            return needed > available ? available : 0
        }
        return 0
    }
}
