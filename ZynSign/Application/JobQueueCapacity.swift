/// Shared scheduling bound for independent signing and transfer queues. Work is
/// owned by application services, never by screen lifetimes. Admission and states
/// remain specific to each pipeline; downloading must never imply signing admission.
enum JobQueueCapacity {
    static func hasCapacity(running: Int, limit: Int) -> Bool {
        running >= 0 && limit > 0 && running < limit
    }
}
