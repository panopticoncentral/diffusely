import Combine

/// Debounces pointer hover so a video preview starts only when the hover is
/// deliberate. `begin()` arms `isArmed` after `delay` unless `cancel()` (or a
/// newer `begin()`) intervenes first. `delay` is injectable for tests; `begin()`
/// returns its `Task` so callers/tests can await the pending arm.
@MainActor
final class HoverIntent: ObservableObject {
    @Published private(set) var isArmed = false

    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    @discardableResult
    func begin() -> Task<Void, Never> {
        task?.cancel()
        let delay = self.delay
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }  // cancelled
            self?.isArmed = true
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        task = nil
        isArmed = false
    }
}
