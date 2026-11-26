/// Why a test stopped waiting for its worker to reach a point.
enum GateWaitError: Error, Equatable {
    case timedOut
    case workerFinished
}
