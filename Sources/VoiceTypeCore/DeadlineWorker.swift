// Bounds the time a caller waits for optional work without pretending to stop hardware instantly.
// The worker remains busy until the actual operation drains, preventing overlapping inference.
import Foundation

@MainActor
public final class DeadlineWorker<Value: Sendable> {
    public var isBusy: Bool { activeID != nil }
    private var activeID: UUID?
    private var waiter: CheckedContinuation<Value?, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    public func run(timeout: Duration, operation: @escaping @Sendable () async throws -> Value) async -> Value? {
        guard !isBusy, !Task.isCancelled else { return nil }
        let id = UUID()
        activeID = id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
                operationTask = Task.detached(priority: .userInitiated) { [weak self] in
                    let result = try? await operation()
                    await self?.complete(id, result: result)
                }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.expire(id)
                }
                if Task.isCancelled { expire(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expire(id) }
        }
    }

    public func cancel() {
        if let id = activeID { expire(id) }
    }

    private func expire(_ id: UUID) {
        guard activeID == id else { return }
        resolve(nil)
        operationTask?.cancel()
    }

    private func complete(_ id: UUID, result: Value?) {
        guard activeID == id else { return }
        resolve(result)
        operationTask = nil
        activeID = nil
    }

    private func resolve(_ result: Value?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: result)
    }
}
