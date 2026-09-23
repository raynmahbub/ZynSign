import Foundation

/// An immutable, header-inclusive individual blob. Only the CodeDirectory
/// factory creates a structurally understood blob. Opaque payloads have a
/// checked outer frame, not validated semantics or cryptographic integrity.
struct CodeSignatureBlob: Equatable {
    enum Content: Equatable {
        case codeDirectory(CodeDirectorySerialization)
        case opaque
    }

    let content: Content
    let magic: UInt32
    let bytes: Data
    var serializedLength: Int { bytes.count }
    /// The generic frame is eight bytes, including for CodeDirectories.
    var payload: Data { Data(bytes.dropFirst(8)) }

    private init(content: Content, magic: UInt32, bytes: Data) {
        self.content = content
        self.magic = magic
        self.bytes = bytes
    }

    /// Serializes once through ZS-023. The container never patches these bytes
    /// or serializes the directory again to discover its size.
    static func codeDirectory(_ directory: CodeDirectory) throws -> Self {
        let serialized = try directory.serialize()
        try serialized.validate()
        return Self(content: .codeDirectory(serialized), magic: CodeDirectory.magic,
                    bytes: serialized.bytes)
    }

    /// Accepts an existing complete blob, including its generic header. This
    /// is not a requirements, entitlements, or CMS generator.
    static func opaque(serializedBytes bytes: Data) throws -> Self {
        guard bytes.count <= SignatureSuperBlob.maximumSerializedLength else {
            throw SuperBlobError.resourceLimitExceeded
        }
        guard bytes.count >= 8 else { throw SuperBlobError.invalidLength }
        let magic = try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let reader = BoundedBinaryReader(bytes: raw)
            let length = try reader.uint32AsInt(at: 4, order: .bigEndian, boundary: .signatureBlob)
            guard length == bytes.count else { throw SuperBlobError.invalidLength }
            return try reader.uint32(at: 0, order: .bigEndian, boundary: .signatureBlob)
        }
        // Do not allow a malformed CodeDirectory to bypass its constructor
        // by relabeling it as an opaque blob, even in an unknown slot.
        guard magic != CodeDirectory.magic else {
            throw SuperBlobError.codeDirectoryRequiresTypedConstruction
        }
        return Self(content: .opaque, magic: magic, bytes: bytes)
    }
}

/// Index type and blob magic are different fields with different meanings.
/// Known slot/magic pairs must agree; unknown pairs stay explicitly opaque.
struct CodeSignatureBlobEntry: Equatable {
    let type: CodeSignatureBlobType
    let blob: CodeSignatureBlob
    let encodedType: UInt32

    init(type: CodeSignatureBlobType, blob: CodeSignatureBlob) throws {
        let encodedType = try type.encodedValue()
        if let expected = type.expectedMagic, blob.magic != expected {
            throw SuperBlobError.invalidBlobMagic(expected: expected, actual: blob.magic)
        }
        switch blob.content {
        case .codeDirectory:
            guard type.isCodeDirectory else { throw SuperBlobError.unsupportedBlobType }
        case .opaque:
            guard !type.isCodeDirectory else {
                throw SuperBlobError.codeDirectoryRequiresTypedConstruction
            }
        }
        self.type = type
        self.blob = blob
        self.encodedType = encodedType
    }
}
