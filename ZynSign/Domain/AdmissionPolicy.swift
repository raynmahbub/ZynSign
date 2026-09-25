/// What the library does when the content it is offered is already held.
///
/// The distinction exists because two different questions can be asked of the
/// same bytes. “Does the library already have this package?” is the automatic
/// question, and its answer is that nothing needs storing again. “I know it
/// does — store it anyway” is the user's answer to a duplicate they were
/// shown, and it is the only reason ZynSign would ever hold the same content
/// twice.
///
/// The policy never changes what the library holds for existing records; it
/// decides only whether the offered artifact is adopted as a further record.
enum AdmissionPolicy: Equatable, Hashable, Sendable {

    /// Recognise byte-identical content and take nothing. The default, and
    /// the policy every path that has not asked the user a question uses.
    case strict

    /// Adopt the offered artifact even when the library holds byte-identical
    /// content, creating a further record. The bytes are adopted under the
    /// import's own identifier; the existing records are untouched.
    case allowDuplicateContent

    /// Whether byte-identical content is admitted as a second record.
    var allowsDuplicateContent: Bool {
        self == .allowDuplicateContent
    }
}
