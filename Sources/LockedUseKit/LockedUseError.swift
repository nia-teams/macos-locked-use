import Foundation

public enum LockedUseError: Error, LocalizedError, Equatable {
    case message(String)
    case stateUnavailable(String)
    case usage(String)
    case stopped(reason: LockedUseStateMachine.StopReason?, awaitingManualUnlock: Bool)

    public var exitCode: Int32 {
        switch self {
        case .usage: return 64
        case .stopped(let reason, let manual): return manual || reason?.requiresManualUnlock == true ? 75 : 76
        case .stateUnavailable: return 77
        case .message: return 1
        }
    }

    public var errorDescription: String? {
        switch self {
        case .message(let message), .stateUnavailable(let message), .usage(let message): return message
        case .stopped(let reason, let manual):
            return manual || reason?.requiresManualUnlock == true
                ? "Locked Use stopped (\(reason?.rawValue ?? "awaitingManualUnlock")); yield to the human and unlock the Mac normally."
                : "Locked Use lease stopped (\(reason?.rawValue ?? "relocked"))."
        }
    }
}
