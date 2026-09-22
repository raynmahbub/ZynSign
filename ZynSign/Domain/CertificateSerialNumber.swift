import Foundation

/// A certificate serial number as the content octets of its INTEGER encoding.
///
/// X.509 serial numbers are arbitrary positive integers. They are not machine
/// integers: a serial may be longer than `UInt64`, and a leading `0x00` octet
/// is significant when the encoding uses it to keep the integer positive.
/// This type stores the hexadecimal form of those exact content octets. It
/// never converts them to `Int` or `UInt64`.
///
/// The hexadecimal text is lowercase, has no `0x` prefix, and preserves
/// leading zero octets. `"0080"` and `"80"` are different serials.
struct CertificateSerialNumber: Equatable, Hashable, CustomStringConvertible {

    /// Lowercase hexadecimal of the INTEGER content octets.
    let hexadecimal: String

    /// Creates a serial from hexadecimal text, or returns `nil` when the text
    /// is empty, odd-length, or not hexadecimal. Uppercase digits are
    /// accepted and normalised to lowercase. Leading zeroes are preserved.
    init?(hexadecimal: String) {
        let normalized = hexadecimal.lowercased()
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else { return nil }
        guard normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.hexadecimal = normalized
    }

    /// Creates a serial from INTEGER content octets, or returns `nil` when
    /// the content is empty.
    init?(contentBytes: [UInt8]) {
        guard !contentBytes.isEmpty else { return nil }
        self.hexadecimal = Self.hexadecimal(of: contentBytes)
    }

    /// The INTEGER content octets. Empty only if the stored text is corrupt,
    /// which the initialisers do not allow.
    var contentBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            let pair = hexadecimal[index..<next]
            if let byte = UInt8(pair, radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    /// The number of INTEGER content octets.
    var contentByteCount: Int { hexadecimal.count / 2 }

    var description: String { hexadecimal }

    /// Lowercase hexadecimal of `bytes`, two digits per octet, including
    /// leading zeroes. An empty input produces an empty string; callers that
    /// require a serial must reject that before constructing a value.
    static func hexadecimal(of bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }
}
