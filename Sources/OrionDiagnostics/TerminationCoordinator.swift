import Foundation

/// Allows graceful serial/recording cleanup without waiting indefinitely to quit.
@MainActor final class TerminationCoordinator {
    private(set) var isReady = false
    private var started = false
    private var cleanup: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    func request(timeout: Duration = .seconds(8), shutdown: @escaping @MainActor () async -> Void,
                 onReady: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        cleanup = Task { [weak self] in
            await shutdown()
            self?.finish(onReady)
        }
        // Independent tasks are intentional: a task group would still wait for
        // an unresponsive cleanup child after its timeout child completed.
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(onReady)
        }
    }

    private func finish(_ onReady: @MainActor () -> Void) {
        guard !isReady else { return }
        isReady = true
        cleanup?.cancel(); watchdog?.cancel()
        cleanup = nil; watchdog = nil
        onReady()
    }
}
