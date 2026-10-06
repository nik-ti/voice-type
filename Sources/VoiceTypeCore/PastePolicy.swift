// Conditions required before posting a single paste command.
// Passing these checks permits event delivery; it does not prove insertion in another app.
public enum PastePolicy {
    public static func canPost(hasPermission: Bool, targetIsFrontmost: Bool, clipboardUnchanged: Bool) -> Bool {
        hasPermission && targetIsFrontmost && clipboardUnchanged
    }
}
