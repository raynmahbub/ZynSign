import Foundation

/// Bounded, paginated hex + ASCII dump formatter and hex-byte parser for the
/// in-app File Manager Hex Inspector & Editor.
enum HexDumpFormatter {

    struct HexRow: Equatable, Hashable, Sendable, Identifiable {
        var id: Int { offset }
        let offset: Int
        let offsetHex: String
        let bytesHex: String
        let asciiPreview: String
    }

    enum HexParseError: Error, Equatable, Sendable {
        case oddNibbleCount
        case invalidHexCharacter(Character)

        var message: String {
            switch self {
            case .oddNibbleCount:
                return "Hex input must contain an even number of hexadecimal digits."
            case .invalidHexCharacter(let ch):
                return "“\(ch)” is not a hexadecimal digit (0–9, A–F)."
            }
        }
    }

    static func formatWindow(
        data: Data,
        startOffset: Int = 0,
        bytesPerRow: Int = 16,
        maxRows: Int = 128
    ) -> [HexRow] {
        let width = max(8, min(32, bytesPerRow))
        let clampedStart = max(0, min(startOffset, data.count))
        guard clampedStart < data.count else { return [] }
        let maxBytes = min(data.count - clampedStart, width * max(1, maxRows))
        let slice = data.subdata(in: clampedStart..<(clampedStart + maxBytes))

        var rows: [HexRow] = []
        var cursor = 0
        while cursor < slice.count {
            let end = min(cursor + width, slice.count)
            let chunk = slice.subdata(in: cursor..<end)
            let absoluteOffset = clampedStart + cursor
            let hexTokens = chunk.map { String(format: "%02X", $0) }
            let paddedTokens = hexTokens + Array(repeating: "  ", count: max(0, width - hexTokens.count))
            let ascii = String(chunk.map { byte -> Character in
                (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            })
            rows.append(HexRow(
                offset: absoluteOffset,
                offsetHex: String(format: "%08X", absoluteOffset),
                bytesHex: paddedTokens.joined(separator: " "),
                asciiPreview: ascii
            ))
            cursor = end
        }
        return rows
    }

    static func encodeHexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func parseHexBytes(_ text: String) throws -> Data {
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(text.utf8.count)
        for ch in text where !ch.isWhitespace && ch != ":" && ch != "-" {
            guard let nibble = hexNibble(ch) else {
                throw HexParseError.invalidHexCharacter(ch)
            }
            cleaned.append(nibble)
        }
        guard cleaned.count.isMultiple(of: 2) else {
            throw HexParseError.oddNibbleCount
        }
        var output = Data(capacity: cleaned.count / 2)
        var idx = 0
        while idx < cleaned.count {
            output.append((cleaned[idx] << 4) | cleaned[idx + 1])
            idx += 2
        }
        return output
    }

    private static func hexNibble(_ ch: Character) -> UInt8? {
        guard let ascii = ch.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return ascii - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
