import Foundation

/// Pure-Swift Mach-O binary patcher for sideloading compatibility:
/// - Legacy `arm64e` capability-bits normalization (`0x80000002` user-space PTRAUTH ABI)
/// - iOS 26+ `LC_BUILD_VERSION` SDK version upgrade (`26.0` = `0x001A0000`) for Liquid Glass
/// - `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` install-name rewriting (e.g. CydiaSubstrate -> ElleKit `@rpath`)
/// - `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` removal (Disinject)
/// - Pre-strip embedded `CSSLOT_ENTITLEMENTS` XML extraction for `Merge Entitlements`
enum MachOBinaryPatcher {

    static let mhMagic64LE: UInt32 = 0xFEED_FACF
    static let fatMagicBE: UInt32 = 0xCAFE_BABE
    static let fatMagic64BE: UInt32 = 0xCAFE_BABF
    static let cpuTypeArm64: UInt32 = 0x0100_000C
    static let cpuSubtypeArm64e: UInt32 = 0x0000_0002
    static let modernArm64eSubtype: UInt32 = 0x8000_0002

    static let lcLoadDylib: UInt32 = 0x0000_000C
    static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    static let lcReexportDylib: UInt32 = 0x8000_001F
    static let lcCodeSignature: UInt32 = 0x0000_001D
    static let lcBuildVersion: UInt32 = 0x0000_0032
    static let lcSegment64: UInt32 = 0x0000_0019

    static let csMagicEmbeddedSignature: UInt32 = 0xFADE_0CC0
    static let csMagicEntitlements: UInt32 = 0xFADE_7171
    static let csSlotEntitlements: UInt32 = 5
    static let sdk26PackedVersion: UInt32 = 0x001A_0000

    struct SliceRange: Equatable, Sendable {
        let offset: Int
        let size: Int
        let fatArchSubtypeOffset: Int?
    }

    enum PatchError: Error, Equatable, Sendable {
        case truncatedBinary
        case insufficientHeaderPadding(required: Int, available: Int)
    }

    /// Normalizes legacy `arm64e` slices (`cpusubtype == 0x00000002` with zero
    /// capability bits) to modern user-space `0x80000002` in both thin and fat binaries.
    static func fixLegacyArm64eSlices(in data: Data) -> (data: Data, modified: Bool) {
        guard let slices = locateSlices(in: data) else { return (data, false) }
        var output = data
        var changed = false
        for slice in slices {
            guard slice.offset + 32 <= output.count else { continue }
            guard readUInt32LE(output, at: slice.offset) == mhMagic64LE else { continue }
            let cpuType = readUInt32LE(output, at: slice.offset + 4)
            let cpuSubtype = readUInt32LE(output, at: slice.offset + 8)
            guard cpuType == cpuTypeArm64,
                  (cpuSubtype & 0x00FF_FFFF) == cpuSubtypeArm64e,
                  (cpuSubtype & 0xFF00_0000) == 0 else { continue }
            writeUInt32LE(modernArm64eSubtype, into: &output, at: slice.offset + 8)
            if let fatSubtypeOffset = slice.fatArchSubtypeOffset, fatSubtypeOffset + 4 <= output.count {
                writeUInt32BE(modernArm64eSubtype, into: &output, at: fatSubtypeOffset)
            }
            changed = true
        }
        return (output, changed)
    }

    /// Updates `LC_BUILD_VERSION.sdk` to at least `sdkVersion` (`0x001A0000` for iOS 26.0)
    /// across all 64-bit Mach-O slices so iOS 26 enables Liquid Glass metrics.
    static func patchMinimumSDKVersion(
        in data: Data,
        sdkVersion: UInt32 = sdk26PackedVersion
    ) -> (data: Data, modified: Bool) {
        guard let slices = locateSlices(in: data) else { return (data, false) }
        var output = data
        var changed = false
        for slice in slices {
            guard let header = readHeader64(in: output, slice: slice) else { continue }
            var cursor = slice.offset + 32
            let end = cursor + header.sizeofcmds
            guard end <= slice.offset + slice.size, end <= output.count else { continue }
            for _ in 0..<header.ncmds {
                guard cursor + 8 <= end else { break }
                let cmd = readUInt32LE(output, at: cursor)
                let cmdsize = Int(readUInt32LE(output, at: cursor + 4))
                guard cmdsize >= 8, cursor + cmdsize <= end else { break }
                if cmd == lcBuildVersion, cmdsize >= 24 {
                    let currentSDK = readUInt32LE(output, at: cursor + 16)
                    if currentSDK < sdkVersion {
                        writeUInt32LE(sdkVersion, into: &output, at: cursor + 16)
                        changed = true
                    }
                }
                cursor += cmdsize
            }
        }
        return (output, changed)
    }

    /// Rewrites matching `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` install names in place
    /// (for example rewriting `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`
    /// to `@rpath/CydiaSubstrate.framework/CydiaSubstrate` for ElleKit).
    static func rewriteInstallNames(
        in data: Data,
        replacements: [String: String]
    ) throws -> (data: Data, rewrittenCount: Int) {
        guard !replacements.isEmpty, let slices = locateSlices(in: data) else { return (data, 0) }
        var output = data
        var totalRewritten = 0
        for slice in slices {
            let outcome = try rewriteSliceLoadCommands(in: &output, slice: slice) { cmd, rawBytes, installName in
                guard let name = installName, let replacement = replacements[name] else {
                    return .keep(rawBytes)
                }
                totalRewritten += 1
                return .replace(buildDylibCommand(cmd: cmd, template: rawBytes, installName: replacement))
            }
            _ = outcome
        }
        return (output, totalRewritten)
    }

    /// Removes `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` load commands whose install name
    /// matches `removedNames` (exact match or trailing filename match).
    static func removeLoadCommands(
        in data: Data,
        matchingInstallNames removedNames: Set<String>
    ) throws -> (data: Data, removedCount: Int) {
        guard !removedNames.isEmpty, let slices = locateSlices(in: data) else { return (data, 0) }
        var output = data
        var removedCount = 0
        for slice in slices {
            _ = try rewriteSliceLoadCommands(in: &output, slice: slice) { _, rawBytes, installName in
                guard let name = installName else { return .keep(rawBytes) }
                let tail = (name as NSString).lastPathComponent
                if removedNames.contains(name) || removedNames.contains(tail) {
                    removedCount += 1
                    return .remove
                }
                return .keep(rawBytes)
            }
        }
        return (output, removedCount)
    }

    /// Extracts the XML entitlements blob (`CSSLOT_ENTITLEMENTS`) from an existing
    /// signed Mach-O binary before signature stripping, if present.
    static func extractEmbeddedEntitlementsXML(from data: Data) -> Data? {
        guard let slices = locateSlices(in: data) else { return nil }
        for slice in slices {
            if let xml = extractSliceEntitlementsXML(from: data, slice: slice) {
                return xml
            }
        }
        return nil
    }

    /// Strips any embedded `LC_CODE_SIGNATURE` load command and trailing SuperBlob
    /// from a thin or universal Mach-O image, returning the unsigned image bytes.
    static func stripCodeSignature(from data: Data) -> Data? {
        try? MachOCodeSignatureStripper.stripSignature(from: data)
    }

    /// Lists all `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB` install names
    /// declared across slices of `data`.
    static func listLinkedDylibs(in data: Data) -> [String] {
        guard let slices = locateSlices(in: data) else { return [] }
        var seen: Set<String> = []
        var ordered: [String] = []
        for slice in slices {
            guard let header = readHeader64(in: data, slice: slice) else { continue }
            var cursor = slice.offset + 32
            let end = cursor + header.sizeofcmds
            guard end <= slice.offset + slice.size, end <= data.count else { continue }
            for _ in 0..<header.ncmds {
                guard cursor + 8 <= end else { break }
                let cmd = readUInt32LE(data, at: cursor)
                let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
                guard cmdsize >= 8, cursor + cmdsize <= end else { break }
                if let name = decodeDylibName(in: data, cmd: cmd, offset: cursor, cmdsize: cmdsize),
                   seen.insert(name).inserted {
                    ordered.append(name)
                }
                cursor += cmdsize
            }
        }
        return ordered
    }

    // MARK: - Internal Mach-O Helpers

    private struct Header64 {
        let ncmds: Int
        let sizeofcmds: Int
        let firstContentOffset: Int
    }

    private enum CommandMutation {
        case keep(Data)
        case replace(Data)
        case remove
    }

    static func locateSlices(in data: Data) -> [SliceRange]? {
        guard data.count >= 32 else { return nil }
        let magicLE = readUInt32LE(data, at: 0)
        if magicLE == mhMagic64LE {
            return [SliceRange(offset: 0, size: data.count, fatArchSubtypeOffset: nil)]
        }
        let magicBE = readUInt32BE(data, at: 0)
        if magicBE == fatMagicBE {
            let count = Int(readUInt32BE(data, at: 4))
            guard count > 0, count <= 16, 8 + count * 20 <= data.count else { return nil }
            var slices: [SliceRange] = []
            for idx in 0..<count {
                let entryOffset = 8 + idx * 20
                let sliceOffset = Int(readUInt32BE(data, at: entryOffset + 8))
                let sliceSize = Int(readUInt32BE(data, at: entryOffset + 12))
                guard sliceOffset >= 0, sliceSize >= 32, sliceOffset + sliceSize <= data.count else { continue }
                slices.append(SliceRange(offset: sliceOffset, size: sliceSize, fatArchSubtypeOffset: entryOffset + 4))
            }
            return slices.isEmpty ? nil : slices
        }
        if magicBE == fatMagic64BE {
            let count = Int(readUInt32BE(data, at: 4))
            guard count > 0, count <= 16, 8 + count * 32 <= data.count else { return nil }
            var slices: [SliceRange] = []
            for idx in 0..<count {
                let entryOffset = 8 + idx * 32
                let sliceOffset = Int(readUInt64BE(data, at: entryOffset + 8))
                let sliceSize = Int(readUInt64BE(data, at: entryOffset + 16))
                guard sliceOffset >= 0, sliceSize >= 32, sliceOffset + sliceSize <= data.count else { continue }
                slices.append(SliceRange(offset: sliceOffset, size: sliceSize, fatArchSubtypeOffset: entryOffset + 4))
            }
            return slices.isEmpty ? nil : slices
        }
        return nil
    }

    private static func readHeader64(in data: Data, slice: SliceRange) -> Header64? {
        guard slice.offset + 32 <= data.count,
              readUInt32LE(data, at: slice.offset) == mhMagic64LE else { return nil }
        let ncmds = Int(readUInt32LE(data, at: slice.offset + 16))
        let sizeofcmds = Int(readUInt32LE(data, at: slice.offset + 20))
        guard ncmds >= 0, ncmds <= 4_096, sizeofcmds >= 0, 32 + sizeofcmds <= slice.size else { return nil }
        let firstContent = findFirstContentOffset(in: data, slice: slice, ncmds: ncmds, sizeofcmds: sizeofcmds)
        return Header64(ncmds: ncmds, sizeofcmds: sizeofcmds, firstContentOffset: firstContent)
    }

    private static func findFirstContentOffset(in data: Data, slice: SliceRange, ncmds: Int, sizeofcmds: Int) -> Int {
        var earliest = slice.size
        var cursor = slice.offset + 32
        let end = cursor + sizeofcmds
        for _ in 0..<ncmds {
            guard cursor + 8 <= end else { break }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= end else { break }
            if cmd == lcSegment64, cmdsize >= 72 {
                let nsects = Int(readUInt32LE(data, at: cursor + 64))
                for sectIdx in 0..<nsects {
                    let sectOffset = cursor + 72 + sectIdx * 80
                    guard sectOffset + 80 <= cursor + cmdsize else { break }
                    let fileOff = Int(readUInt32LE(data, at: sectOffset + 48))
                    if fileOff > 0 { earliest = min(earliest, fileOff) }
                }
            }
            cursor += cmdsize
        }
        return max(32 + sizeofcmds, earliest)
    }

    private static func rewriteSliceLoadCommands(
        in data: inout Data,
        slice: SliceRange,
        transform: (UInt32, Data, String?) -> CommandMutation
    ) throws -> Bool {
        guard let header = readHeader64(in: data, slice: slice) else { return false }
        var rebuilt = Data()
        var newCount = 0
        var mutated = false
        var cursor = slice.offset + 32
        let end = cursor + header.sizeofcmds
        for _ in 0..<header.ncmds {
            guard cursor + 8 <= end else { throw PatchError.truncatedBinary }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= end else { throw PatchError.truncatedBinary }
            let raw = data.subdata(in: cursor..<(cursor + cmdsize))
            let name = decodeDylibName(in: data, cmd: cmd, offset: cursor, cmdsize: cmdsize)
            switch transform(cmd, raw, name) {
            case .keep(let kept):
                rebuilt.append(kept)
                newCount += 1
            case .replace(let replaced):
                rebuilt.append(replaced)
                newCount += 1
                mutated = true
            case .remove:
                mutated = true
            }
            cursor += cmdsize
        }
        guard mutated else { return false }
        let availableBytes = header.firstContentOffset - 32
        guard rebuilt.count <= availableBytes else {
            throw PatchError.insufficientHeaderPadding(required: rebuilt.count, available: availableBytes)
        }
        let regionLength = max(header.sizeofcmds, rebuilt.count)
        var padded = rebuilt
        if padded.count < regionLength {
            padded.append(Data(repeating: 0, count: regionLength - padded.count))
        }
        data.replaceSubrange((slice.offset + 32)..<(slice.offset + 32 + regionLength), with: padded)
        writeUInt32LE(UInt32(newCount), into: &data, at: slice.offset + 16)
        writeUInt32LE(UInt32(rebuilt.count), into: &data, at: slice.offset + 20)
        return true
    }

    private static func decodeDylibName(in data: Data, cmd: UInt32, offset: Int, cmdsize: Int) -> String? {
        guard cmd == lcLoadDylib || cmd == lcLoadWeakDylib || cmd == lcReexportDylib,
              cmdsize >= 24 else { return nil }
        let strOffset = Int(readUInt32LE(data, at: offset + 8))
        guard strOffset >= 24, strOffset < cmdsize else { return nil }
        let rawSlice = data.subdata(in: (offset + strOffset)..<(offset + cmdsize))
        let trimmed = rawSlice.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8)
    }

    private static func buildDylibCommand(cmd: UInt32, template: Data, installName: String) -> Data {
        let nameBytes = Array(installName.utf8) + [0]
        let padding = (8 - (24 + nameBytes.count) % 8) % 8
        let total = 24 + nameBytes.count + padding
        var result = Data(capacity: total)
        let timestamp = template.count >= 16 ? readUInt32LE(template, at: 12) : 2
        let currentVer = template.count >= 20 ? readUInt32LE(template, at: 16) : 0x0001_0000
        let compatVer = template.count >= 24 ? readUInt32LE(template, at: 20) : 0x0001_0000
        appendUInt32LE(cmd, to: &result)
        appendUInt32LE(UInt32(total), to: &result)
        appendUInt32LE(24, to: &result)
        appendUInt32LE(timestamp, to: &result)
        appendUInt32LE(currentVer, to: &result)
        appendUInt32LE(compatVer, to: &result)
        result.append(contentsOf: nameBytes)
        if padding > 0 { result.append(contentsOf: [UInt8](repeating: 0, count: padding)) }
        return result
    }

    private static func extractSliceEntitlementsXML(from data: Data, slice: SliceRange) -> Data? {
        guard let header = readHeader64(in: data, slice: slice) else { return nil }
        var cursor = slice.offset + 32
        let end = cursor + header.sizeofcmds
        for _ in 0..<header.ncmds {
            guard cursor + 8 <= end else { break }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= end else { break }
            if cmd == lcCodeSignature, cmdsize >= 16 {
                let dataOff = Int(readUInt32LE(data, at: cursor + 8))
                let dataSize = Int(readUInt32LE(data, at: cursor + 12))
                let sigStart = slice.offset + dataOff
                guard dataOff > 0, dataSize >= 12, sigStart + dataSize <= slice.offset + slice.size,
                      sigStart + dataSize <= data.count else { return nil }
                return parseSuperBlobEntitlements(in: data, start: sigStart, length: dataSize)
            }
            cursor += cmdsize
        }
        return nil
    }

    private static func parseSuperBlobEntitlements(in data: Data, start: Int, length: Int) -> Data? {
        guard readUInt32BE(data, at: start) == csMagicEmbeddedSignature else { return nil }
        let blobCount = Int(readUInt32BE(data, at: start + 8))
        guard blobCount > 0, blobCount <= 64, 12 + blobCount * 8 <= length else { return nil }
        for idx in 0..<blobCount {
            let indexPos = start + 12 + idx * 8
            let slotType = readUInt32BE(data, at: indexPos)
            let relOffset = Int(readUInt32BE(data, at: indexPos + 4))
            guard slotType == csSlotEntitlements, relOffset >= 12, relOffset + 8 <= length else { continue }
            let blobStart = start + relOffset
            guard readUInt32BE(data, at: blobStart) == csMagicEntitlements else { continue }
            let blobLen = Int(readUInt32BE(data, at: blobStart + 4))
            guard blobLen > 8, relOffset + blobLen <= length else { continue }
            return data.subdata(in: (blobStart + 8)..<(blobStart + blobLen))
        }
        return nil
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        (UInt64(readUInt32BE(data, at: offset)) << 32) | UInt64(readUInt32BE(data, at: offset + 4))
    }

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeUInt32BE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
