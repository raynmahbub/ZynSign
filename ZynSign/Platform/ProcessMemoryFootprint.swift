import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How much memory this process is holding, as the kernel reports it.
///
/// ZynSign asks for one number — the resident set — and only where a Lab
/// check or a diagnostic needs it. The figure is the process's own, never
/// another process's, and it carries nothing about what is in the memory:
/// no addresses, no contents, no identifiers.
///
/// Where the platform will not say, the answer is `nil` rather than zero.
/// A reported zero is a claim, and this boundary's whole job is to avoid
/// making one it cannot support.
enum ProcessMemoryFootprint {

    /// The resident set size in bytes, or `nil` when the platform does not
    /// report it.
    static func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.resident_size
        #else
        return nil
        #endif
    }

    /// The virtual size in bytes, or `nil` when the platform does not report
    /// it. Resident size is the number that matters for memory pressure;
    /// this is here for the rare diagnostic that needs the reservation.
    static func virtualBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return info.virtual_size
        #else
        return nil
        #endif
    }
}
