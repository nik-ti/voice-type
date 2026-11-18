// Remembers the model's reading of the fixed cleanup instructions and examples between takes.
// Each take then only processes its own transcript, which removes most of the per-take startup time.
import MLX
import MLXLMCommon

final class InstructionPromptCache: @unchecked Sendable {
    private var prefix: [Int32] = []
    private var cache: [KVCache]?

    /// Returns the saved cache when this prompt begins with exactly the instructions it was built from.
    func reusableCache(for promptTokens: [Int32]) -> (cache: [KVCache], prefixLength: Int)? {
        guard let cache, !prefix.isEmpty, promptTokens.count > prefix.count,
              promptTokens.starts(with: prefix) else { return nil }
        return (cache, prefix.count)
    }

    func start(prefix: [Int32], cache: [KVCache]) {
        self.prefix = prefix
        self.cache = cache
    }

    /// Drops the transcript and reply from the cache so only the instructions remain for the next take.
    func rewindToPrefix() {
        guard let cache, let offset = cache.first?.offset, offset >= prefix.count,
              cache.allSatisfy(\.isTrimmable) else {
            self.cache = nil
            prefix = []
            return
        }
        for layer in cache { layer.trim(layer.offset - prefix.count) }
    }
}
