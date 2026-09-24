/// Control-character detection for `Character`.
///
/// The standard library exposes control-ness on Unicode scalars
/// (`Unicode.Scalar.Properties`) but offers no `Character.isControl`, while
/// validation and redaction in this module judge whole characters. This
/// fills that gap with one shared definition: a character counts as control
/// when any of its scalars carries the control general category.
///
/// The name mirrors the missing standard API deliberately. If a future SDK
/// introduces `Character.isControl`, the collision surfaces as a loud
/// ambiguity error at the use sites, which is preferable to nine quiet,
/// divergent local definitions.
extension Character {

    /// Whether any scalar in this character is a control scalar.
    var isControl: Bool {
        unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }
}
