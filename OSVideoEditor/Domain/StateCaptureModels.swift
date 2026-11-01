//
//  StateCaptureModels.swift
//  OSVideoEditor
//
//  Timestamped state-update payloads emitted by CanvasState for the Milestone 2 recording/timeline engine.
//

import CoreGraphics
import Foundation

/// Lifecycle phase of an interactive canvas mutation.
nonisolated enum InteractionPhase: String, Codable, Sendable, Equatable {
    case began
    case changed
    case ended
    case discrete
}

/// Window presentation mode on the virtual desktop.
nonisolated enum WindowPresentationState: String, Codable, Sendable, Equatable {
    case normal
    case minimized
    case maximized
}

/// Immutable keyframe-ready snapshot of a single desktop window at a point in time.
nonisolated struct WindowKeyframeSnapshot: Equatable, Codable, Sendable, Identifiable {
    var id: UUID { windowID }

    let windowID: UUID
    let title: String
    let contentKind: WindowContent.Kind
    let frame: WindowFrame
    let zIndex: Double
    let presentationState: WindowPresentationState
    let accent: CartoonAccent
}

/// Describes the specific mutation that triggered a timestamped state capture event.
nonisolated enum CanvasMutationAction: Equatable, Codable, Sendable {
    case windowMoved(
        windowID: UUID,
        windowTitle: String,
        from: CGPoint,
        to: CGPoint,
        phase: InteractionPhase
    )
    case windowResized(
        windowID: UUID,
        windowTitle: String,
        corner: ResizeCorner,
        from: WindowFrame,
        to: WindowFrame,
        phase: InteractionPhase
    )
    case windowFocused(
        windowID: UUID,
        windowTitle: String,
        zIndex: Double
    )
    case windowPresentationChanged(
        windowID: UUID,
        windowTitle: String,
        state: WindowPresentationState,
        frame: WindowFrame
    )
    case windowAdded(
        windowID: UUID,
        windowTitle: String,
        kind: WindowContent.Kind,
        frame: WindowFrame
    )
    case windowClosed(
        windowID: UUID,
        windowTitle: String
    )
    case workspaceReset

    var badgeText: String {
        switch self {
        case .windowMoved: "MOVE"
        case .windowResized: "RESIZE"
        case .windowFocused: "Z-FOCUS"
        case .windowPresentationChanged: "STATE"
        case .windowAdded: "SPAWN"
        case .windowClosed: "CLOSE"
        case .workspaceReset: "RESET"
        }
    }

    var phase: InteractionPhase {
        switch self {
        case let .windowMoved(_, _, _, _, phase),
             let .windowResized(_, _, _, _, _, phase):
            phase
        case .windowFocused,
             .windowPresentationChanged,
             .windowAdded,
             .windowClosed,
             .workspaceReset:
            .discrete
        }
    }

    var summaryDescription: String {
        switch self {
        case let .windowMoved(_, title, _, to, phase):
            "\(title) → (\(Int(to.x)), \(Int(to.y))) [\(phase.rawValue)]"
        case let .windowResized(_, title, corner, _, to, phase):
            "\(title) [\(corner.shortLabel)] → \(Int(to.size.width))×\(Int(to.size.height)) [\(phase.rawValue)]"
        case let .windowFocused(_, title, zIndex):
            "\(title) → z:\(Int(zIndex))"
        case let .windowPresentationChanged(_, title, state, _):
            "\(title) → \(state.rawValue)"
        case let .windowAdded(_, title, kind, _):
            "\(title) (\(kind.shortBadge))"
        case let .windowClosed(_, title):
            "\(title) closed"
        case .workspaceReset:
            "Default scene restored"
        }
    }
}

/// Complete timestamped state emission produced by `CanvasState` on every movement, resize, and window mutation.
nonisolated struct CanvasStateUpdate: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    let sequenceNumber: UInt64
    let timestamp: Date
    /// Monotonic seconds elapsed since the `CanvasState` capture clock started (ideal for timeline keyframing).
    let elapsedSeconds: TimeInterval
    let action: CanvasMutationAction
    let windowsSnapshot: [WindowKeyframeSnapshot]

    var formattedElapsed: String {
        String(format: "+%06.3fs", elapsedSeconds)
    }
}
