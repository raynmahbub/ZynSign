import Foundation

/// Pure-Swift Debian `.deb` (`!<arch>\n` + `control.tar.*` + `data.tar.*`)
/// reader for extracting rootful/rootless iOS tweak `.dylib`, `.framework`,
/// and `.bundle` payloads safely inside ZynSign's bounded tweak sandbox.
enum DebArchiveParser {

    static let arMagic = Data("!<arch>\n".utf8)
    static let maximumDecompressedBytes = 128 * 1_024 * 1_024
    static let maximumArchiveBytes = 128 * 1_024 * 1_024

    enum CompressionKind {
        case deflate
        case lzma
    }

    /// Platform decoders must enforce the output limit while decoding, not
    /// after allocating the entire expanded member.
    typealias BoundedDecoder = (Data, CompressionKind, Int) throws -> Data

    struct ControlMetadata: Codable, Equatable, Hashable, Sendable {
        var packageIdentifier: String?
        var name: String?
        var version: String?
        var author: String?
        var maintainer: String?
        var architecture: String?
        var depends: String?
        var summary: String?
    }

    struct ExtractedPayload: Equatable, Hashable, Sendable {
        enum PayloadKind: String, Codable, Equatable, Hashable, Sendable {
            case dylib
            case framework
            case bundle
        }

        let kind: PayloadKind
        /// For `.dylib`: `Tweak.dylib`. For `.framework`: `Foo.framework/Info.plist`, etc.
        let relativePath: String
        let topLevelName: String
        let bytes: Data
        let isExecutable: Bool
    }

    struct UnpackedDeb: Equatable, Sendable {
        let control: ControlMetadata
        let payloads: [ExtractedPayload]
    }

    enum DebError: Error, Equatable, Sendable {
        case notADebArchive
        case truncatedMember
        case malformedArchive
        case duplicatePayload
        case missingDataTar
        case unsupportedCompression(String)
        case decompressionFailed(String)
        case archiveTooLarge(limit: Int)
        case noExtractablePayloads

        var message: String {
            switch self {
            case .notADebArchive:
                return "The file is not a valid Debian (.deb) archive."
            case .truncatedMember:
                return "The .deb archive has a truncated member header or body."
            case .malformedArchive:
                return "The .deb archive contains malformed or unsafe archive entries."
            case .duplicatePayload:
                return "The .deb archive contains conflicting payload paths."
            case .missingDataTar:
                return "The .deb archive contains no data.tar member."
            case .unsupportedCompression(let name):
                return "Unsupported .deb member compression (\(name)). Use uncompressed, gzip, zlib, or xz/lzma."
            case .decompressionFailed(let name):
                return "Could not decompress \(name) inside the .deb archive."
            case .archiveTooLarge(let limit):
                return "The unpacked .deb exceeds the \(limit / (1024 * 1024)) MiB safety bound."
            case .noExtractablePayloads:
                return "The .deb archive contains no .dylib, .framework, or .bundle tweak payloads."
            }
        }
    }

    /// Parses a `.deb` archive's control metadata and extracts all embedded
    /// `.dylib`, `.framework`, and `.bundle` entries from `data.tar.*`.
    static func unpack(_ data: Data, decoder: BoundedDecoder? = nil) throws -> UnpackedDeb {
        guard data.count <= maximumArchiveBytes else { throw DebError.archiveTooLarge(limit: maximumArchiveBytes) }
        let members = try parseArMembers(data)
        let controlMembers = members.filter { $0.name == "control.tar" || $0.name.hasPrefix("control.tar.") }
        let dataMembers = members.filter { $0.name == "data.tar" || $0.name.hasPrefix("data.tar.") }
        guard controlMembers.count <= 1, dataMembers.count <= 1 else { throw DebError.malformedArchive }
        var control = ControlMetadata()
        if let controlMember = controlMembers.first {
            let tarBytes = try decompressTarMember(controlMember.name, payload: controlMember.bytes, decoder: decoder)
            guard tarBytes.count <= maximumDecompressedBytes else {
                throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
            }
            let entries = try parseTarEntries(tarBytes)
            if let controlEntry = entries.first(where: {
                ($0.path as NSString).lastPathComponent == "control"
            }), let text = String(data: controlEntry.bytes, encoding: .utf8) {
                control = parseControlFile(text)
            }
        }

        guard let dataMember = dataMembers.first else {
            throw DebError.missingDataTar
        }
        let dataTar = try decompressTarMember(dataMember.name, payload: dataMember.bytes, decoder: decoder)
        guard dataTar.count <= maximumDecompressedBytes else {
            throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
        }
        let entries = try parseTarEntries(dataTar)
        let payloads = classifyTweakPayloads(from: entries)
        var paths = Set<String>()
        for payload in payloads {
            guard let path = ArchivePath(rawValue: payload.relativePath) else { throw DebError.malformedArchive }
            let folded = path.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(folded).inserted else { throw DebError.duplicatePayload }
        }
        // A regular file cannot also be an ancestor directory of another payload.
        for path in paths {
            var components = path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                guard !paths.contains(components.joined(separator: "/")) else { throw DebError.duplicatePayload }
            }
        }
        guard !payloads.isEmpty else {
            throw DebError.noExtractablePayloads
        }
        return UnpackedDeb(control: control, payloads: payloads)
    }

    // MARK: - Unix `ar` Parser

    private struct ArMember {
        let name: String
        let bytes: Data
    }

    private static func parseArMembers(_ data: Data) throws -> [ArMember] {
        guard data.count >= 8, data.prefix(8) == arMagic else {
            throw DebError.notADebArchive
        }
        var members: [ArMember] = []
        var offset = 8
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            let magic = header.subdata(in: 58..<60)
            guard magic == Data([0x60, 0x0A]) else {
                throw DebError.truncatedMember
            }
            let rawName = String(data: header.subdata(in: 0..<16), encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let rawSize = String(data: header.subdata(in: 48..<58), encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let bodySize = Int(rawSize), bodySize >= 0 else {
                throw DebError.truncatedMember
            }
            let bodyStart = offset + 60
            guard bodySize <= data.count - bodyStart else {
                throw DebError.truncatedMember
            }
            var cleanName = rawName
            if cleanName.hasSuffix("/") {
                cleanName.removeLast()
            }
            var body = data.subdata(in: bodyStart..<(bodyStart + bodySize))
            // BSD `#1/<len>` extended filename convention used by some `ar` writers.
            if cleanName.hasPrefix("#1/") {
                guard let nameLen = Int(cleanName.dropFirst(3)), nameLen > 0, nameLen <= body.count else {
                    throw DebError.truncatedMember
                }
                let extNameData = body.prefix(nameLen).prefix { $0 != 0 }
                guard let name = String(data: extNameData, encoding: .utf8), !name.isEmpty else {
                    throw DebError.malformedArchive
                }
                cleanName = name
                body = body.dropFirst(nameLen)
            }
            members.append(ArMember(name: cleanName, bytes: Data(body)))
            let bodyEnd = bodyStart + bodySize
            guard bodySize % 2 == 0 || bodyEnd < data.count else { throw DebError.truncatedMember }
            offset = bodyEnd + (bodySize % 2)
        }
        guard offset == data.count else { throw DebError.truncatedMember }
        return members
    }

    // MARK: - Compression

    private static func decompressTarMember(
        _ name: String, payload: Data, decoder: BoundedDecoder?
    ) throws -> Data {
        if name == "data.tar" || name == "control.tar" {
            return payload
        }
        let input: Data
        let kind: CompressionKind
        if name.hasSuffix(".gz") {
            input = try stripGzipEnvelope(payload, memberName: name)
            kind = .deflate
        } else if name.hasSuffix(".xz") || name.hasSuffix(".lzma") {
            input = payload
            kind = .lzma
        } else if name.hasSuffix(".zlib") {
            input = payload.count > 6 && payload[0] == 0x78
                ? payload.subdata(in: 2..<(payload.count - 4))
                : payload
            kind = .deflate
        } else {
            throw DebError.unsupportedCompression(name)
        }
        guard let decoder else { throw DebError.unsupportedCompression(name) }
        do {
            let out = try decoder(input, kind, maximumDecompressedBytes)
            guard out.count <= maximumDecompressedBytes else {
                throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
            }
            if name.hasSuffix(".gz") {
                let trailer = payload.count - 8
                let expectedCRC = readLittleEndianUInt32(payload, at: trailer)
                let expectedSize = readLittleEndianUInt32(payload, at: trailer + 4)
                guard crc32(out) == expectedCRC, UInt32(truncatingIfNeeded: out.count) == expectedSize else {
                    throw DebError.decompressionFailed(name)
                }
            }
            return out
        } catch let error as DebError {
            throw error
        } catch {
            throw DebError.decompressionFailed(name)
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum = UInt32.max
        for byte in data {
            checksum = (checksum >> 8) ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xFF)]
        }
        return checksum ^ UInt32.max
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    /// Strips the RFC 1952 envelope for the bounded raw DEFLATE decoder.
    private static func stripGzipEnvelope(_ data: Data, memberName: String) throws -> Data {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
            throw DebError.decompressionFailed(memberName)
        }
        let flags = data[3]
        guard flags & 0xE0 == 0 else { throw DebError.decompressionFailed(memberName) }
        var cursor = 10
        if (flags & 0x04) != 0 {
            guard cursor + 2 <= data.count else { throw DebError.decompressionFailed(memberName) }
            let xlen = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2 + xlen
        }
        if (flags & 0x08) != 0 {
            while cursor < data.count && data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if (flags & 0x10) != 0 {
            while cursor < data.count && data[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if (flags & 0x02) != 0 {
            guard cursor <= data.count - 10 else { throw DebError.decompressionFailed(memberName) }
            let expected = UInt16(data[cursor]) | (UInt16(data[cursor + 1]) << 8)
            guard UInt16(truncatingIfNeeded: crc32(data.subdata(in: 0..<cursor))) == expected else {
                throw DebError.decompressionFailed(memberName)
            }
            cursor += 2
        }
        let end = data.count - 8
        guard cursor <= end else { throw DebError.decompressionFailed(memberName) }
        return data.subdata(in: cursor..<end)
    }

    // MARK: - POSIX `ustar` / PAX Tar Reader

    private struct TarEntry {
        let path: String
        let mode: Int
        let bytes: Data
    }

    private static func parseTarEntries(_ tar: Data) throws -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = 0
        var paxPathOverride: String?
        var reachedTerminator = false
        while offset <= tar.count, tar.count - offset >= 512 {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                guard tar[offset...].allSatisfy({ $0 == 0 }), paxPathOverride == nil else {
                    throw DebError.malformedArchive
                }
                reachedTerminator = true
                break
            }
            let checksumText = readNullTerminatedASCII(header.subdata(in: 148..<156))
                .trimmingCharacters(in: .whitespaces)
            guard let storedChecksum = Int(checksumText, radix: 8) else { throw DebError.malformedArchive }
            let actualChecksum = header.enumerated().reduce(0) { sum, item in
                sum + ((148..<156).contains(item.offset) ? 32 : Int(item.element))
            }
            guard storedChecksum == actualChecksum else { throw DebError.malformedArchive }
            let namePart = readNullTerminatedASCII(header.subdata(in: 0..<100))
            let prefixPart = readNullTerminatedASCII(header.subdata(in: 345..<500))
            let modeOctal = readNullTerminatedASCII(header.subdata(in: 100..<108))
                .trimmingCharacters(in: .whitespaces)
            let sizeOctal = readNullTerminatedASCII(header.subdata(in: 124..<136))
                .trimmingCharacters(in: .whitespaces)
            let typeFlag = header[156]
            guard let size = Int(sizeOctal, radix: 8), size >= 0 else { throw DebError.malformedArchive }
            let mode = Int(modeOctal, radix: 8) ?? 0o644
            let contentStart = offset + 512
            guard size <= tar.count - contentStart else { throw DebError.malformedArchive }
            let content = tar.subdata(in: contentStart..<(contentStart + size))
            let padding = (512 - size % 512) % 512
            guard padding <= tar.count - contentStart - size else { throw DebError.malformedArchive }
            offset = contentStart + size + padding

            if typeFlag == UInt8(ascii: "g") || typeFlag == UInt8(ascii: "S") {
                throw DebError.malformedArchive // Global PAX and GNU sparse semantics are not implemented.
            }
            if typeFlag == UInt8(ascii: "x") {
                if let path = try parsePaxPath(content) {
                    guard paxPathOverride == nil else { throw DebError.malformedArchive }
                    paxPathOverride = path
                }
                continue
            }
            if typeFlag == UInt8(ascii: "L") {
                guard paxPathOverride == nil,
                      let path = String(data: content.prefix { $0 != 0 }, encoding: .utf8), !path.isEmpty else {
                    throw DebError.malformedArchive
                }
                paxPathOverride = path
                continue
            }

            let rawPath = paxPathOverride ?? (prefixPart.isEmpty ? namePart : "\(prefixPart)/\(namePart)")
            paxPathOverride = nil
            // Regular file (`0` or NUL). Symlinks and device nodes are never extracted.
            guard typeFlag == 0 || typeFlag == UInt8(ascii: "0") else { continue }
            guard let cleanPath = sanitizeRelativePath(rawPath) else { throw DebError.malformedArchive }
            entries.append(TarEntry(path: cleanPath, mode: mode, bytes: content))
        }
        guard reachedTerminator else { throw DebError.malformedArchive }
        return entries
    }

    private static func parsePaxPath(_ data: Data) throws -> String? {
        var offset = 0
        var path: String?
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 0x20), space > offset,
                  let lengthText = String(data: data.subdata(in: offset..<space), encoding: .ascii),
                  let length = Int(lengthText), length > space - offset + 1,
                  length <= data.count - offset else { throw DebError.malformedArchive }
            let end = offset + length
            guard data[end - 1] == 0x0A,
                  let record = String(data: data.subdata(in: (space + 1)..<(end - 1)), encoding: .utf8),
                  let equals = record.firstIndex(of: "=") else { throw DebError.malformedArchive }
            let key = String(record[..<equals])
            let value = String(record[record.index(after: equals)...])
            // These keys alter the interpretation of the following file's data.
            // Refuse them rather than extracting with unimplemented semantics.
            guard key != "size", !key.hasPrefix("GNU.sparse"), key != "SCHILY.realsize" else {
                throw DebError.malformedArchive
            }
            if key == "path" {
                guard path == nil, !value.isEmpty else { throw DebError.malformedArchive }
                path = value
            }
            offset = end
        }
        return path
    }

    private static func readNullTerminatedASCII(_ slice: Data) -> String {
        String(data: slice.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private static func sanitizeRelativePath(_ raw: String) -> String? {
        // A leading ./ is conventional in tar archives; other ambiguous or
        // absolute spellings must not silently become a different path.
        var candidate = raw
        while candidate.hasPrefix("./") { candidate.removeFirst(2) }
        return ArchivePath(rawValue: candidate)?.rawValue
    }

    // MARK: - Payload Classification & Debian `control`

    private static func classifyTweakPayloads(from entries: [TarEntry]) -> [ExtractedPayload] {
        var payloads: [ExtractedPayload] = []
        for entry in entries where !entry.bytes.isEmpty {
            let parts = entry.path.split(separator: "/").map(String.init)
            if let fwIndex = parts.firstIndex(where: { $0.lowercased().hasSuffix(".framework") }) {
                let fwName = parts[fwIndex]
                let subPath = parts[fwIndex...].joined(separator: "/")
                payloads.append(ExtractedPayload(
                    kind: .framework,
                    relativePath: subPath,
                    topLevelName: fwName,
                    bytes: entry.bytes,
                    isExecutable: (entry.mode & 0o111) != 0
                ))
            } else if let bundleIndex = parts.firstIndex(where: {
                let lower = $0.lowercased()
                return lower.hasSuffix(".bundle") && !lower.hasSuffix("preferencebundle.bundle")
            }) {
                let bundleName = parts[bundleIndex]
                let subPath = parts[bundleIndex...].joined(separator: "/")
                payloads.append(ExtractedPayload(
                    kind: .bundle,
                    relativePath: subPath,
                    topLevelName: bundleName,
                    bytes: entry.bytes,
                    isExecutable: (entry.mode & 0o111) != 0
                ))
            } else if let fileName = parts.last, fileName.lowercased().hasSuffix(".dylib") {
                payloads.append(ExtractedPayload(
                    kind: .dylib,
                    relativePath: fileName,
                    topLevelName: fileName,
                    bytes: entry.bytes,
                    isExecutable: true
                ))
            }
        }
        return payloads
    }

    static func parseControlFile(_ text: String) -> ControlMetadata {
        var meta = ControlMetadata()
        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.hasPrefix(" "), !rawLine.hasPrefix("\t"),
                  let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { continue }
            switch key {
            case "package": meta.packageIdentifier = val
            case "name": meta.name = val
            case "version": meta.version = val
            case "author": meta.author = val
            case "maintainer": meta.maintainer = val
            case "architecture": meta.architecture = val
            case "depends": meta.depends = val
            case "description": meta.summary = val
            default: break
            }
        }
        return meta
    }
}
