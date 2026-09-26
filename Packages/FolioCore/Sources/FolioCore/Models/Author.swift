/// A person (or organisation) credited as an author.
///
/// Organisations store their full name in `family` and leave `given` empty.
public struct Author: Codable, Sendable, Hashable {
    public var family: String
    public var given: String

    public init(family: String, given: String = "") {
        self.family = family
        self.given = given
    }
}
