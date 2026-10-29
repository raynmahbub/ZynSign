import Foundation

/// Read-only Mach-O analyzer for imported tweak `.dylib` and `.framework` binaries.
///
/// Inspects architecture slices, `LC_LOAD_DYLIB` dependencies,
/// hooking-framework expectations (`CydiaSubstrate`,
/// `ElleKit`, `libhooker`), legacy `arm64e` ABI flags, and produces a concrete
/// recommended injection configuration.
enum TweakMachOAnalyzer {

    enum HookingRuntime: String, Codable, Equatable, Hashable, Sendable {
        case none = "None Detected"
        case cydiaSubstrate = "CydiaSubstrate"
        case elleKit = "ElleKit"
        case libhooker = "libhooker"
    }

    struct SliceSummary: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let architecture: String
        let hasLegacyArm64eSubtype: Bool
        let byteSize: Int
    }

    struct Recommendation: Equatable, Hashable, Sendable {
        let injectBase: TweakInjectBase
        let injectFolder: TweakInjectFolder
        let replaceSubstrateWithElleKit: Bool
        let fixLegacyArm64eSlice: Bool
        let rationale: String
    }

    struct AnalysisReport: Equatable, Sendable {
        let isValidMachO: Bool
        let slices: [SliceSummary]
        let linkedLibraries: [String]
        let hookingRuntime: HookingRuntime
        let requiresRpathSubstrateRewrite: Bool
        let hasLegacyArm64eSlice: Bool
        let recommendation: Recommendation
    }

    static func analyze(_ data: Data) -> AnalysisReport {
        guard let ranges = MachOBinaryPatcher.locateSlices(in: data), !ranges.isEmpty else {
            return AnalysisReport(
                isValidMachO: false,
                slices: [],
                linkedLibraries: [],
                hookingRuntime: .none,
                requiresRpathSubstrateRewrite: false,
                hasLegacyArm64eSlice: false,
                recommendation: Recommendation(
                    injectBase: .executablePath,
                    injectFolder: .frameworks,
                    replaceSubstrateWithElleKit: false,
                    fixLegacyArm64eSlice: false,
                    rationale: "Not a standalone Mach-O binary (archive or resource bundle)."
                )
            )
        }

        let (summaries, anyLegacyArm64e) = parseSlices(in: data, ranges: ranges)
        let linked = MachOBinaryPatcher.listLinkedDylibs(in: data)
        let usesAbsoluteSubstrate = linked.contains {
            $0.hasPrefix("/Library/Frameworks/CydiaSubstrate.framework/")
                || $0 == "/usr/lib/libsubstrate.dylib"
        }
        let runtime = classifyRuntime(linkedLibraries: linked)
        let usesRpath = linked.contains { $0.hasPrefix("@rpath/") } || usesAbsoluteSubstrate
        let base: TweakInjectBase = usesRpath ? .rpath : .executablePath
        var reasons: [String] = []
        if usesAbsoluteSubstrate {
            reasons.append("Links rootful CydiaSubstrate; enable ElleKit @rpath rewrite and bundle CydiaSubstrate.framework.")
        }
        if anyLegacyArm64e {
            reasons.append("Contains a legacy arm64e slice; enable Fix Legacy arm64e Slice for iOS 26+.")
        }
        if reasons.isEmpty {
            reasons.append("Standard \(base.rawValue)/Frameworks staging is compatible.")
        }

        return AnalysisReport(
            isValidMachO: true,
            slices: summaries,
            linkedLibraries: linked,
            hookingRuntime: runtime,
            requiresRpathSubstrateRewrite: usesAbsoluteSubstrate,
            hasLegacyArm64eSlice: anyLegacyArm64e,
            recommendation: Recommendation(
                injectBase: base,
                injectFolder: .frameworks,
                replaceSubstrateWithElleKit: usesAbsoluteSubstrate,
                fixLegacyArm64eSlice: anyLegacyArm64e,
                rationale: reasons.joined(separator: " ")
            )
        )
    }

    private static func parseSlices(
        in data: Data,
        ranges: [MachOBinaryPatcher.SliceRange]
    ) -> ([SliceSummary], Bool) {
        var summaries: [SliceSummary] = []
        var anyLegacyArm64e = false
        for (idx, slice) in ranges.enumerated() where slice.offset + 12 <= data.count {
            let cpuType = readUInt32LE(data, at: slice.offset + 4)
            let cpuSubtype = readUInt32LE(data, at: slice.offset + 8)
            let archName: String
            var isLegacyArm64e = false
            if cpuType == MachOBinaryPatcher.cpuTypeArm64 {
                if (cpuSubtype & 0x00FF_FFFF) == MachOBinaryPatcher.cpuSubtypeArm64e {
                    isLegacyArm64e = (cpuSubtype & 0xFF00_0000) == 0
                    archName = isLegacyArm64e ? "arm64e (legacy ABI)" : "arm64e"
                } else {
                    archName = "arm64"
                }
            } else {
                archName = String(format: "cpu-0x%08x", cpuType)
            }
            if isLegacyArm64e { anyLegacyArm64e = true }
            summaries.append(SliceSummary(
                id: "\(idx)-\(archName)",
                architecture: archName,
                hasLegacyArm64eSubtype: isLegacyArm64e,
                byteSize: slice.size
            ))
        }
        return (summaries, anyLegacyArm64e)
    }

    private static func classifyRuntime(linkedLibraries: [String]) -> HookingRuntime {
        let lowerLinked = linkedLibraries.map { $0.lowercased() }
        if lowerLinked.contains(where: { $0.contains("ellekit") }) {
            return .elleKit
        }
        if lowerLinked.contains(where: { $0.contains("cydiasubstrate") || $0.contains("libsubstrate") }) {
            return .cydiaSubstrate
        }
        if lowerLinked.contains(where: { $0.contains("libhooker") }) {
            return .libhooker
        }
        return .none
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
