import Foundation

/// Classifies existing code-signature state through the established bounded
/// ZS-022 parser. It performs no mutation, signing, hash computation, or
/// validity decision; malformed states stay explicit so a caller cannot treat
/// a parser failure as permission to replace bytes.
struct MachOCodeSignatureInspector {
    private let parser: any MachOParsing

    init(parser: any MachOParsing = ReadOnlyMachOParser()) {
        self.parser = parser
    }

    func inspect(bytes: Data) -> MachOCodeSignatureInspection {
        do {
            let image = try parser.parse(bytes)
            switch image.container {
            case .thin(let slice):
                return .thin(MachOCodeSignatureSliceInspection(
                    architectureIndex: nil,
                    slice: slice,
                    existingSignature: signatureState(for: slice)
                ))
            case .universal(let universal):
                let slices = universal.slices.enumerated().map { index, slice in
                    MachOCodeSignatureSliceInspection(
                        architectureIndex: index,
                        slice: slice,
                        existingSignature: signatureState(for: slice)
                    )
                }
                return .universal(slices)
            }
        } catch let error as MachOParsingError {
            if let state = MachOExistingCodeSignatureState.classify(error) {
                return .malformedSignature(
                    architectureIndex: error.architectureIndex,
                    state: state
                )
            }
            return .malformedMachO(error)
        } catch {
            // `MachOParsing` is an internal protocol whose production parser
            // raises MachOParsingError. A substitute that violates that
            // contract cannot be mistaken for a valid or absent signature.
            return .malformedMachO(MachOParsingError(.unsupportedFormat, at: .input))
        }
    }

    private func signatureState(for slice: MachOSlice) -> MachOExistingCodeSignatureState {
        if let embeddedSignature = slice.embeddedSignature {
            return .valid(embeddedSignature)
        }
        return .absent
    }
}
