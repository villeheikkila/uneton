/// Owns independent token streams so one long-lived activity cannot block another.
public actor ConcurrentTokenObservers {
  private var tasks: [String: Task<Void, Never>] = [:]

  public init() {}

  public func start(id: String, observe: @escaping @MainActor @Sendable () async -> Void) {
    guard tasks[id] == nil else { return }
    tasks[id] = Task {
      await observe()
      tasks.removeValue(forKey: id)
    }
  }

  public func cancelAll() async {
    let running = Array(tasks.values)
    for task in running { task.cancel() }
    for task in running { await task.value }
    tasks.removeAll()
  }
}
