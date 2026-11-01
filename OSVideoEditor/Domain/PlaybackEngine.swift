//
//  PlaybackEngine.swift
//  OSVideoEditor
//
//  Deterministic time-scrubbing playback controller and mathematical keyframe interpolator
//  (Linear, Cubic Bezier Ease-In-Out, and Damped Cartoon Spring) driving CanvasState.
//

import CoreGraphics
import Darwin
import Foundation
import Observation

// MARK: - Pure Keyframe Interpolation & Scene Evaluation

nonisolated enum KeyframeInterpolator {

    /// Evaluates normalized progress `u in [0, 1]` through the requested `InterpolationCurve`.
    /// Note: `.spring` intentionally produces a subtle under-damped overshoot (~5%) before settling to `1.0`.
    static func progress(for rawT: Double, curve: InterpolationCurve) -> Double {
        if rawT <= 0.0 { return 0.0 }
        if rawT >= 1.0 { return 1.0 }

        switch curve {
        case .linear:
            return rawT

        case .easeInOut:
            // Standard smooth ease-in-out cubic Bezier: P1(0.42, 0.0), P2(0.58, 1.0)
            return evaluateCubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0, at: rawT)

        case .spring:
            return evaluateDampedSpring(at: rawT)
        }
    }

    /// Interpolates a `WindowFrame` (origin X/Y, width, height) between `from` and `to`.
    static func interpolateFrame(
        from start: WindowFrame,
        to end: WindowFrame,
        progress rawT: Double,
        curve: InterpolationCurve,
        minimumSize: CGSize = CGSize(width: 120, height: 100)
    ) -> WindowFrame {
        if start == end || rawT <= 0.0 {
            return start
        }
        if rawT >= 1.0 {
            return end
        }

        let eased = CGFloat(progress(for: rawT, curve: curve))
        let x = start.origin.x + (end.origin.x - start.origin.x) * eased
        let y = start.origin.y + (end.origin.y - start.origin.y) * eased
        let minW = max(80, min(minimumSize.width, min(start.size.width, end.size.width)))
        let minH = max(80, min(minimumSize.height, min(start.size.height, end.size.height)))
        let width = max(minW, start.size.width + (end.size.width - start.size.width) * eased)
        let height = max(minH, start.size.height + (end.size.height - start.size.height) * eased)

        return WindowFrame(x: x, y: y, width: width, height: height)
    }

    /// Deterministically evaluates a single `WindowTimelineTrack` at timestamp `time`.
    /// Returns `nil` if the window does not exist on the desktop at `time` (not yet spawned or already closed).
    static func evaluateTrack(
        _ track: WindowTimelineTrack,
        at time: Double,
        curve: InterpolationCurve
    ) -> EvaluatedWindowState? {
        let keyframes = track.keyframes
        guard let first = keyframes.first else { return nil }
        let spawnOrigin = track.wasSpawnedDuringSession ? first.time : 0.0

        // Prior to first keyframe
        if time < first.time {
            if track.wasSpawnedDuringSession || !first.isPresent {
                return nil
            }
            return EvaluatedWindowState(
                windowID: track.windowID,
                title: track.title,
                initialContent: track.initialContent,
                minimumSize: track.minimumSize,
                frame: first.frame,
                zIndex: first.zIndex,
                presentationState: first.presentationState,
                isFocused: first.isFocused,
                accent: first.accent,
                spawnTime: spawnOrigin
            )
        }

        guard let index = rightmostKeyframeIndex(in: keyframes, atOrBefore: time) else {
            return nil
        }

        let k0 = keyframes[index]
        guard k0.isPresent else {
            // Discrete close transition occurred at or before `time`
            return nil
        }

        // At or beyond the final keyframe on this track
        guard index + 1 < keyframes.count else {
            return EvaluatedWindowState(
                windowID: track.windowID,
                title: track.title,
                initialContent: track.initialContent,
                minimumSize: track.minimumSize,
                frame: k0.frame,
                zIndex: k0.zIndex,
                presentationState: k0.presentationState,
                isFocused: k0.isFocused,
                accent: k0.accent,
                spawnTime: spawnOrigin
            )
        }

        let k1 = keyframes[index + 1]
        let span = k1.time - k0.time

        let interpolatedFrame: WindowFrame
        if span <= 0.000_001 || !k1.isPresent {
            interpolatedFrame = k0.frame
        } else {
            let localT = (time - k0.time) / span
            interpolatedFrame = interpolateFrame(
                from: k0.frame,
                to: k1.frame,
                progress: localT,
                curve: curve,
                minimumSize: track.minimumSize
            )
        }

        // Discrete properties (zIndex, minimized/maximized state, active focus, accent) step at keyframe boundaries
        return EvaluatedWindowState(
            windowID: track.windowID,
            title: track.title,
            initialContent: track.initialContent,
            minimumSize: track.minimumSize,
            frame: interpolatedFrame,
            zIndex: k0.zIndex,
            presentationState: k0.presentationState,
            isFocused: k0.isFocused,
            accent: k0.accent,
            spawnTime: spawnOrigin
        )
    }

    /// Deterministically evaluates the full desktop scene at timestamp `time`.
    static func evaluateScene(
        in session: RecordedSession,
        at time: Double,
        curve: InterpolationCurve
    ) -> InterpolatedSceneState {
        let clampedTime = min(max(time, 0.0), max(0.0, session.duration))

        var evaluatedWindows: [EvaluatedWindowState] = []
        evaluatedWindows.reserveCapacity(session.tracks.count)

        for track in session.tracks {
            if let state = evaluateTrack(track, at: clampedTime, curve: curve) {
                evaluatedWindows.append(state)
            }
        }

        let visibleWindows = evaluatedWindows.filter { $0.presentationState != .minimized }
        let focusedVisible = visibleWindows
            .filter(\.isFocused)
            .max(by: { $0.zIndex < $1.zIndex })
        let resolvedActiveID = focusedVisible?.windowID
            ?? visibleWindows.max(by: { $0.zIndex < $1.zIndex })?.windowID

        return InterpolatedSceneState(
            time: clampedTime,
            windows: evaluatedWindows,
            activeWindowID: resolvedActiveID,
            wallpaper: session.wallpaper,
            canvasSize: session.canvasSize
        )
    }

    // MARK: - Binary Search & Curve Solvers

    /// Finds the largest index `i` such that `keyframes[i].time <= time` in `O(log N)`.
    static func rightmostKeyframeIndex(
        in keyframes: [WindowKeyframe],
        atOrBefore time: Double
    ) -> Int? {
        guard !keyframes.isEmpty, time >= keyframes[0].time else { return nil }

        var low = 0
        var high = keyframes.count - 1
        var best = 0

        while low <= high {
            let mid = low + (high - low) / 2
            if keyframes[mid].time <= time {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    /// Solves parametric 1D cubic Bezier `(0,0) -> (x1,y1) -> (x2,y2) -> (1,1)` for `y(x)` via Newton-Raphson + bisection fallback.
    private static func evaluateCubicBezier(
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double,
        at targetX: Double
    ) -> Double {
        let cx = 3.0 * x1
        let bx = 3.0 * (x2 - x1) - cx
        let ax = 1.0 - cx - bx

        let cy = 3.0 * y1
        let by = 3.0 * (y2 - y1) - cy
        let ay = 1.0 - cy - by

        func sampleX(_ s: Double) -> Double {
            ((ax * s + bx) * s + cx) * s
        }

        func sampleDerivativeX(_ s: Double) -> Double {
            (3.0 * ax * s + 2.0 * bx) * s + cx
        }

        func sampleY(_ s: Double) -> Double {
            ((ay * s + by) * s + cy) * s
        }

        var s = targetX
        var converged = false

        for _ in 0..<6 {
            let err = sampleX(s) - targetX
            if abs(err) < 1e-7 {
                converged = true
                break
            }
            let derivative = sampleDerivativeX(s)
            if abs(derivative) < 1e-6 {
                break
            }
            s = min(max(s - err / derivative, 0.0), 1.0)
        }

        if !converged {
            var low = 0.0
            var high = 1.0
            s = targetX
            for _ in 0..<14 {
                let err = sampleX(s) - targetX
                if abs(err) < 1e-7 { break }
                if err < 0 {
                    low = s
                } else {
                    high = s
                }
                s = 0.5 * (low + high)
            }
        }

        return sampleY(s)
    }

    /// Evaluates an under-damped harmonic spring normalized cleanly to `(0, 0)` and `(1, 1)`.
    private static func evaluateDampedSpring(
        at u: Double,
        dampingRatio zeta: Double = 0.68,
        naturalFrequency omega0: Double = 11.0
    ) -> Double {
        let omegaD = omega0 * (1.0 - zeta * zeta).squareRoot()

        func rawSpring(_ t: Double) -> Double {
            let decay = Darwin.exp(-zeta * omega0 * t)
            let oscillation = Darwin.cos(omegaD * t) + ((zeta * omega0) / omegaD) * Darwin.sin(omegaD * t)
            return 1.0 - decay * oscillation
        }

        let endValue = rawSpring(1.0)
        let current = rawSpring(u)
        // Smooth boundary correction ensures exact f(1) == 1.0 without jump discontinuity
        return current + (1.0 - endValue) * u
    }
}

// MARK: - Observable Playback Controller

@Observable
final class PlaybackEngine {
    // MARK: - Playback State

    private(set) var currentTime: Double = 0.0
    private(set) var isPlaying: Bool = false
    private(set) var session: RecordedSession?

    var duration: Double {
        session?.duration ?? 0.0
    }

    var hasRecordedSession: Bool {
        guard let session else { return false }
        return !session.tracks.isEmpty
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0.0), 1.0)
    }

    /// Active keyframe interpolation curve; changing this immediately updates the canvas at `currentTime`.
    var interpolationCurve: InterpolationCurve = .easeInOut {
        didSet {
            if oldValue != interpolationCurve, session != nil {
                applySceneToCanvas(at: currentTime)
            }
        }
    }

    var isLooping: Bool = false
    var playbackRate: Double = 1.0

    // MARK: - Internal Playback Loop Bookkeeping

    @ObservationIgnored
    private weak var canvasState: CanvasState?
    @ObservationIgnored
    private var playbackTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastTickUptime: TimeInterval = 0

    // MARK: - Initialization

    init(canvasState: CanvasState? = nil) {
        self.canvasState = canvasState
    }

    // MARK: - Session Binding

    func bind(to canvasState: CanvasState) {
        self.canvasState = canvasState
    }

    /// Loads a recorded session into the playback controller and optionally seeks to an initial timestamp.
    func loadSession(
        _ newSession: RecordedSession?,
        canvasState: CanvasState? = nil,
        seekTo initialTime: Double? = nil
    ) {
        pause()
        if let canvasState {
            self.canvasState = canvasState
        }
        self.session = newSession

        guard let newSession else {
            currentTime = 0.0
            return
        }

        let target = min(max(initialTime ?? currentTime, 0.0), newSession.duration)
        currentTime = target
        if initialTime != nil {
            applySceneToCanvas(at: target)
        }
    }

    // MARK: - Transport Controls

    /// Starts deterministic real-time playback from `currentTime` (rewinding to `0` if currently at the end).
    func play() {
        guard let session, session.duration > 0 else { return }
        guard !isPlaying else { return }

        if currentTime >= session.duration - 0.001 {
            seek(to: 0.0)
        } else {
            applySceneToCanvas(at: currentTime)
        }

        isPlaying = true
        lastTickUptime = ProcessInfo.processInfo.systemUptime

        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            // ~120 Hz frame pacing for ProMotion-smooth window interpolation
            let frameDuration = Duration.milliseconds(8)
            while !Task.isCancelled {
                try? await Task.sleep(for: frameDuration)
                guard !Task.isCancelled, let self, self.isPlaying else { break }
                self.advancePlaybackTick()
            }
        }
    }

    /// Pauses active playback at the current playhead position.
    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Stops playback and rewinds the playhead to `00:00.00`.
    func stop() {
        pause()
        seek(to: 0.0)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Deterministically scrubs to `time`, clamping within `[0, duration]` and updating `CanvasState` synchronously.
    func seek(to time: Double) {
        let clamped = min(max(time, 0.0), max(0.0, duration))
        currentTime = clamped
        applySceneToCanvas(at: clamped)
    }

    /// Jumps to the previous or next major keyframe landmark across all tracks.
    func stepToAdjacentKeyframe(forward: Bool) {
        guard let session else { return }
        pause()
        let landmarks = session.snapTimestamps
        let epsilon = 0.005

        if forward {
            if let next = landmarks.first(where: { $0 > currentTime + epsilon }) {
                seek(to: next)
            } else {
                seek(to: session.duration)
            }
        } else {
            if let prev = landmarks.last(where: { $0 < currentTime - epsilon }) {
                seek(to: prev)
            } else {
                seek(to: 0.0)
            }
        }
    }

    /// Evaluates the scene at `time` without mutating `CanvasState` (useful for previews and testing).
    func evaluateScene(at time: Double) -> InterpolatedSceneState? {
        guard let session else { return nil }
        return KeyframeInterpolator.evaluateScene(
            in: session,
            at: time,
            curve: interpolationCurve
        )
    }

    // MARK: - Internal Tick & Canvas Synchronization

    private func advancePlaybackTick() {
        guard let session, session.duration > 0 else {
            pause()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let rawDelta = max(0.0, min(0.1, now - lastTickUptime))
        lastTickUptime = now

        let nextTime = currentTime + rawDelta * max(0.1, playbackRate)
        if nextTime >= session.duration {
            if isLooping {
                let wrapped = nextTime.truncatingRemainder(dividingBy: session.duration)
                seek(to: wrapped)
            } else {
                seek(to: session.duration)
                pause()
            }
        } else {
            seek(to: nextTime)
        }
    }

    private func applySceneToCanvas(at time: Double) {
        guard let session, let canvasState else { return }
        let scene = KeyframeInterpolator.evaluateScene(
            in: session,
            at: time,
            curve: interpolationCurve
        )
        canvasState.applyInterpolatedScene(scene)
    }
}
