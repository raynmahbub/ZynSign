import Foundation

/// Opt-in inspection of bytes an application caller has already obtained
/// within its own intake policy. It reads no archive entry itself: the IPA
/// explorer still lists executable candidates without opening them. The
/// parser's structured failures cross this boundary unchanged.
struct MachOInspection {
    private let parser: any MachOParsing

    init(parser: any MachOParsing = ReadOnlyMachOParser()) {
        self.parser = parser
    }

    func inspect(bytes: Data) throws -> MachOImage {
        try parser.parse(bytes)
    }
}
