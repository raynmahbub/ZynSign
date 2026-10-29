import Foundation

/// Binary inspection, `MH_EXECUTE -> MH_DYLIB` container patching, multi-slot
/// sandbox metadata, Home-Screen WebClip generator, and dual-mode strategy
/// advisor for ZynSign's in-process guest container runtime.
enum GuestMachOPatcher {

    static let mhMagic64: UInt32 = 0xFEED_FACF
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatCigam: UInt32 = 0xBEBA_FECA
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let fatCigam64: UInt32 = 0xBFBA_FECA

    static let cpuTypeArm64: UInt32 = 0x0100_000C
    static let mhExecute: UInt32 = 0x2
    static let mhDylib: UInt32 = 0x6
    static let mhPieFlag: UInt32 = 0x0020_0000

    static let lcSegment64: UInt32 = 0x19
    static let lcSymtab: UInt32 = 0x02
    static let lcEncryptionInfo64: UInt32 = 0x2C
    static let lcBuildVersion: UInt32 = 0x32
    static let lcVersionMinIphoneOS: UInt32 = 0x25
    static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    static let lcIdDylib: UInt32 = 0x0D

    enum PatchError: Error, Equatable, Sendable, LocalizedError {
        case invalidMachO
        case missingArm64Slice
        case fairPlayEncrypted
        case notPositionIndependent
        case unsupportedFileType(UInt32)
        case insufficientHeaderPadding(needed: Int, available: Int)

        var errorDescription: String? {
            switch self {
            case .invalidMachO:
                return "The candidate executable is not a valid 64-bit Mach-O binary."
            case .missingArm64Slice:
                return "Universal binary does not contain an arm64 slice."
            case .fairPlayEncrypted:
                return "Binary is FairPlay-encrypted (cryptid != 0) and must be decrypted before container staging."
            case .notPositionIndependent:
                return "Executable is not position-independent (MH_PIE absent) and cannot be mapped with dlopen."
            case .unsupportedFileType(let raw):
                return "Unsupported Mach-O file type \(raw) for guest container patching."
            case .insufficientHeaderPadding(let needed, let available):
                return "Mach-O header needs \(needed) bytes of load-command padding, but only \(available) bytes remain."
            }
        }
    }

    struct GuestBinaryInspection: Equatable, Sendable {
        let isUniversal: Bool
        let hasArm64Slice: Bool
        let isFairPlayEncrypted: Bool
        let isPositionIndependent: Bool
        let headerFileType: UInt32
        let headerPaddingBytes: Int
        let minimumOSVersion: String?
        let hasPageZeroSegment: Bool
    }

    struct GuestBinaryPatchOutcome: Equatable, Sendable {
        let binary: Data
        let extractedFromUniversal: Bool
        let convertedExecuteToDylib: Bool
        let neutralizedPageZero: Bool
        let injectedInstallNames: [String]
    }

    /// Inspects raw Mach-O bytes (thin or universal) before staging into a guest container.
    static func inspectCandidateBinary(_ data: Data) -> GuestBinaryInspection? {
        guard data.count >= 32 else { return nil }
        let magic = readU32LE(data, 0)
        let isUniversal = (magic == fatMagic || magic == fatCigam || magic == fatMagic64 || magic == fatCigam64)
        let thinSlice: Data
        if isUniversal {
            guard let slice = try? extractArm64Slice(data) else {
                return GuestBinaryInspection(
                    isUniversal: true,
                    hasArm64Slice: false,
                    isFairPlayEncrypted: false,
                    isPositionIndependent: false,
                    headerFileType: 0,
                    headerPaddingBytes: 0,
                    minimumOSVersion: nil,
                    hasPageZeroSegment: false
                )
            }
            thinSlice = slice
        } else {
            guard magic == mhMagic64 else { return nil }
            thinSlice = data
        }
        return inspectThinArm64Slice(thinSlice, isUniversal: isUniversal)
    }

    /// Extracts the best `arm64` slice from a fat universal binary, or returns
    /// thin 64-bit `arm64` Mach-O data unchanged.
    static func extractArm64Slice(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw PatchError.invalidMachO }
        let magic = readU32BE(data, 0)
        if readU32LE(data, 0) == mhMagic64 {
            guard readU32LE(data, 4) == cpuTypeArm64 else {
                throw PatchError.missingArm64Slice
            }
            return data
        }
        if magic == fatMagic {
            return try extractFat32Arm64(data)
        }
        if magic == fatMagic64 {
            return try extractFat64Arm64(data)
        }
        throw PatchError.invalidMachO
    }

    /// Transforms an application main executable (`MH_EXECUTE`) or companion
    /// binary into an in-process `dlopen`-loadable `MH_DYLIB` image with
    /// `__PAGEZERO` neutralized and optional loader/tweak `LC_LOAD_WEAK_DYLIB` commands.
    static func patchExecutableForGuestRuntime(
        _ input: Data,
        installID: String,
        injectedInstallNames: [String] = []
    ) throws -> GuestBinaryPatchOutcome {
        let wasUniversal = isFatMagic(input)
        let slice = try extractArm64Slice(input)
        guard let inspection = inspectThinArm64Slice(slice, isUniversal: wasUniversal) else {
            throw PatchError.invalidMachO
        }
        if inspection.isFairPlayEncrypted {
            throw PatchError.fairPlayEncrypted
        }
        guard inspection.headerFileType == mhExecute || inspection.headerFileType == mhDylib else {
            throw PatchError.unsupportedFileType(inspection.headerFileType)
        }
        if inspection.headerFileType == mhExecute && !inspection.isPositionIndependent {
            throw PatchError.notPositionIndependent
        }

        // Strip any prior signature first so subsequent CS_ADHOC signing starts clean.
        var working = MachOBinaryPatcher.stripCodeSignature(from: slice) ?? slice
        var converted = false
        if readU32LE(working, 12) == mhExecute {
            writeU32LE(&working, 12, mhDylib)
            let flags = readU32LE(working, 24)
            writeU32LE(&working, 24, flags & ~mhPieFlag)
            converted = true
        }

        let pageZeroNeutralized = neutralizePageZeroSegment(&working)
        var addedCommands: [String] = []
        if converted && !hasCommand(working, cmd: lcIdDylib) {
            try appendDylibLoadCommand(&working, cmd: lcIdDylib, installName: installID)
        }
        for installName in injectedInstallNames where !installName.isEmpty {
            if !containsDylibInstallName(working, installName: installName) {
                try appendDylibLoadCommand(&working, cmd: lcLoadWeakDylib, installName: installName)
                addedCommands.append(installName)
            }
        }

        return GuestBinaryPatchOutcome(
            binary: working,
            extractedFromUniversal: wasUniversal,
            convertedExecuteToDylib: converted,
            neutralizedPageZero: pageZeroNeutralized,
            injectedInstallNames: addedCommands
        )
    }

    // MARK: - Internal Binary Helpers

    private static func isFatMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = readU32BE(data, 0)
        return magic == fatMagic || magic == fatMagic64
    }

    private static func extractFat32Arm64(_ data: Data) throws -> Data {
        let count = Int(readU32BE(data, 4))
        guard count > 0, count <= 16, data.count >= 8 + count * 20 else {
            throw PatchError.invalidMachO
        }
        var bestRange: Range<Int>?
        var bestSubtype: UInt32 = .max
        for idx in 0..<count {
            let base = 8 + idx * 20
            let cpuType = readU32BE(data, base)
            let cpuSubtype = readU32BE(data, base + 4) & 0x00FF_FFFF
            let offset = Int(readU32BE(data, base + 8))
            let size = Int(readU32BE(data, base + 12))
            guard cpuType == cpuTypeArm64, offset >= 0, size >= 32, offset + size <= data.count else {
                continue
            }
            if bestRange == nil || cpuSubtype < bestSubtype {
                bestSubtype = cpuSubtype
                bestRange = offset..<(offset + size)
            }
        }
        guard let range = bestRange else { throw PatchError.missingArm64Slice }
        return Data(data.subdata(in: range))
    }

    private static func extractFat64Arm64(_ data: Data) throws -> Data {
        let count = Int(readU32BE(data, 4))
        guard count > 0, count <= 16, data.count >= 8 + count * 32 else {
            throw PatchError.invalidMachO
        }
        var bestRange: Range<Int>?
        var bestSubtype: UInt32 = .max
        for idx in 0..<count {
            let base = 8 + idx * 32
            let cpuType = readU32BE(data, base)
            let cpuSubtype = readU32BE(data, base + 4) & 0x00FF_FFFF
            let offset = Int(readU64BE(data, base + 8))
            let size = Int(readU64BE(data, base + 16))
            guard cpuType == cpuTypeArm64, offset >= 0, size >= 32, offset + size <= data.count else {
                continue
            }
            if bestRange == nil || cpuSubtype < bestSubtype {
                bestSubtype = cpuSubtype
                bestRange = offset..<(offset + size)
            }
        }
        guard let range = bestRange else { throw PatchError.missingArm64Slice }
        return Data(data.subdata(in: range))
    }

    private static func inspectThinArm64Slice(_ data: Data, isUniversal: Bool) -> GuestBinaryInspection? {
        guard data.count >= 32,
              readU32LE(data, 0) == mhMagic64,
              readU32LE(data, 4) == cpuTypeArm64 else {
            return nil
        }
        let fileType = readU32LE(data, 12)
        let ncmds = Int(readU32LE(data, 16))
        let sizeofcmds = Int(readU32LE(data, 20))
        let flags = readU32LE(data, 24)
        guard ncmds >= 0, sizeofcmds >= 0, 32 + sizeofcmds <= data.count else { return nil }

        var encrypted = false
        var hasPageZero = false
        var minOS: String?
        var lowestSectionOffset = data.count
        var cursor = 32
        let end = 32 + sizeofcmds

        for _ in 0..<ncmds {
            guard cursor + 8 <= end else { break }
            let cmd = readU32LE(data, cursor)
            let cmdsize = Int(readU32LE(data, cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= end else { break }

            if cmd == lcEncryptionInfo64 && cmdsize >= 24 {
                if readU32LE(data, cursor + 16) != 0 { encrypted = true }
            } else if cmd == lcSegment64 && cmdsize >= 72 {
                let segName = readFixedCString(data, offset: cursor + 8, length: 16)
                if segName == "__PAGEZERO" { hasPageZero = true }
                lowestSectionOffset = min(lowestSectionOffset, earliestSectionOffset(in: data, segmentCursor: cursor, cmdsize: cmdsize))
            } else if cmd == lcBuildVersion && cmdsize >= 24 {
                minOS = decodePackedVersion(readU32LE(data, cursor + 12))
            } else if cmd == lcVersionMinIphoneOS && cmdsize >= 16 && minOS == nil {
                minOS = decodePackedVersion(readU32LE(data, cursor + 8))
            }
            cursor += cmdsize
        }

        let padding = max(0, lowestSectionOffset - (32 + sizeofcmds))
        return GuestBinaryInspection(
            isUniversal: isUniversal,
            hasArm64Slice: true,
            isFairPlayEncrypted: encrypted,
            isPositionIndependent: (flags & mhPieFlag) != 0 || fileType == mhDylib,
            headerFileType: fileType,
            headerPaddingBytes: padding,
            minimumOSVersion: minOS,
            hasPageZeroSegment: hasPageZero
        )
    }

    private static func earliestSectionOffset(in data: Data, segmentCursor: Int, cmdsize: Int) -> Int {
        let nsects = Int(readU32LE(data, segmentCursor + 64))
        guard nsects > 0, 72 + nsects * 80 <= cmdsize else { return data.count }
        var earliest = data.count
        for sectIdx in 0..<nsects {
            let sectOffset = Int(readU32LE(data, segmentCursor + 72 + sectIdx * 80 + 48))
            if sectOffset > 0 && sectOffset < earliest {
                earliest = sectOffset
            }
        }
        return earliest
    }

    private static func neutralizePageZeroSegment(_ data: inout Data) -> Bool {
        let ncmds = Int(readU32LE(data, 16))
        let sizeofcmds = Int(readU32LE(data, 20))
        guard 32 + sizeofcmds <= data.count else { return false }
        var cursor = 32
        var modified = false
        for _ in 0..<ncmds {
            guard cursor + 8 <= 32 + sizeofcmds else { break }
            let cmd = readU32LE(data, cursor)
            let cmdsize = Int(readU32LE(data, cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= 32 + sizeofcmds else { break }
            if cmd == lcSegment64 && cmdsize >= 72 {
                let segName = readFixedCString(data, offset: cursor + 8, length: 16)
                if segName == "__PAGEZERO" {
                    // Rename __PAGEZERO and collapse its unmapped low-memory reservation
                    // so dyld's dlopen maps the guest cleanly inside the host's address space.
                    writeFixedCString(&data, offset: cursor + 8, length: 16, value: "__ZYN_ZERO")
                    writeU64LE(&data, cursor + 24, 0xFFFF_C000)
                    writeU64LE(&data, cursor + 32, 0x0000_4000)
                    modified = true
                }
            }
            cursor += cmdsize
        }
        return modified
    }

    private static func hasCommand(_ data: Data, cmd target: UInt32) -> Bool {
        let ncmds = Int(readU32LE(data, 16))
        let sizeofcmds = Int(readU32LE(data, 20))
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= 32 + sizeofcmds else { break }
            let cmd = readU32LE(data, cursor)
            let cmdsize = Int(readU32LE(data, cursor + 4))
            guard cmdsize >= 8 else { break }
            if cmd == target { return true }
            cursor += cmdsize
        }
        return false
    }

    private static func containsDylibInstallName(_ data: Data, installName: String) -> Bool {
        let ncmds = Int(readU32LE(data, 16))
        let sizeofcmds = Int(readU32LE(data, 20))
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= 32 + sizeofcmds else { break }
            let cmd = readU32LE(data, cursor)
            let cmdsize = Int(readU32LE(data, cursor + 4))
            guard cmdsize >= 24, cursor + cmdsize <= 32 + sizeofcmds else {
                if cmdsize >= 8 { cursor += cmdsize; continue }
                break
            }
            if cmd == 0x0C || cmd == lcLoadWeakDylib || cmd == lcIdDylib {
                let nameOffset = Int(readU32LE(data, cursor + 8))
                if nameOffset >= 24, nameOffset < cmdsize {
                    let raw = readFixedCString(data, offset: cursor + nameOffset, length: cmdsize - nameOffset)
                    if raw == installName { return true }
                }
            }
            cursor += cmdsize
        }
        return false
    }

    private static func appendDylibLoadCommand(_ data: inout Data, cmd: UInt32, installName: String) throws {
        guard let inspection = inspectThinArm64Slice(data, isUniversal: false) else {
            throw PatchError.invalidMachO
        }
        let nameBytes = Array(installName.utf8) + [0]
        let unalignedSize = 24 + nameBytes.count
        let cmdsize = (unalignedSize + 7) & ~7
        guard inspection.headerPaddingBytes >= cmdsize else {
            throw PatchError.insufficientHeaderPadding(needed: cmdsize, available: inspection.headerPaddingBytes)
        }
        let ncmds = readU32LE(data, 16)
        let sizeofcmds = Int(readU32LE(data, 20))
        let insertOffset = 32 + sizeofcmds

        var payload = Data(count: cmdsize)
        writeU32LE(&payload, 0, cmd)
        writeU32LE(&payload, 4, UInt32(cmdsize))
        writeU32LE(&payload, 8, 24) // lc_str offset
        writeU32LE(&payload, 12, 2) // timestamp
        writeU32LE(&payload, 16, 0x0001_0000) // current_version 1.0.0
        writeU32LE(&payload, 20, 0x0001_0000) // compatibility_version 1.0.0
        for (idx, byte) in nameBytes.enumerated() {
            payload[24 + idx] = byte
        }

        data.replaceSubrange(insertOffset..<(insertOffset + cmdsize), with: payload)
        writeU32LE(&data, 16, ncmds + 1)
        writeU32LE(&data, 20, UInt32(sizeofcmds + cmdsize))
    }

    private static func decodePackedVersion(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFFFF
        let minor = (raw >> 8) & 0xFF
        let patch = raw & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    private static func readFixedCString(_ data: Data, offset: Int, length: Int) -> String {
        let end = min(data.count, offset + length)
        guard offset < end else { return "" }
        let slice = data[offset..<end]
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func writeFixedCString(_ data: inout Data, offset: Int, length: Int, value: String) {
        let utf8 = Array(value.utf8.prefix(length))
        for idx in 0..<length {
            data[offset + idx] = idx < utf8.count ? utf8[idx] : 0
        }
    }

    private static func readU32LE(_ d: Data, _ o: Int) -> UInt32 {
        let b0 = UInt32(d[d.startIndex + o])
        let b1 = UInt32(d[d.startIndex + o + 1]) << 8
        let b2 = UInt32(d[d.startIndex + o + 2]) << 16
        let b3 = UInt32(d[d.startIndex + o + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func readU32BE(_ d: Data, _ o: Int) -> UInt32 {
        let b0 = UInt32(d[d.startIndex + o]) << 24
        let b1 = UInt32(d[d.startIndex + o + 1]) << 16
        let b2 = UInt32(d[d.startIndex + o + 2]) << 8
        let b3 = UInt32(d[d.startIndex + o + 3])
        return b0 | b1 | b2 | b3
    }

    private static func readU64BE(_ d: Data, _ o: Int) -> UInt64 {
        (UInt64(readU32BE(d, o)) << 32) | UInt64(readU32BE(d, o + 4))
    }

    private static func writeU32LE(_ d: inout Data, _ o: Int, _ v: UInt32) {
        d[d.startIndex + o] = UInt8(v & 0xFF)
        d[d.startIndex + o + 1] = UInt8((v >> 8) & 0xFF)
        d[d.startIndex + o + 2] = UInt8((v >> 16) & 0xFF)
        d[d.startIndex + o + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func writeU64LE(_ d: inout Data, _ o: Int, _ v: UInt64) {
        writeU32LE(&d, o, UInt32(v & 0xFFFF_FFFF))
        writeU32LE(&d, o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
    }
}

/// Isolated data sandbox profile slot for a hosted guest application, enabling
/// multi-account switching without duplicating the app binary on disk.
struct GuestDataSlot: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var label: String
    let createdAt: Date

    static func primary(createdAt: Date = Date()) -> GuestDataSlot {
        GuestDataSlot(id: "primary", label: "Primary Profile", createdAt: createdAt)
    }

    func relativeDataPath(bundleIdentifier: String) -> String {
        if id == "primary" {
            return GuestContainer.Layout.dataPath(bundleIdentifier: bundleIdentifier)
        }
        return "\(GuestContainer.Layout.containerPath(bundleIdentifier: bundleIdentifier))/DataSlots/\(id)"
    }
}

/// Persistent descriptor for an app staged inside ZynSign's Host Container.
struct HostedGuestDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    var displayName: String
    var shortVersion: String
    var buildVersion: String
    let executableName: String
    var activeSlotID: String
    var slots: [GuestDataSlot]
    var stagedTweaks: [String]
    var injectedLibraries: [String]
    var requiresJIT: Bool
    var jitlessCompatible: Bool
    var sharedAppGroupIsolation: Bool
    let stagedAt: Date
    var lastLaunchedAt: Date?

    var activeSlot: GuestDataSlot {
        slots.first { $0.id == activeSlotID } ?? slots.first ?? .primary(createdAt: stagedAt)
    }

    func toContainerMetadata() -> GuestContainer.Metadata {
        GuestContainer.Metadata(
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            version: shortVersion,
            buildVersion: buildVersion,
            executable: executableName,
            dataIdentifier: activeSlotID,
            stagingMode: "adhoc",
            tweaks: stagedTweaks,
            injectedLibraries: injectedLibraries,
            requiresJIT: requiresJIT
        )
    }
}

/// Builds a Home-Screen WebClip `.mobileconfig` profile that launches a hosted
/// guest app (and optional data slot) directly via `zynsign://launch-guest`.
enum GuestWebClipProfileBuilder {

    static func buildMobileConfig(
        guest: HostedGuestDescriptor,
        slotID: String? = nil,
        iconPNGData: Data? = nil,
        profileUUID: UUID = UUID(),
        payloadUUID: UUID = UUID()
    ) throws -> Data {
        let chosenSlot = slotID ?? guest.activeSlotID
        var components = URLComponents()
        components.scheme = "zynsign"
        components.host = "launch-guest"
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: guest.bundleIdentifier),
            URLQueryItem(name: "slot", value: chosenSlot)
        ]
        let launchURL = components.string ?? "zynsign://launch-guest?bundleId=\(guest.bundleIdentifier)"
        let slotSuffix = chosenSlot == "primary" ? "" : " (\(chosenSlot))"
        let clipLabel = "\(guest.displayName)\(slotSuffix)"

        var webClipPayload: [String: Any] = [
            "FullScreen": true,
            "IgnoreManifestScope": true,
            "IsRemovable": true,
            "Label": clipLabel,
            "PayloadDescription": "Launches \(guest.displayName) inside ZynSign's Host Container.",
            "PayloadDisplayName": "\(clipLabel) Launcher",
            "PayloadIdentifier": "io.zynsign.webclip.\(guest.bundleIdentifier).\(chosenSlot)",
            "PayloadType": "com.apple.webClip.managed",
            "PayloadUUID": payloadUUID.uuidString,
            "PayloadVersion": 1,
            "Precomposed": true,
            "URL": launchURL
        ]
        if let iconPNGData, !iconPNGData.isEmpty {
            webClipPayload["Icon"] = iconPNGData
        }

        let root: [String: Any] = [
            "PayloadContent": [webClipPayload],
            "PayloadDescription": "Home Screen shortcut for \(guest.displayName) hosted by ZynSign.",
            "PayloadDisplayName": "\(clipLabel) — ZynSign Container",
            "PayloadIdentifier": "io.zynsign.container.launcher.\(profileUUID.uuidString)",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID.uuidString,
            "PayloadVersion": 1
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}

/// Advises whether a given package and user account state is best served by
/// Paid Direct Signing, Free Personal-Team Wire-Free Sideload, or Zero-Slot
/// Host Containerization.
enum ZynSigningStrategyAdvisor {

    enum ExecutionTrack: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
        case paidCertificate = "Paid Certificate"
        case freeAccountDirect = "Free Account (Direct)"
        case hostContainer = "Host Container (Zero-Slot)"
        case adHocExport = "Ad-Hoc Package"

        var badgeLabel: String {
            switch self {
            case .paidCertificate: return "365-Day Direct"
            case .freeAccountDirect: return "7-Day Wire-Free"
            case .hostContainer: return "Unlimited Apps · 0 Slots"
            case .adHocExport: return "CS_ADHOC"
            }
        }
    }

    struct Recommendation: Equatable, Sendable {
        let track: ExecutionTrack
        let headline: String
        let rationale: String
        let preservesThreeAppBudget: Bool
    }

    static func recommend(
        hasPaidCertificate: Bool,
        hasFreePersonalTeam: Bool,
        activeFreeAppCount: Int,
        hasAppExtensions: Bool,
        requiresPushOrBackground: Bool,
        prefersUnlimitedContainerApps: Bool
    ) -> Recommendation {
        if hasPaidCertificate && !prefersUnlimitedContainerApps {
            return Recommendation(
                track: .paidCertificate,
                headline: "Sign with Paid Certificate (1-Year Lease)",
                rationale: "A valid Developer or Enterprise identity is available, preserving full app extensions, background modes, and year-long device trust.",
                preservesThreeAppBudget: true
            )
        }
        if prefersUnlimitedContainerApps && !hasAppExtensions && !requiresPushOrBackground {
            return Recommendation(
                track: .hostContainer,
                headline: "Stage in Host Container (Zero Apple ID Slots)",
                rationale: "Converts the executable to MH_DYLIB and runs it inside ZynSign's sandbox with isolated multi-profile data slots — bypassing the 3-app Free Apple ID cap.",
                preservesThreeAppBudget: true
            )
        }
        if hasFreePersonalTeam {
            let maxFree = SideloadAccount.personalTeam.concurrentAppLimit ?? 3
            if activeFreeAppCount >= maxFree && !hasAppExtensions {
                return Recommendation(
                    track: .hostContainer,
                    headline: "Free 3-App Cap Reached — Stage in Host Container",
                    rationale: "Your personal team already has \(activeFreeAppCount)/\(maxFree) active standalone apps. Hosting inside ZynSign uses 0 additional device slots and needs no 7-day re-sign per guest.",
                    preservesThreeAppBudget: true
                )
            }
            return Recommendation(
                track: .freeAccountDirect,
                headline: "Sign with Free Apple ID & Refresh Over Loopback",
                rationale: "Uses \(min(activeFreeAppCount + 1, maxFree))/\(maxFree) personal-team app slots with 7-day wire-free refresh via ZynSign's local device bridge.",
                preservesThreeAppBudget: false
            )
        }
        return Recommendation(
            track: .hostContainer,
            headline: "Stage in Host Container (Ad-Hoc Runtime)",
            rationale: "No Apple certificate is required to stage decrypted apps into ZynSign's Host Container with CS_ADHOC signing.",
            preservesThreeAppBudget: true
        )
    }
}
