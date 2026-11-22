import SwiftUI

enum TerminalSessionStatus: Int, Equatable {
    case idle, failed, running, waiting

    init(block: TerminalCommandBlock?) {
        switch block?.state {
        case .waitingForInput, .hiddenInput: self = .waiting
        case .running, .alternateScreen: self = .running
        case .interrupted: self = .failed
        case .finished: self = (block?.exitCode ?? 0) == 0 ? .idle : .failed
        case .cancelled, nil: self = .idle
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .failed: .red
        case .running: .green
        case .waiting: .orange
        }
    }

    @MainActor
    static func ordered(_ sessions: [TerminalSession]) -> [TerminalSession] {
        sessions.sorted {
            if $0.status == $1.status { return $0.lastActivity > $1.lastActivity }
            return $0.status.rawValue > $1.status.rawValue
        }
    }

    static func countBadge(_ count: Int) -> Int? { count > 1 ? count : nil }
}

extension TerminalSession {
    var status: TerminalSessionStatus { TerminalSessionStatus(block: blocks.last) }
}

struct TerminalSessionStatusDot: View {
    let status: TerminalSessionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.4 : 1)
            .task(id: status == .running && !reduceMotion) {
                guard status == .running, !reduceMotion else { dimmed = false; return }
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.9)) { dimmed.toggle() }
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            .accessibilityHidden(true)
    }
}
