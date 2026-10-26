/// Local input guards shared by provider decoders and tool dispatch. These do
/// not constrain provider generation. Source edits carry file contents and need
/// the same allowance in ordinary chat and dedicated refactor turns.
enum ToolInputLimits {
    static let maximumArgumentBytes = 262144
    static func argumentBytes(for name: String) -> Int {
        ["validate_web_source", "update_web_source"].contains(name) ? maximumArgumentBytes : 4096
    }
}
