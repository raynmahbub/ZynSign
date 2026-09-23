import Foundation

/// Deterministic hashes for the ordinary CodeDirectory slots, in page order.
struct CodePageHasher {
    private let messageDigest: any MessageDigest

    init(messageDigest: any MessageDigest) {
        self.messageDigest = messageDigest
    }

    /// Hashes bytes in the half-open range `0..<codeLimit`.
    ///
    /// Bytes after `codeLimit` are deliberately ignored. A limit larger than
    /// the supplied data is an error rather than an implicit truncation or
    /// zero-extension. For a zero limit, no digest operation is performed and
    /// no code slots are returned. Exponent zero uses the format's unpaged
    /// single-range form.
    func hashCodePages(
        _ code: Data,
        codeLimit: UInt64,
        pageSize: CodeDirectoryPageSize,
        hashConfiguration: CodeDirectoryHashConfiguration
    ) throws -> [CodeDirectoryCodeSlot] {
        guard codeLimit <= UInt64(UInt32.max) else {
            throw CodeDirectoryError.invalidCodeLimit
        }
        guard codeLimit <= UInt64(code.count) else {
            throw CodeDirectoryError.codeLimitExceedsAvailableBytes
        }
        guard let limit = Int(exactly: codeLimit) else {
            throw CodeDirectoryError.invalidCodeLimit
        }
        let slotCount = try CodeDirectory.expectedCodeSlotCount(
            codeLimit: codeLimit,
            pageSize: pageSize
        )
        guard slotCount <= CodeDirectory.maximumCodeSlots else {
            throw CodeDirectoryError.resourceLimitExceeded
        }

        var slots: [CodeDirectoryCodeSlot] = []
        slots.reserveCapacity(slotCount)
        guard limit > 0 else { return slots }

        let pageByteCount = pageSize.byteCount ?? limit
        var start = 0
        for index in 0..<slotCount {
            guard start <= limit else {
                throw CodeDirectoryError.invalidPageCount
            }
            let remaining = limit - start
            let length = min(pageByteCount, remaining)
            guard length > 0, length <= limit - start else {
                throw CodeDirectoryError.invalidLength
            }
            let end = start + length
            let page = code.subdata(in: start..<end)
            let digest = try messageDigest.digest(
                page,
                algorithm: hashConfiguration.digestAlgorithm
            )
            guard digest.algorithm == hashConfiguration.digestAlgorithm else {
                throw CodeDirectoryError.digestAlgorithmMismatch
            }
            guard digest.bytes.count == hashConfiguration.digestAlgorithm.digestLength else {
                throw CodeDirectoryError.invalidHashLength
            }
            let hash: Data
            if hashConfiguration.hashSize == digest.bytes.count {
                hash = digest.bytes
            } else {
                guard hashConfiguration.hashSize < digest.bytes.count else {
                    throw CodeDirectoryError.invalidHashConfiguration
                }
                hash = Data(digest.bytes.prefix(hashConfiguration.hashSize))
            }
            guard hash.count == hashConfiguration.hashSize else {
                throw CodeDirectoryError.invalidHashLength
            }
            slots.append(CodeDirectoryCodeSlot(index: index, hash: hash))
            start = end
        }
        guard start == limit else {
            throw CodeDirectoryError.invalidPageCount
        }
        return slots
    }
}
