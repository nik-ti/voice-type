// Adds one trailing space to completed prose when it is copied for insertion.
// History and literal filenames retain their original text.
public enum DictationInsertion {
    public static func text(_ text: String) -> String {
        guard let last = text.last, ".!?…\"”»'".contains(last) else { return text }
        return text + " "
    }
}
