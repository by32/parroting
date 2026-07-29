/// Single source of truth for the shipped version.
///
/// The release workflow asserts `parrot --version` matches the pushed git tag,
/// so a forgotten bump fails the release rather than shipping a binary that
/// misreports itself. Bump this in the same commit that cuts a tag.
enum Version {
    static let current = "0.1.0"
}
