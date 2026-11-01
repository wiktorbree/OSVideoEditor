//
//  TimelineModels.swift
//  OSVideoEditor
//
//  Milestone 2 domain models for recorded desktop sessions, normalized window keyframe tracks,
//  interpolation curves, and deterministic scene evaluation snapshots.
//

import CoreGraphics
import Foundation

/// Active operational mode of the ScreenPlay OS workspace.
nonisolated enum WorkspaceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case liveCanvas
    case reviewTimeline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveCanvas: "Live Canvas"
        case .reviewTimeline: "Review Timeline"
        }
    }

    var shortLabel: String {
        switch self {
        case .liveCanvas: "LIVE"
        case .reviewTimeline: "REVIEW"
        }
    }

    var systemImage: String {
        switch self {
        case .liveCanvas: "cursorarrow.motionlines"
        case .reviewTimeline: "film.stack"
        }
    }
}

/// Mathematical easing/motion curve applied when interpolating `WindowFrame` between keyframes.
nonisolated enum InterpolationCurve: String, CaseIterable, Codable, Sendable, Identifiable {
    case linear
    case easeInOut
    case spring

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: "Linear"
        case .easeInOut: "Ease In-Out"
        case .spring: "Spring"
        }
    }

    var shortBadge: String {
        switch self {
        case .linear: "LIN"
        case .easeInOut: "BEZIER"
        case .spring: "SPRING"
        }
    }

    var systemImage: String {
        switch self {
        case .linear: "line.diagonal"
        case .easeInOut: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .spring: "waveform.path"
        }
    }
}

/// Semantic classification of a recorded window keyframe on the timeline.
nonisolated enum KeyframeEventKind: String, Codable, Sendable, Equatable {
    case initial
    case moveBegan
    case moveSample
    case moveEnded
    case resizeBegan
    case resizeSample
    case resizeEnded
    case focused
    case presentationChanged
    case spawned
    case closed
    case hold

    /// Indicates whether this keyframe should be rendered as a primary diamond marker on the track UI
    /// and participate in magnetic playhead snapping.
    var isMajorLandmark: Bool {
        switch self {
        case .initial,
             .moveBegan,
             .moveEnded,
             .resizeBegan,
             .resizeEnded,
             .focused,
             .presentationChanged,
             .spawned,
             .closed:
            true
        case .moveSample,
             .resizeSample,
             .hold:
            false
        }
    }

    var isContinuousSample: Bool {
        switch self {
        case .moveSample, .resizeSample:
            true
        default:
            false
        }
    }
}

/// Single timestamped keyframe on a `WindowTimelineTrack`.
nonisolated struct WindowKeyframe: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    /// Monotonic seconds elapsed since the recording session started (`>= 0`).
    var time: Double
    var frame: WindowFrame
    var zIndex: Double
    var presentationState: WindowPresentationState
    var isFocused: Bool
    /// `true` while the window exists on the desktop canvas; `false` once closed.
    var isPresent: Bool
    var accent: CartoonAccent
    var eventKind: KeyframeEventKind

    init(
        id: UUID = UUID(),
        time: Double,
        frame: WindowFrame,
        zIndex: Double,
        presentationState: WindowPresentationState,
        isFocused: Bool,
        isPresent: Bool = true,
        accent: CartoonAccent,
        eventKind: KeyframeEventKind
    ) {
        self.id = id
        self.time = max(0, time)
        self.frame = frame
        self.zIndex = zIndex
        self.presentationState = presentationState
        self.isFocused = isFocused
        self.isPresent = isPresent
        self.accent = accent
        self.eventKind = eventKind
    }
}

/// Visual span representing a continuous transform interval (drag, resize, or animated zoom) on a track.
nonisolated struct MotionSpan: Identifiable, Equatable, Codable, Sendable {
    var id: String { "\(startTime)-\(endTime)-\(kind.rawValue)" }

    enum Kind: String, Codable, Sendable, Equatable {
        case move
        case resize
        case presentation
    }

    let startTime: Double
    let endTime: Double
    let kind: Kind

    var duration: Double {
        max(0, endTime - startTime)
    }
}

/// Per-window timeline track containing metadata for reconstruction and sorted keyframes.
nonisolated struct WindowTimelineTrack: Identifiable, Equatable, Codable, Sendable {
    var id: UUID { windowID }

    let windowID: UUID
    var title: String
    var contentKind: WindowContent.Kind
    var initialContent: WindowContent
    var minimumSize: CGSize
    var accent: CartoonAccent
    /// `true` if the window was spawned after `t = 0`, meaning it does not exist prior to its first keyframe.
    var wasSpawnedDuringSession: Bool
    /// Sorted monotonically by `time`.
    var keyframes: [WindowKeyframe]

    init(
        windowID: UUID,
        title: String,
        contentKind: WindowContent.Kind,
        initialContent: WindowContent,
        minimumSize: CGSize,
        accent: CartoonAccent,
        wasSpawnedDuringSession: Bool = false,
        keyframes: [WindowKeyframe] = []
    ) {
        self.windowID = windowID
        self.title = title
        self.contentKind = contentKind
        self.initialContent = initialContent
        self.minimumSize = minimumSize
        self.accent = accent
        self.wasSpawnedDuringSession = wasSpawnedDuringSession
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    var majorKeyframes: [WindowKeyframe] {
        keyframes.filter(\.eventKind.isMajorLandmark)
    }

    var sampleKeyframes: [WindowKeyframe] {
        keyframes.filter(\.eventKind.isContinuousSample)
    }

    /// Time range during which this window exists on the desktop within a session of `totalDuration`.
    func activePresenceRange(totalDuration: Double) -> ClosedRange<Double>? {
        guard let first = keyframes.first else { return nil }
        let start = wasSpawnedDuringSession ? first.time : 0.0
        let closeTime = keyframes.first(where: { !$0.isPresent })?.time
        let end = max(start, min(totalDuration, closeTime ?? totalDuration))
        return start...end
    }

    /// Derives continuous motion spans (move, resize, animated presentation transitions) for timeline bar rendering.
    var motionSpans: [MotionSpan] {
        guard keyframes.count >= 2 else { return [] }
        var spans: [MotionSpan] = []

        var activeStart: Double?
        var activeKind: MotionSpan.Kind?

        for index in 0..<keyframes.count {
            let kf = keyframes[index]
            switch kf.eventKind {
            case .moveBegan:
                if let start = activeStart, let kind = activeKind, kf.time > start {
                    spans.append(MotionSpan(startTime: start, endTime: kf.time, kind: kind))
                }
                activeStart = kf.time
                activeKind = .move

            case .moveSample:
                if activeStart == nil {
                    let fallbackStart = index > 0 ? keyframes[index - 1].time : kf.time
                    activeStart = fallbackStart
                    activeKind = .move
                }

            case .moveEnded:
                let start = activeStart ?? (index > 0 ? keyframes[index - 1].time : kf.time)
                if kf.time >= start {
                    spans.append(MotionSpan(startTime: start, endTime: kf.time, kind: .move))
                }
                activeStart = nil
                activeKind = nil

            case .resizeBegan:
                if let start = activeStart, let kind = activeKind, kf.time > start {
                    spans.append(MotionSpan(startTime: start, endTime: kf.time, kind: kind))
                }
                activeStart = kf.time
                activeKind = .resize

            case .resizeSample:
                if activeStart == nil {
                    let fallbackStart = index > 0 ? keyframes[index - 1].time : kf.time
                    activeStart = fallbackStart
                    activeKind = .resize
                }

            case .resizeEnded:
                let start = activeStart ?? (index > 0 ? keyframes[index - 1].time : kf.time)
                if kf.time >= start {
                    spans.append(MotionSpan(startTime: start, endTime: kf.time, kind: .resize))
                }
                activeStart = nil
                activeKind = nil

            case .presentationChanged:
                if index > 0 {
                    let prev = keyframes[index - 1]
                    if prev.frame != kf.frame && kf.time > prev.time {
                        spans.append(MotionSpan(startTime: prev.time, endTime: kf.time, kind: .presentation))
                    }
                }

            default:
                break
            }
        }

        // Close any still-open gesture span (e.g. while live recording a drag in progress)
        if let start = activeStart, let kind = activeKind, let lastTime = keyframes.last?.time, lastTime > start {
            spans.append(MotionSpan(startTime: start, endTime: lastTime, kind: kind))
        }

        return spans
    }
}

/// Timestamped interaction marker captured during a recording session.
nonisolated struct RecordedInteractionEvent: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let time: Double
    let action: CanvasMutationAction
    let activeWindowID: UUID?

    init(
        id: UUID = UUID(),
        time: Double,
        action: CanvasMutationAction,
        activeWindowID: UUID?
    ) {
        self.id = id
        self.time = max(0, time)
        self.action = action
        self.activeWindowID = activeWindowID
    }
}

/// Complete, self-contained recording of a ScreenPlay OS desktop performance.
nonisolated struct RecordedSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var createdAt: Date
    var duration: Double
    var wallpaper: CartoonWallpaper
    var canvasSize: CGSize
    var initialActiveWindowID: UUID?
    var tracks: [WindowTimelineTrack]
    var events: [RecordedInteractionEvent]
    var rawEventCount: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: Double,
        wallpaper: CartoonWallpaper,
        canvasSize: CGSize = CGSize(width: 1280, height: 760),
        initialActiveWindowID: UUID?,
        tracks: [WindowTimelineTrack],
        events: [RecordedInteractionEvent] = [],
        rawEventCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = max(0, duration)
        self.wallpaper = wallpaper
        self.canvasSize = CGSize(
            width: max(320, canvasSize.width),
            height: max(240, canvasSize.height)
        )
        self.initialActiveWindowID = initialActiveWindowID
        self.tracks = tracks
        self.events = events
        self.rawEventCount = rawEventCount
    }

    var totalKeyframeCount: Int {
        tracks.reduce(0) { $0 + $1.keyframes.count }
    }

    /// Deduplicated, sorted timestamps for magnetic playhead snapping (`0`, `duration`, and major keyframes).
    var snapTimestamps: [Double] {
        var candidates: [Double] = [0.0, duration]
        for track in tracks {
            for kf in track.majorKeyframes {
                candidates.append(kf.time)
            }
        }
        candidates.sort()

        var deduplicated: [Double] = []
        for t in candidates {
            if let last = deduplicated.last, abs(t - last) < 0.002 {
                continue
            }
            deduplicated.append(t)
        }
        return deduplicated
    }
}

// MARK: - Deterministic Scene Evaluation Output

/// Evaluated geometry and discrete state for a single window at time `t`.
nonisolated struct EvaluatedWindowState: Equatable, Sendable, Identifiable {
    var id: UUID { windowID }

    let windowID: UUID
    let title: String
    let initialContent: WindowContent
    let minimumSize: CGSize
    let frame: WindowFrame
    let zIndex: Double
    let presentationState: WindowPresentationState
    let isFocused: Bool
    let accent: CartoonAccent
    /// Timeline timestamp (`>= 0`) when this window first entered the desktop session.
    let spawnTime: Double

    init(
        windowID: UUID,
        title: String,
        initialContent: WindowContent,
        minimumSize: CGSize,
        frame: WindowFrame,
        zIndex: Double,
        presentationState: WindowPresentationState,
        isFocused: Bool,
        accent: CartoonAccent,
        spawnTime: Double = 0.0
    ) {
        self.windowID = windowID
        self.title = title
        self.initialContent = initialContent
        self.minimumSize = minimumSize
        self.frame = frame
        self.zIndex = zIndex
        self.presentationState = presentationState
        self.isFocused = isFocused
        self.accent = accent
        self.spawnTime = max(0.0, spawnTime)
    }
}

/// Complete desktop scene evaluated deterministically at playback time `t`.
nonisolated struct InterpolatedSceneState: Equatable, Sendable {
    let time: Double
    let windows: [EvaluatedWindowState]
    let activeWindowID: UUID?
    let wallpaper: CartoonWallpaper?
    let canvasSize: CGSize

    init(
        time: Double,
        windows: [EvaluatedWindowState],
        activeWindowID: UUID?,
        wallpaper: CartoonWallpaper?,
        canvasSize: CGSize = CGSize(width: 1280, height: 760)
    ) {
        self.time = time
        self.windows = windows
        self.activeWindowID = activeWindowID
        self.wallpaper = wallpaper
        self.canvasSize = canvasSize
    }
}

// MARK: - Timeline Timecode Formatting

nonisolated enum TimelineTimeFormatter {
    /// Formats elapsed seconds as `MM:SS.cc` (centiseconds) for transport counters.
    static func formatTimecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalCentiseconds = Int((clamped * 100.0).rounded())
        let centiseconds = totalCentiseconds % 100
        let totalSeconds = totalCentiseconds / 100
        let secs = totalSeconds % 60
        let mins = totalSeconds / 60
        return String(format: "%02d:%02d.%02d", mins, secs, centiseconds)
    }

    /// Formats ruler tick labels concisely (`0s`, `1.5s`, `01:05`).
    static func formatRulerLabel(_ seconds: Double, showTenths: Bool) -> String {
        let clamped = max(0, seconds)
        if clamped >= 60 {
            let mins = Int(clamped) / 60
            let secs = clamped - Double(mins * 60)
            if showTenths {
                return String(format: "%d:%04.1f", mins, secs)
            } else {
                return String(format: "%d:%02d", mins, Int(secs.rounded()))
            }
        }
        if showTenths {
            return String(format: "%.1fs", clamped)
        } else {
            return String(format: "%.0fs", clamped)
        }
    }
}
