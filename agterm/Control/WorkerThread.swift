import Foundation

/// Intel: x86_64 builds can compile a `Thread { }` literal as `@MainActor`, trapping on its first instruction.
func makeWorkerThread(_ body: @escaping @Sendable () -> Void) -> Thread {
    Thread(block: body)
}

/// `Thread.detachNewThread` through the same nonisolated parameter as `makeWorkerThread`.
func detachWorkerThread(_ body: @escaping @Sendable () -> Void) {
    Thread.detachNewThread(body)
}
