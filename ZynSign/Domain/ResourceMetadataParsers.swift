import Foundation

/// Lightweight, bounded, pure-Swift parsers for bundled media and asset headers.
///
/// Designed to quickly inspect headers and metadata from raw data prefixes
/// without decoding entire bitmaps or reading large audio/video streams into
/// memory.
public enum ResourceMetadataParsers {

    // MARK: - Image Dimension Parsing

    /// The parsed dimensions of an image.
    public struct ImageDimensions: Equatable, Hashable, Sendable {
        public let width: Int
        public let height: Int
        public let format: String

        public init(width: Int, height: Int, format: String) {
            self.width = width
            self.height = height
            self.format = format
        }
    }

    /// Quickly parses image dimensions from a prefix of bytes.
    public static func parseImageDimensions(from data: Data) -> ImageDimensions? {
        if let png = parsePNGDimensions(from: data) { return png }
        if let jpeg = parseJPEGDimensions(from: data) { return jpeg }
        if let gif = parseGIFDimensions(from: data) { return gif }
        if let webp = parseWebPDimensions(from: data) { return webp }
        return nil
    }

    /// Parses PNG dimensions from the IHDR chunk.
    public static func parsePNGDimensions(from data: Data) -> ImageDimensions? {
        guard data.count >= 24 else { return nil }
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.prefix(8).elementsEqual(signature) else { return nil }
        // IHDR chunk starts at offset 12: chunk type at 12..16 ('IHDR')
        guard data[12] == 0x49, data[13] == 0x48, data[14] == 0x44, data[15] == 0x52 else { return nil }
        let width = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
        let height = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        guard width > 0, height > 0 else { return nil }
        return ImageDimensions(width: width, height: height, format: "PNG")
    }

    /// Parses JPEG dimensions from Start of Frame (SOF) markers.
    public static func parseJPEGDimensions(from data: Data) -> ImageDimensions? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var offset = 2
        while offset + 9 < data.count {
            guard data[offset] == 0xFF else {
                offset += 1
                continue
            }
            let marker = data[offset + 1]
            // SOF0, SOF1, SOF2 markers
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                let height = Int(data[offset + 5]) << 8 | Int(data[offset + 6])
                let width = Int(data[offset + 7]) << 8 | Int(data[offset + 8])
                guard width > 0, height > 0 else { return nil }
                return ImageDimensions(width: width, height: height, format: "JPEG")
            }
            if marker == 0xD9 || marker == 0xDA { // EOI or SOS
                break
            }
            // Read segment length (2 bytes big endian)
            guard offset + 3 < data.count else { break }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard length >= 2 else { break }
            offset += 2 + length
        }
        return nil
    }

    /// Parses GIF dimensions from the GIF header.
    public static func parseGIFDimensions(from data: Data) -> ImageDimensions? {
        guard data.count >= 10 else { return nil }
        let header = String(decoding: data.prefix(6), as: UTF8.self)
        guard header == "GIF87a" || header == "GIF89a" else { return nil }
        let width = Int(data[6]) | (Int(data[7]) << 8)
        let height = Int(data[8]) | (Int(data[9]) << 8)
        guard width > 0, height > 0 else { return nil }
        return ImageDimensions(width: width, height: height, format: "GIF")
    }

    /// Parses WebP dimensions from VP8, VP8L, or VP8X chunks.
    public static func parseWebPDimensions(from data: Data) -> ImageDimensions? {
        guard data.count >= 30 else { return nil }
        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil } // 'RIFF'
        guard data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 else { return nil } // 'WEBP'

        // Check chunk type at offset 12
        if data[12] == 0x56, data[13] == 0x50, data[14] == 0x38, data[15] == 0x20 { // 'VP8 '
            guard data.count >= 30 else { return nil }
            let width = (Int(data[26]) | (Int(data[27]) << 8)) & 0x3FFF
            let height = (Int(data[28]) | (Int(data[29]) << 8)) & 0x3FFF
            return ImageDimensions(width: width, height: height, format: "WebP")
        } else if data[12] == 0x56, data[13] == 0x50, data[14] == 0x38, data[15] == 0x4C { // 'VP8L'
            guard data.count >= 25, data[20] == 0x2F else { return nil }
            let b1 = Int(data[21])
            let b2 = Int(data[22])
            let b3 = Int(data[23])
            let b4 = Int(data[24])
            let width = 1 + (((b2 & 0x3F) << 8) | b1)
            let height = 1 + (((b4 & 0x0F) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6))
            return ImageDimensions(width: width, height: height, format: "WebP")
        } else if data[12] == 0x56, data[13] == 0x50, data[14] == 0x38, data[15] == 0x58 { // 'VP8X'
            guard data.count >= 30 else { return nil }
            let width = 1 + (Int(data[24]) | (Int(data[25]) << 8) | (Int(data[26]) << 16))
            let height = 1 + (Int(data[27]) | (Int(data[28]) << 8) | (Int(data[29]) << 16))
            return ImageDimensions(width: width, height: height, format: "WebP")
        }
        return nil
    }

    // MARK: - Font Metadata Parsing

    /// The extracted metadata of a bundled font.
    public struct FontMetadata: Equatable, Hashable, Sendable {
        public let postScriptName: String
        public let familyName: String
        public let style: String
        public let format: String

        public init(postScriptName: String, familyName: String, style: String, format: String) {
            self.postScriptName = postScriptName
            self.familyName = familyName
            self.style = style
            self.format = format
        }
    }

    /// Parses font metadata from TrueType / OpenType font binary tables.
    public static func parseFontMetadata(from data: Data, fallbackName: String) -> FontMetadata {
        guard data.count >= 12 else {
            return fallbackFontMetadata(fallbackName)
        }

        let sfntVersion = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        let format: String = {
            if sfntVersion == 0x4F54544F { return "OTF" } // 'OTTO'
            if sfntVersion == 0x74746366 { return "TTC" } // 'ttcf'
            return "TTF"
        }()

        let tableCount = Int(data[4]) << 8 | Int(data[5])
        guard tableCount > 0, 12 + tableCount * 16 <= data.count else {
            return fallbackFontMetadata(fallbackName, format: format)
        }

        // Search for 'name' table (tag 0x6E616D65)
        var nameTableOffset: Int?
        var nameTableLength: Int?
        for i in 0..<tableCount {
            let offset = 12 + i * 16
            let tag = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
            if tag == 0x6E616D65 { // 'name'
                nameTableOffset = Int(data[offset + 8]) << 24 | Int(data[offset + 9]) << 16 | Int(data[offset + 10]) << 8 | Int(data[offset + 11])
                nameTableLength = Int(data[offset + 12]) << 24 | Int(data[offset + 13]) << 16 | Int(data[offset + 14]) << 8 | Int(data[offset + 15])
                break
            }
        }

        guard let tableOffset = nameTableOffset, let length = nameTableLength,
              tableOffset + 6 <= data.count, length > 6 else {
            return fallbackFontMetadata(fallbackName, format: format)
        }

        let count = Int(data[tableOffset + 2]) << 8 | Int(data[tableOffset + 3])
        let stringOffset = tableOffset + (Int(data[tableOffset + 4]) << 8 | Int(data[tableOffset + 5]))
        guard stringOffset <= data.count else {
            return fallbackFontMetadata(fallbackName, format: format)
        }

        var familyName: String?
        var styleName: String?
        var postScriptName: String?

        // Read NameRecords
        for i in 0..<count {
            let recOffset = tableOffset + 6 + i * 12
            guard recOffset + 12 <= stringOffset else { break }

            let platformID = Int(data[recOffset]) << 8 | Int(data[recOffset + 1])
            let nameID = Int(data[recOffset + 6]) << 8 | Int(data[recOffset + 7])
            let recordLength = Int(data[recOffset + 8]) << 8 | Int(data[recOffset + 9])
            let recordOffset = stringOffset + (Int(data[recOffset + 10]) << 8 | Int(data[recOffset + 11]))

            guard recordOffset + recordLength <= data.count else { continue }
            let recordData = data.subdata(in: recordOffset..<(recordOffset + recordLength))

            var stringValue: String?
            if platformID == 0 || platformID == 3 {
                // Unicode / Windows: UTF-16BE
                stringValue = String(data: recordData, encoding: .utf16BigEndian)
            } else if platformID == 1 {
                // Macintosh Roman
                stringValue = String(data: recordData, encoding: .macOSRoman)
            }
            if stringValue == nil {
                stringValue = String(data: recordData, encoding: .utf8)
            }

            guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }

            switch nameID {
            case 1: // Font Family
                if familyName == nil || platformID == 3 { familyName = value }
            case 2: // Font Subfamily (Style)
                if styleName == nil || platformID == 3 { styleName = value }
            case 6: // PostScript Name
                if postScriptName == nil || platformID == 3 { postScriptName = value }
            default:
                break
            }
        }

        let cleanFamily = familyName ?? fallbackName
        let cleanStyle = styleName ?? "Regular"
        let cleanPS = postScriptName ?? "\(cleanFamily)-\(cleanStyle)"
        return FontMetadata(postScriptName: cleanPS, familyName: cleanFamily, style: cleanStyle, format: format)
    }

    private static func fallbackFontMetadata(_ fallbackName: String, format: String = "TTF") -> FontMetadata {
        let base = fallbackName
            .replacingOccurrences(of: ".ttf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".otf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".ttc", with: "", options: .caseInsensitive)
        let parts = base.split(separator: "-")
        let family = parts.first.map(String.init) ?? base
        let style = parts.count > 1 ? String(parts[1]) : "Regular"
        return FontMetadata(postScriptName: base, familyName: family, style: style, format: format)
    }

    // MARK: - Video & Audio Header Parsing

    /// Scans MP4/MOV atoms for duration and video track dimensions.
    public static func parseMP4Metadata(from data: Data) -> (duration: TimeInterval?, width: Int?, height: Int?) {
        guard data.count >= 16 else { return (nil, nil, nil) }
        var offset = 0
        var duration: TimeInterval?
        var width: Int?
        var height: Int?

        while offset + 8 <= data.count {
            let size = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]))
            let tag = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let boxSize = size == 1 ? 16 : size
            guard boxSize >= 8 else { break }

            if tag == "moov" {
                // Descend into moov container
                let subdata = data.subdata(in: (offset + 8)..<min(data.count, offset + boxSize))
                let result = parseMoovAtom(from: subdata)
                duration = result.duration
                width = result.width
                height = result.height
                break
            }
            offset += boxSize
        }
        return (duration, width, height)
    }

    private static func parseMoovAtom(from data: Data) -> (duration: TimeInterval?, width: Int?, height: Int?) {
        var offset = 0
        var duration: TimeInterval?
        var width: Int?
        var height: Int?

        while offset + 8 <= data.count {
            let size = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]))
            guard offset + 8 <= data.count else { break }
            let tag = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let boxSize = max(8, size)
            guard offset + boxSize <= data.count else { break }

            if tag == "mvhd" && duration == nil {
                // Parse Movie Header Atom (mvhd)
                let version = data[offset + 8]
                if version == 0 && offset + 28 <= data.count {
                    let timescale = UInt32(data[offset + 20]) << 24 | UInt32(data[offset + 21]) << 16 | UInt32(data[offset + 22]) << 8 | UInt32(data[offset + 23])
                    let dur = UInt32(data[offset + 24]) << 24 | UInt32(data[offset + 25]) << 16 | UInt32(data[offset + 26]) << 8 | UInt32(data[offset + 27])
                    if timescale > 0 {
                        duration = TimeInterval(dur) / TimeInterval(timescale)
                    }
                }
            } else if tag == "trak" && (width == nil || height == nil) {
                // Inspect Track Atom (trak)
                let sub = data.subdata(in: (offset + 8)..<(offset + boxSize))
                if let dims = parseTrakDimensions(from: sub) {
                    width = dims.width
                    height = dims.height
                }
            }
            offset += boxSize
        }
        return (duration, width, height)
    }

    private static func parseTrakDimensions(from data: Data) -> (width: Int, height: Int)? {
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]))
            guard offset + 8 <= data.count else { break }
            let tag = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let boxSize = max(8, size)
            guard offset + boxSize <= data.count else { break }

            if tag == "tkhd" {
                // Track Header Atom
                // Width & height are fixed point 16.16 at end of tkhd atom
                if boxSize >= 84 {
                    let w = Int(data[offset + boxSize - 8]) << 8 | Int(data[offset + boxSize - 7])
                    let h = Int(data[offset + boxSize - 4]) << 8 | Int(data[offset + boxSize - 3])
                    if w > 0 && h > 0 {
                        return (w, h)
                    }
                }
            }
            offset += boxSize
        }
        return nil
    }

    /// Parses WAV audio header for duration and channels.
    public static func parseWAVMetadata(from data: Data) -> (duration: TimeInterval?, sampleRate: Double?, channels: Int?) {
        guard data.count >= 44 else { return (nil, nil, nil) }
        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return (nil, nil, nil) } // 'RIFF'
        guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return (nil, nil, nil) } // 'WAVE'

        var offset = 12
        var byteRate: Int?
        var sampleRate: Double?
        var channels: Int?
        var dataSize: Int?

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8) | (Int(data[offset + 6]) << 16) | (Int(data[offset + 7]) << 24)
            guard chunkSize >= 0 else { break }

            if chunkID == "fmt " && offset + 24 <= data.count {
                channels = Int(data[offset + 10]) | (Int(data[offset + 11]) << 8)
                let sr = Int(data[offset + 12]) | (Int(data[offset + 13]) << 8) | (Int(data[offset + 14]) << 16) | (Int(data[offset + 15]) << 24)
                sampleRate = Double(sr)
                byteRate = Int(data[offset + 16]) | (Int(data[offset + 17]) << 8) | (Int(data[offset + 18]) << 16) | (Int(data[offset + 19]) << 24)
            } else if chunkID == "data" {
                dataSize = chunkSize
                break
            }
            offset += 8 + chunkSize
        }

        var duration: TimeInterval?
        if let dataSize, let byteRate, byteRate > 0 {
            duration = TimeInterval(dataSize) / TimeInterval(byteRate)
        }
        return (duration, sampleRate, channels)
    }

    // MARK: - Strings & Stringsdict Parsing

    /// Parses key-value pairs from an Apple `.strings` or `.stringsdict` file.
    public static func parseStringsFile(from data: Data) -> [LocalizationEntry] {
        // Try PropertyListSerialization first (binary / XML / OpenStep dictionary)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        if let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] {
            return dict.keys.sorted().compactMap { key in
                let val = dict[key]
                let valStr: String
                if let str = val as? String {
                    valStr = str
                } else if let subDict = val as? [String: Any], let format = subDict["NSStringLocalizedFormatKey"] as? String {
                    valStr = format
                } else if let desc = val {
                    valStr = String(describing: desc)
                } else {
                    valStr = ""
                }
                return LocalizationEntry(key: key, value: valStr)
            }
        }

        // Fallback: line-based parser for text `.strings`
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian) else {
            return []
        }

        var entries: [LocalizationEntry] = []
        var currentComment: String?
        let lines = text.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("/*") && line.hasSuffix("*/") {
                let stripped = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
                currentComment = stripped
                continue
            }
            if line.hasPrefix("//") {
                currentComment = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Look for "Key" = "Value";
            if let eqIndex = line.firstIndex(of: "=") {
                let left = line[..<eqIndex].trimmingCharacters(in: .whitespaces)
                let right = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

                var key = left
                if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 {
                    key = String(key.dropFirst().dropLast())
                }

                var value = right
                if value.hasSuffix(";") {
                    value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
                }
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }

                if !key.isEmpty {
                    entries.append(LocalizationEntry(key: String(key), value: String(value), comment: currentComment))
                    currentComment = nil
                }
            }
        }

        return entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}
