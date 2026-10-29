import Foundation

/// Pure-Swift Debian `.deb` (`!<arch>\n` + `control.tar.*` + `data.tar.*`)
/// reader for extracting rootful/rootless iOS tweak `.dylib`, `.framework`,
/// and `.bundle` payloads safely inside ZynSign's bounded tweak sandbox.
enum DebArchiveParser {

    static let arMagic = Data("!<arch>\n".utf8)
    static let maximumDecompressedBytes = 128 * 1_024 * 1_024

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
    static func unpack(_ data: Data) throws -> UnpackedDeb {
        let members = try parseArMembers(data)
        var control = ControlMetadata()
        if let controlMember = members.first(where: { $0.name.hasPrefix("control.tar") }) {
            if let tarBytes = try? decompressTarMember(controlMember.name, payload: controlMember.bytes) {
                let entries = parseTarEntries(tarBytes)
                if let controlEntry = entries.first(where: {
                    ($0.path as NSString).lastPathComponent == "control"
                }), let text = String(data: controlEntry.bytes, encoding: .utf8) {
                    control = parseControlFile(text)
                }
            }
        }

        guard let dataMember = members.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw DebError.missingDataTar
        }
        let dataTar = try decompressTarMember(dataMember.name, payload: dataMember.bytes)
        guard dataTar.count <= maximumDecompressedBytes else {
            throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
        }
        let entries = parseTarEntries(dataTar)
        let payloads = classifyTweakPayloads(from: entries)
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
            guard bodyStart + bodySize <= data.count else {
                throw DebError.truncatedMember
            }
            var cleanName = rawName
            if cleanName.hasSuffix("/") {
                cleanName.removeLast()
            }
            var body = data.subdata(in: bodyStart..<(bodyStart + bodySize))
            // BSD `#1/<len>` extended filename convention used by some `ar` writers.
            if cleanName.hasPrefix("#1/"),
               let nameLen = Int(cleanName.dropFirst(3)),
               nameLen > 0, nameLen <= body.count {
                let extNameData = body.prefix(nameLen).prefix { $0 != 0 }
                cleanName = String(data: extNameData, encoding: .utf8) ?? cleanName
                body = body.dropFirst(nameLen)
            }
            members.append(ArMember(name: cleanName, bytes: Data(body)))
            offset = bodyStart + bodySize + (bodySize % 2)
        }
        return members
    }

    // MARK: - Compression

    private static func decompressTarMember(_ name: String, payload: Data) throws -> Data {
        if name == "data.tar" || name == "control.tar" {
            return payload
        }
        if name.hasSuffix(".gz") {
            let rawDeflate = try stripGzipEnvelope(payload, memberName: name)
            do {
                let out = try (rawDeflate as NSData).decompressed(using: .zlib) as Data
                guard out.count <= maximumDecompressedBytes else {
                    throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
                }
                return out
            } catch let debErr as DebError {
                throw debErr
            } catch {
                throw DebError.decompressionFailed(name)
            }
        }
        if name.hasSuffix(".xz") || name.hasSuffix(".lzma") {
            do {
                let out = try (payload as NSData).decompressed(using: .lzma) as Data
                guard out.count <= maximumDecompressedBytes else {
                    throw DebError.archiveTooLarge(limit: maximumDecompressedBytes)
                }
                return out
            } catch let debErr as DebError {
                throw debErr
            } catch {
                throw DebError.decompressionFailed(name)
            }
        }
        if name.hasSuffix(".zlib") {
            let stripped = payload.count > 6 && payload[0] == 0x78
                ? payload.subdata(in: 2..<(payload.count - 4))
                : payload
            guard let out = try? (stripped as NSData).decompressed(using: .zlib) as Data else {
                throw DebError.decompressionFailed(name)
            }
            return out
        }
        throw DebError.unsupportedCompression(name)
    }

    /// Strips RFC 1952 gzip header and 8-byte trailer so `NSData.decompressed(using: .zlib)`
    /// receives the raw RFC 1951 DEFLATE stream.
    private static func stripGzipEnvelope(_ data: Data, memberName: String) throws -> Data {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
            throw DebError.decompressionFailed(memberName)
        }
        let flags = data[3]
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

    private static func parseTarEntries(_ tar: Data) -> [TarEntry] {
        var entries: [TarEntry] = []
        var offset = 0
        var paxPathOverride: String?
        while offset + 512 <= tar.count {
            let header = tar.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) { break }
            let namePart = readNullTerminatedASCII(header.subdata(in: 0..<100))
            let prefixPart = readNullTerminatedASCII(header.subdata(in: 345..<500))
            let modeOctal = readNullTerminatedASCII(header.subdata(in: 100..<108))
                .trimmingCharacters(in: .whitespaces)
            let sizeOctal = readNullTerminatedASCII(header.subdata(in: 124..<136))
                .trimmingCharacters(in: .whitespaces)
            let typeFlag = header[156]
            let size = Int(sizeOctal, radix: 8) ?? 0
            let mode = Int(modeOctal, radix: 8) ?? 0o644
            let contentStart = offset + 512
            guard size >= 0, contentStart + size <= tar.count else { break }
            let content = tar.subdata(in: contentStart..<(contentStart + size))
            let blocks = (size + 511) / 512
            offset = contentStart + blocks * 512

            if typeFlag == UInt8(ascii: "x"), let pax = String(data: content, encoding: .utf8) {
                paxPathOverride = parsePaxPath(pax)
                continue
            }
            if typeFlag == UInt8(ascii: "L"), let gnuLong = String(data: content.prefix { $0 != 0 }, encoding: .utf8) {
                paxPathOverride = gnuLong
                continue
            }

            let rawPath = paxPathOverride ?? (prefixPart.isEmpty ? namePart : "\(prefixPart)/\(namePart)")
            paxPathOverride = nil
            // Regular file (`0` or NUL). Symlinks and device nodes are never extracted.
            guard typeFlag == 0 || typeFlag == UInt8(ascii: "0") else { continue }
            guard let cleanPath = sanitizeRelativePath(rawPath) else { continue }
            entries.append(TarEntry(path: cleanPath, mode: mode, bytes: content))
        }
        return entries
    }

    private static func parsePaxPath(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            if let space = line.firstIndex(of: " ") {
                let kv = line[line.index(after: space)...]
                if kv.hasPrefix("path=") {
                    return String(kv.dropFirst(5))
                }
            }
        }
        return nil
    }

    private static func readNullTerminatedASCII(_ slice: Data) -> String {
        String(data: slice.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private static func sanitizeRelativePath(_ raw: String) -> String? {
        let components = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
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
