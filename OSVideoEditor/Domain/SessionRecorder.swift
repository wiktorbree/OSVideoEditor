//
//  SessionRecorder.swift
//  OSVideoEditor
//
//  Live session recording engine consuming `CanvasState.makeStateUpdateStream()` and frame ticks,
//  normalizing high-frequency drag/resize bursts into clean 60 Hz / delta-filtered keyframes.
//

import CoreGraphics
import Darwin
import Foundation
import Observation

/// Configuration controlling how `SessionRecorder` throttles and normalizes high-frequency gestures.
nonisolated struct RecordingSamplingConfiguration: Equatable, Codable, Sendable {
    /// Maximum keyframe sampling rate (Hz) for continuous `.changed` drag and resize gestures.
    var maxSampleRateHz: Double
    /// Minimum Euclidean origin movement (points) required before emitting an intermediate move sample.
    var minimumPositionDelta: CGFloat
    /// Minimum Euclidean size delta (points) required before emitting an intermediate resize sample.
    var minimumSizeDelta: CGFloat
    /// Duration (seconds) over which discrete animated window jumps (e.g. Maximize / Restore) interpolate.
    var discreteTransitionDuration: Double

    var minimumSampleInterval: Double {
        1.0 / max(1.0, maxSampleRateHz)
    }

    static let standard60Hz = RecordingSamplingConfiguration(
        maxSampleRateHz: 60.0,
        minimumPositionDelta: 1.5,
        minimumSizeDelta: 1.5,
        discreteTransitionDuration: 0.24
    )
}

@Observable
final class SessionRecorder {
    // MARK: - Observable Recording State

    private(set) var isRecording: Bool = false
    /// Live monotonic elapsed recording duration (seconds).
    private(set) var elapsedTime: Double = 0.0
    /// Live-updated recorded session (populated in real time while recording and finalized on stop).
    private(set) var latestSession: RecordedSession?
    /// Total raw `CanvasStateUpdate` emissions observed during the active/last session.
    private(set) var rawEventsReceived: Int = 0
    /// Total normalized keyframes stored across all window tracks.
    private(set) var keyframesRecorded: Int = 0

    var samplingConfiguration: RecordingSamplingConfiguration

    // MARK: - Internal Session Buffers

    @ObservationIgnored
    private weak var canvasState: CanvasState?
    @ObservationIgnored
    private var streamTask: Task<Void, Never>?
    @ObservationIgnored
    private var tickerTask: Task<Void, Never>?

    @ObservationIgnored
    private var recordingOriginUptime: TimeInterval = 0
    @ObservationIgnored
    private var recordingOriginCanvasElapsed: TimeInterval = 0
    @ObservationIgnored
    private var lastProcessedSequenceNumber: UInt64 = 0
    @ObservationIgnored
    private var lastRecordedTime: Double = 0
    @ObservationIgnored
    private var sessionID = UUID()
    @ObservationIgnored
    private var sessionCreatedAt = Date()
    @ObservationIgnored
    private var initialWallpaper: CartoonWallpaper = .pastelSunrise
    @ObservationIgnored
    private var initialCanvasSize: CGSize = CGSize(width: 1280, height: 760)
    @ObservationIgnored
    private var initialActiveWindowID: UUID?

    @ObservationIgnored
    private var tracks: [WindowTimelineTrack] = []
    @ObservationIgnored
    private var trackIndexByWindowID: [UUID: Int] = [:]
    @ObservationIgnored
    private var recordedEvents: [RecordedInteractionEvent] = []

    @ObservationIgnored
    private var lastSampledTimeByWindow: [UUID: Double] = [:]
    @ObservationIgnored
    private var lastSampledFrameByWindow: [UUID: WindowFrame] = [:]
    @ObservationIgnored
    private var pendingSamplesByWindow: [UUID: PendingGestureSample] = [:]

    private struct PendingGestureSample {
        let time: Double
        let snapshot: WindowKeyframeSnapshot
        let kind: KeyframeEventKind
        let activeWindowID: UUID?
    }

    // MARK: - Initialization

    init(samplingConfiguration: RecordingSamplingConfiguration = .standard60Hz) {
        self.samplingConfiguration = samplingConfiguration
    }

    // MARK: - Recording Lifecycle

    /// Begins a new live recording session attached to `canvasState`, capturing baseline `t = 0` keyframes
    /// and subscribing to `canvasState.makeStateUpdateStream()`.
    func startRecording(canvasState: CanvasState) {
        if isRecording {
            _ = stopRecording()
        }

        self.canvasState = canvasState
        self.sessionID = UUID()
        self.sessionCreatedAt = Date()
        self.recordingOriginUptime = ProcessInfo.processInfo.systemUptime
        self.recordingOriginCanvasElapsed = canvasState.currentCaptureElapsedSeconds
        self.lastProcessedSequenceNumber = canvasState.totalCapturedEvents
        self.lastRecordedTime = 0.0
        self.elapsedTime = 0.0
        self.rawEventsReceived = 0
        self.keyframesRecorded = 0
        self.initialWallpaper = canvasState.wallpaper
        self.initialCanvasSize = canvasState.canvasBounds
        self.initialActiveWindowID = canvasState.activeWindowID

        self.tracks.removeAll(keepingCapacity: true)
        self.trackIndexByWindowID.removeAll(keepingCapacity: true)
        self.recordedEvents.removeAll(keepingCapacity: true)
        self.lastSampledTimeByWindow.removeAll(keepingCapacity: true)
        self.lastSampledFrameByWindow.removeAll(keepingCapacity: true)
        self.pendingSamplesByWindow.removeAll(keepingCapacity: true)

        // Capture t = 0 baseline keyframes for every open window on the desktop
        for window in canvasState.windows {
            let initialKeyframe = WindowKeyframe(
                time: 0.0,
                frame: window.frame,
                zIndex: window.zIndex,
                presentationState: window.presentationState,
                isFocused: canvasState.activeWindowID == window.id && !window.isMinimized,
                isPresent: true,
                accent: window.accent,
                eventKind: .initial
            )
            let track = WindowTimelineTrack(
                windowID: window.id,
                title: window.title,
                contentKind: window.content.kind,
                initialContent: window.content,
                minimumSize: window.minimumSize,
                accent: window.accent,
                wasSpawnedDuringSession: false,
                keyframes: [initialKeyframe]
            )
            trackIndexByWindowID[window.id] = tracks.count
            tracks.append(track)
            lastSampledTimeByWindow[window.id] = 0.0
            lastSampledFrameByWindow[window.id] = window.frame
        }

        isRecording = true
        publishLiveSession(durationOverride: 0.0)

        // Synchronously attach to CanvasState's AsyncStream so zero mutations can be missed
        let updateStream = canvasState.makeStateUpdateStream()
        streamTask = Task { @MainActor [weak self] in
            for await update in updateStream {
                guard !Task.isCancelled, let self, self.isRecording else { break }
                self.consumeStreamUpdate(update)
            }
        }

        // 60 Hz frame ticker advances live elapsed time and flushes resting mid-drag samples
        tickerTask = Task { @MainActor [weak self] in
            let tickInterval = Duration.milliseconds(16)
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard !Task.isCancelled, let self, self.isRecording else { break }
                self.recordFrameTick()
            }
        }
    }

    /// Finalizes the active recording session, flushing any pending samples and returning the immutable `RecordedSession`.
    @discardableResult
    func stopRecording() -> RecordedSession? {
        guard isRecording else { return latestSession }

        // Drain any synchronous recent updates that have not yet resumed the AsyncStream task
        if let canvasState {
            let unconsumed = canvasState.recentUpdates
                .filter { $0.sequenceNumber > lastProcessedSequenceNumber }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            for update in unconsumed {
                consumeStreamUpdate(update)
            }
        }

        flushAllPendingSamples()

        streamTask?.cancel()
        streamTask = nil
        tickerTask?.cancel()
        tickerTask = nil

        let wallClockElapsed = max(0.0, ProcessInfo.processInfo.systemUptime - recordingOriginUptime)
        let maxKeyframeTime = tracks
            .flatMap(\.keyframes)
            .map(\.time)
            .max() ?? 0.0
        let finalDuration = max(0.05, max(lastRecordedTime, max(wallClockElapsed, maxKeyframeTime)))

        isRecording = false
        elapsedTime = finalDuration
        publishLiveSession(durationOverride: finalDuration)
        return latestSession
    }

    /// Clears the stored recorded session when not actively recording.
    func clearRecordedSession() {
        guard !isRecording else { return }
        latestSession = nil
        elapsedTime = 0.0
        rawEventsReceived = 0
        keyframesRecorded = 0
    }

    // MARK: - Frame Ticks & Direct Deterministic Ingestion

    /// Advances the live recording clock and flushes any throttled mid-gesture samples whose throttle window has elapsed.
    func recordFrameTick(overrideElapsedSeconds: Double? = nil) {
        guard isRecording else { return }

        let nowElapsed: Double
        if let overrideElapsedSeconds {
            nowElapsed = max(lastRecordedTime, overrideElapsedSeconds)
        } else {
            nowElapsed = max(lastRecordedTime, ProcessInfo.processInfo.systemUptime - recordingOriginUptime)
        }

        elapsedTime = max(elapsedTime, nowElapsed)

        // Flush any throttled `.changed` sample if the user paused mid-drag past `minimumSampleInterval`
        if !pendingSamplesByWindow.isEmpty {
            var didFlush = false
            let keys = Array(pendingSamplesByWindow.keys)
            for windowID in keys {
                guard let pending = pendingSamplesByWindow[windowID] else { continue }
                let lastTime = lastSampledTimeByWindow[windowID] ?? 0.0
                if nowElapsed - lastTime >= samplingConfiguration.minimumSampleInterval {
                    pendingSamplesByWindow.removeValue(forKey: windowID)
                    commitPendingSample(pending)
                    didFlush = true
                }
            }
            if didFlush {
                publishLiveSession(durationOverride: elapsedTime)
            }
        }

        // Detect direct accent swatch changes made on live windows outside CanvasStateUpdate
        if let canvasState {
            var didSyncAccent = false
            for window in canvasState.windows {
                guard let idx = trackIndexByWindowID[window.id],
                      let lastKF = tracks[idx].keyframes.last,
                      lastKF.isPresent,
                      lastKF.accent != window.accent else {
                    continue
                }
                tracks[idx].accent = window.accent
                appendKeyframe(
                    WindowKeyframe(
                        time: nowElapsed,
                        frame: window.frame,
                        zIndex: window.zIndex,
                        presentationState: window.presentationState,
                        isFocused: canvasState.activeWindowID == window.id && !window.isMinimized,
                        isPresent: true,
                        accent: window.accent,
                        eventKind: .presentationChanged
                    ),
                    toTrackAt: idx
                )
                didSyncAccent = true
            }
            if didSyncAccent {
                lastRecordedTime = max(lastRecordedTime, nowElapsed)
                publishLiveSession(durationOverride: elapsedTime)
            }
        }
    }

    /// Directly ingests a `CanvasStateUpdate` (used by the stream listener and deterministic high-speed unit tests).
    func recordUpdate(
        _ update: CanvasStateUpdate,
        overrideElapsedSeconds: Double? = nil
    ) {
        guard isRecording else { return }
        if update.sequenceNumber > lastProcessedSequenceNumber {
            lastProcessedSequenceNumber = update.sequenceNumber
        }
        ingestUpdate(update, overrideElapsedSeconds: overrideElapsedSeconds)
    }

    // MARK: - Internal Normalization & Sampling Pipeline

    private func consumeStreamUpdate(_ update: CanvasStateUpdate) {
        guard update.sequenceNumber > lastProcessedSequenceNumber else { return }
        lastProcessedSequenceNumber = update.sequenceNumber
        ingestUpdate(update, overrideElapsedSeconds: nil)
    }

    private func ingestUpdate(
        _ update: CanvasStateUpdate,
        overrideElapsedSeconds: Double?
    ) {
        rawEventsReceived += 1

        let timestamp: Double
        if let overrideElapsedSeconds {
            timestamp = max(lastRecordedTime, overrideElapsedSeconds)
        } else {
            let relativeCanvasTime = update.elapsedSeconds - recordingOriginCanvasElapsed
            if relativeCanvasTime >= lastRecordedTime && relativeCanvasTime >= 0 {
                timestamp = relativeCanvasTime
            } else {
                timestamp = max(
                    lastRecordedTime,
                    ProcessInfo.processInfo.systemUptime - recordingOriginUptime
                )
            }
        }

        lastRecordedTime = timestamp
        elapsedTime = max(elapsedTime, timestamp)

        let snapshotsByID = Dictionary(
            uniqueKeysWithValues: update.windowsSnapshot.map { ($0.windowID, $0) }
        )
        let activeID = resolveActiveWindowID(
            from: update.windowsSnapshot,
            action: update.action
        )

        switch update.action {
        case let .windowMoved(windowID, _, _, _, phase):
            guard let snap = snapshotsByID[windowID] else { break }
            handleContinuousTransform(
                snapshot: snap,
                phase: phase,
                isResize: false,
                timestamp: timestamp,
                activeWindowID: activeID,
                allSnapshots: update.windowsSnapshot,
                action: update.action
            )

        case let .windowResized(windowID, _, _, _, _, phase):
            guard let snap = snapshotsByID[windowID] else { break }
            handleContinuousTransform(
                snapshot: snap,
                phase: phase,
                isResize: true,
                timestamp: timestamp,
                activeWindowID: activeID,
                allSnapshots: update.windowsSnapshot,
                action: update.action
            )

        case let .windowFocused(windowID, _, _):
            flushPendingSample(for: windowID)
            syncDiscreteFocusAndZOrder(
                primaryWindowID: windowID,
                allSnapshots: update.windowsSnapshot,
                activeWindowID: activeID,
                timestamp: timestamp
            )
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: update.action,
                    activeWindowID: activeID
                )
            )

        case let .windowPresentationChanged(windowID, _, newState, newFrame):
            flushPendingSample(for: windowID)
            if let snap = snapshotsByID[windowID] {
                let trackIdx = ensureTrackIndex(for: snap, at: timestamp)
                trimSyntheticFutureKeyframes(inTrackAt: trackIdx, after: timestamp)

                if let previous = tracks[trackIdx].keyframes.last, previous.frame != newFrame {
                    if timestamp - previous.time > 0.005 {
                        appendKeyframe(
                            WindowKeyframe(
                                time: timestamp,
                                frame: previous.frame,
                                zIndex: previous.zIndex,
                                presentationState: previous.presentationState,
                                isFocused: previous.isFocused,
                                isPresent: true,
                                accent: previous.accent,
                                eventKind: .hold
                            ),
                            toTrackAt: trackIdx
                        )
                    }
                    let targetTime = timestamp + max(0.0, samplingConfiguration.discreteTransitionDuration)
                    appendKeyframe(
                        WindowKeyframe(
                            time: targetTime,
                            frame: newFrame,
                            zIndex: snap.zIndex,
                            presentationState: newState,
                            isFocused: activeID == windowID && newState != .minimized,
                            isPresent: true,
                            accent: snap.accent,
                            eventKind: .presentationChanged
                        ),
                        toTrackAt: trackIdx
                    )
                    lastSampledTimeByWindow[windowID] = targetTime
                    lastSampledFrameByWindow[windowID] = newFrame
                } else {
                    appendKeyframe(
                        WindowKeyframe(
                            time: timestamp,
                            frame: newFrame,
                            zIndex: snap.zIndex,
                            presentationState: newState,
                            isFocused: activeID == windowID && newState != .minimized,
                            isPresent: true,
                            accent: snap.accent,
                            eventKind: .presentationChanged
                        ),
                        toTrackAt: trackIdx
                    )
                    lastSampledTimeByWindow[windowID] = timestamp
                    lastSampledFrameByWindow[windowID] = newFrame
                }
            }
            syncSecondaryFocusChanges(
                excluding: windowID,
                allSnapshots: update.windowsSnapshot,
                activeWindowID: activeID,
                timestamp: timestamp
            )
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: update.action,
                    activeWindowID: activeID
                )
            )

        case let .windowAdded(windowID, _, _, _):
            if let snap = snapshotsByID[windowID] {
                let trackIdx = ensureTrackIndex(
                    for: snap,
                    at: timestamp,
                    spawnedMidSession: timestamp > 0.001
                )
                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: snap.frame,
                        zIndex: snap.zIndex,
                        presentationState: snap.presentationState,
                        isFocused: activeID == windowID,
                        isPresent: true,
                        accent: snap.accent,
                        eventKind: .spawned
                    ),
                    toTrackAt: trackIdx
                )
                lastSampledTimeByWindow[windowID] = timestamp
                lastSampledFrameByWindow[windowID] = snap.frame
            }
            syncSecondaryFocusChanges(
                excluding: windowID,
                allSnapshots: update.windowsSnapshot,
                activeWindowID: activeID,
                timestamp: timestamp
            )
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: update.action,
                    activeWindowID: activeID
                )
            )

        case let .windowClosed(windowID, _):
            pendingSamplesByWindow.removeValue(forKey: windowID)
            if let trackIdx = trackIndexByWindowID[windowID] {
                trimSyntheticFutureKeyframes(inTrackAt: trackIdx, after: timestamp)
                let fallbackFrame = tracks[trackIdx].keyframes.last?.frame
                    ?? WindowFrame(x: 100, y: 100, width: 400, height: 300)
                let fallbackZ = tracks[trackIdx].keyframes.last?.zIndex ?? 1
                let fallbackState = tracks[trackIdx].keyframes.last?.presentationState ?? .normal
                let fallbackAccent = tracks[trackIdx].keyframes.last?.accent ?? tracks[trackIdx].accent

                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: fallbackFrame,
                        zIndex: fallbackZ,
                        presentationState: fallbackState,
                        isFocused: false,
                        isPresent: false,
                        accent: fallbackAccent,
                        eventKind: .closed
                    ),
                    toTrackAt: trackIdx
                )
            }
            syncSecondaryFocusChanges(
                excluding: windowID,
                allSnapshots: update.windowsSnapshot,
                activeWindowID: activeID,
                timestamp: timestamp
            )
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: update.action,
                    activeWindowID: activeID
                )
            )

        case .workspaceReset:
            pendingSamplesByWindow.removeAll()
            let activeSnapshotIDs = Set(update.windowsSnapshot.map(\.windowID))

            // Close any previously open tracks not present in the reset scene
            for idx in tracks.indices where !activeSnapshotIDs.contains(tracks[idx].windowID) {
                if let last = tracks[idx].keyframes.last, last.isPresent {
                    trimSyntheticFutureKeyframes(inTrackAt: idx, after: timestamp)
                    appendKeyframe(
                        WindowKeyframe(
                            time: timestamp,
                            frame: last.frame,
                            zIndex: last.zIndex,
                            presentationState: last.presentationState,
                            isFocused: false,
                            isPresent: false,
                            accent: last.accent,
                            eventKind: .closed
                        ),
                        toTrackAt: idx
                    )
                }
            }

            // Spawn or update tracks for the reset windows
            for snap in update.windowsSnapshot {
                let trackIdx = ensureTrackIndex(
                    for: snap,
                    at: timestamp,
                    spawnedMidSession: timestamp > 0.001
                )
                let kind: KeyframeEventKind = timestamp > 0.001 ? .spawned : .initial
                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: snap.frame,
                        zIndex: snap.zIndex,
                        presentationState: snap.presentationState,
                        isFocused: activeID == snap.windowID,
                        isPresent: true,
                        accent: snap.accent,
                        eventKind: kind
                    ),
                    toTrackAt: trackIdx
                )
                lastSampledTimeByWindow[snap.windowID] = timestamp
                lastSampledFrameByWindow[snap.windowID] = snap.frame
            }

            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: update.action,
                    activeWindowID: activeID
                )
            )
        }

        let maxTrackTime = tracks.flatMap(\.keyframes).map(\.time).max() ?? 0.0
        publishLiveSession(durationOverride: max(elapsedTime, maxTrackTime))
    }

    private func handleContinuousTransform(
        snapshot: WindowKeyframeSnapshot,
        phase: InteractionPhase,
        isResize: Bool,
        timestamp: Double,
        activeWindowID: UUID?,
        allSnapshots: [WindowKeyframeSnapshot],
        action: CanvasMutationAction
    ) {
        let windowID = snapshot.windowID
        let trackIdx = ensureTrackIndex(for: snapshot, at: timestamp)
        trimSyntheticFutureKeyframes(inTrackAt: trackIdx, after: timestamp)

        switch phase {
        case .began:
            pendingSamplesByWindow.removeValue(forKey: windowID)
            let kind: KeyframeEventKind = isResize ? .resizeBegan : .moveBegan
            appendKeyframe(
                WindowKeyframe(
                    time: timestamp,
                    frame: snapshot.frame,
                    zIndex: snapshot.zIndex,
                    presentationState: snapshot.presentationState,
                    isFocused: activeWindowID == windowID,
                    isPresent: true,
                    accent: snapshot.accent,
                    eventKind: kind
                ),
                toTrackAt: trackIdx
            )
            lastSampledTimeByWindow[windowID] = timestamp
            lastSampledFrameByWindow[windowID] = snapshot.frame
            syncSecondaryFocusChanges(
                excluding: windowID,
                allSnapshots: allSnapshots,
                activeWindowID: activeWindowID,
                timestamp: timestamp
            )
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: action,
                    activeWindowID: activeWindowID
                )
            )

        case .changed:
            let lastTime = lastSampledTimeByWindow[windowID] ?? -.greatestFiniteMagnitude
            let lastFrame = lastSampledFrameByWindow[windowID] ?? snapshot.frame
            let dt = timestamp - lastTime

            let posDelta = Darwin.hypot(
                snapshot.frame.origin.x - lastFrame.origin.x,
                snapshot.frame.origin.y - lastFrame.origin.y
            )
            let sizeDelta = Darwin.hypot(
                snapshot.frame.size.width - lastFrame.size.width,
                snapshot.frame.size.height - lastFrame.size.height
            )

            let exceedsSpatialDelta = isResize
                ? (posDelta >= samplingConfiguration.minimumPositionDelta || sizeDelta >= samplingConfiguration.minimumSizeDelta)
                : (posDelta >= samplingConfiguration.minimumPositionDelta)

            guard exceedsSpatialDelta else { return }

            let sampleKind: KeyframeEventKind = isResize ? .resizeSample : .moveSample
            if dt >= samplingConfiguration.minimumSampleInterval {
                pendingSamplesByWindow.removeValue(forKey: windowID)
                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: snapshot.frame,
                        zIndex: snapshot.zIndex,
                        presentationState: snapshot.presentationState,
                        isFocused: activeWindowID == windowID,
                        isPresent: true,
                        accent: snapshot.accent,
                        eventKind: sampleKind
                    ),
                    toTrackAt: trackIdx
                )
                lastSampledTimeByWindow[windowID] = timestamp
                lastSampledFrameByWindow[windowID] = snapshot.frame
            } else {
                // Buffer the latest sub-interval sample in case the user holds still mid-gesture
                pendingSamplesByWindow[windowID] = PendingGestureSample(
                    time: timestamp,
                    snapshot: snapshot,
                    kind: sampleKind,
                    activeWindowID: activeWindowID
                )
            }

        case .ended, .discrete:
            pendingSamplesByWindow.removeValue(forKey: windowID)
            let endKind: KeyframeEventKind = isResize ? .resizeEnded : .moveEnded

            // Replace a micro-adjacent `.moveSample` / `.resizeSample` (< 3ms old) to avoid duplicate-time clutter,
            // while strictly preserving `.moveBegan` / `.resizeBegan` landmarks.
            if let lastKF = tracks[trackIdx].keyframes.last,
               lastKF.eventKind.isContinuousSample,
               timestamp - lastKF.time < 0.003 {
                tracks[trackIdx].keyframes.removeLast()
            }

            appendKeyframe(
                WindowKeyframe(
                    time: timestamp,
                    frame: snapshot.frame,
                    zIndex: snapshot.zIndex,
                    presentationState: snapshot.presentationState,
                    isFocused: activeWindowID == windowID,
                    isPresent: true,
                    accent: snapshot.accent,
                    eventKind: endKind
                ),
                toTrackAt: trackIdx
            )
            lastSampledTimeByWindow[windowID] = timestamp
            lastSampledFrameByWindow[windowID] = snapshot.frame
            recordedEvents.append(
                RecordedInteractionEvent(
                    time: timestamp,
                    action: action,
                    activeWindowID: activeWindowID
                )
            )
        }
    }

    // MARK: - Track Management & Helpers

    private func ensureTrackIndex(
        for snapshot: WindowKeyframeSnapshot,
        at timestamp: Double,
        spawnedMidSession: Bool = true
    ) -> Int {
        if let existing = trackIndexByWindowID[snapshot.windowID] {
            return existing
        }

        let liveWindow = canvasState?.windows.first(where: { $0.id == snapshot.windowID })
        let content = liveWindow?.content ?? Self.fallbackContent(for: snapshot)
        let minSize = liveWindow?.minimumSize ?? content.recommendedMinimumSize

        let newTrack = WindowTimelineTrack(
            windowID: snapshot.windowID,
            title: snapshot.title,
            contentKind: snapshot.contentKind,
            initialContent: content,
            minimumSize: minSize,
            accent: snapshot.accent,
            wasSpawnedDuringSession: spawnedMidSession && timestamp > 0.001,
            keyframes: []
        )
        let newIdx = tracks.count
        trackIndexByWindowID[snapshot.windowID] = newIdx
        tracks.append(newTrack)
        return newIdx
    }

    private func appendKeyframe(_ keyframe: WindowKeyframe, toTrackAt index: Int) {
        tracks[index].accent = keyframe.accent
        if let last = tracks[index].keyframes.last, keyframe.time < last.time {
            tracks[index].keyframes.append(keyframe)
            tracks[index].keyframes.sort { $0.time < $1.time }
        } else {
            tracks[index].keyframes.append(keyframe)
        }
    }

    /// If a track has synthetic future transition keyframes (e.g. a Maximize spring finishing at `t + 0.24s`)
    /// and a new user interaction arrives earlier at `cutoffTime`, resolve the interpolated frame at `cutoffTime`
    /// and prune the unreached future keyframes.
    private func trimSyntheticFutureKeyframes(inTrackAt index: Int, after cutoffTime: Double) {
        guard let last = tracks[index].keyframes.last, last.time > cutoffTime + 0.000_1 else {
            return
        }
        let evaluated = KeyframeInterpolator.evaluateTrack(
            tracks[index],
            at: cutoffTime,
            curve: .easeInOut
        )
        tracks[index].keyframes.removeAll { $0.time > cutoffTime }
        if let evaluated {
            appendKeyframe(
                WindowKeyframe(
                    time: cutoffTime,
                    frame: evaluated.frame,
                    zIndex: evaluated.zIndex,
                    presentationState: evaluated.presentationState,
                    isFocused: evaluated.isFocused,
                    isPresent: true,
                    accent: evaluated.accent,
                    eventKind: .hold
                ),
                toTrackAt: index
            )
            lastSampledTimeByWindow[tracks[index].windowID] = cutoffTime
            lastSampledFrameByWindow[tracks[index].windowID] = evaluated.frame
        }
    }

    private func syncDiscreteFocusAndZOrder(
        primaryWindowID: UUID,
        allSnapshots: [WindowKeyframeSnapshot],
        activeWindowID: UUID?,
        timestamp: Double
    ) {
        for snap in allSnapshots {
            let trackIdx = ensureTrackIndex(for: snap, at: timestamp)
            let isNowFocused = (activeWindowID == snap.windowID) && (snap.presentationState != .minimized)

            if snap.windowID == primaryWindowID {
                trimSyntheticFutureKeyframes(inTrackAt: trackIdx, after: timestamp)
                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: snap.frame,
                        zIndex: snap.zIndex,
                        presentationState: snap.presentationState,
                        isFocused: isNowFocused,
                        isPresent: true,
                        accent: snap.accent,
                        eventKind: .focused
                    ),
                    toTrackAt: trackIdx
                )
            } else if let last = tracks[trackIdx].keyframes.last,
                      last.isPresent,
                      (last.isFocused != isNowFocused || last.zIndex != snap.zIndex || last.presentationState != snap.presentationState) {
                // Only touch non-future keyframes so ongoing transitions aren't disturbed unnecessarily
                if last.time <= timestamp {
                    appendKeyframe(
                        WindowKeyframe(
                            time: timestamp,
                            frame: last.frame,
                            zIndex: snap.zIndex,
                            presentationState: snap.presentationState,
                            isFocused: isNowFocused,
                            isPresent: true,
                            accent: snap.accent,
                            eventKind: .hold
                        ),
                        toTrackAt: trackIdx
                    )
                }
            }
        }
    }

    private func syncSecondaryFocusChanges(
        excluding excludedWindowID: UUID,
        allSnapshots: [WindowKeyframeSnapshot],
        activeWindowID: UUID?,
        timestamp: Double
    ) {
        for snap in allSnapshots where snap.windowID != excludedWindowID {
            guard let trackIdx = trackIndexByWindowID[snap.windowID],
                  let last = tracks[trackIdx].keyframes.last,
                  last.isPresent,
                  last.time <= timestamp else {
                continue
            }
            let shouldFocus = (activeWindowID == snap.windowID) && (snap.presentationState != .minimized)
            if last.isFocused != shouldFocus || last.zIndex != snap.zIndex {
                appendKeyframe(
                    WindowKeyframe(
                        time: timestamp,
                        frame: last.frame,
                        zIndex: snap.zIndex,
                        presentationState: snap.presentationState,
                        isFocused: shouldFocus,
                        isPresent: true,
                        accent: snap.accent,
                        eventKind: .hold
                    ),
                    toTrackAt: trackIdx
                )
            }
        }
    }

    private func flushPendingSample(for windowID: UUID) {
        guard let pending = pendingSamplesByWindow.removeValue(forKey: windowID) else { return }
        commitPendingSample(pending)
    }

    private func flushAllPendingSamples() {
        let pendingValues = pendingSamplesByWindow.values.sorted { $0.time < $1.time }
        pendingSamplesByWindow.removeAll()
        for pending in pendingValues {
            commitPendingSample(pending)
        }
    }

    private func commitPendingSample(_ pending: PendingGestureSample) {
        let windowID = pending.snapshot.windowID
        let trackIdx = ensureTrackIndex(for: pending.snapshot, at: pending.time)
        appendKeyframe(
            WindowKeyframe(
                time: pending.time,
                frame: pending.snapshot.frame,
                zIndex: pending.snapshot.zIndex,
                presentationState: pending.snapshot.presentationState,
                isFocused: pending.activeWindowID == windowID,
                isPresent: true,
                accent: pending.snapshot.accent,
                eventKind: pending.kind
            ),
            toTrackAt: trackIdx
        )
        lastSampledTimeByWindow[windowID] = pending.time
        lastSampledFrameByWindow[windowID] = pending.snapshot.frame
    }

    private func resolveActiveWindowID(
        from snapshots: [WindowKeyframeSnapshot],
        action: CanvasMutationAction
    ) -> UUID? {
        let visible = snapshots.filter { $0.presentationState != .minimized }
        switch action {
        case let .windowMoved(id, _, _, _, _),
             let .windowResized(id, _, _, _, _, _),
             let .windowFocused(id, _, _),
             let .windowAdded(id, _, _, _):
            if visible.contains(where: { $0.windowID == id }) {
                return id
            }
        case let .windowPresentationChanged(id, _, state, _):
            if state != .minimized, visible.contains(where: { $0.windowID == id }) {
                return id
            }
        case .windowClosed, .workspaceReset:
            break
        }
        return visible.max(by: { $0.zIndex < $1.zIndex })?.windowID
    }

    private func publishLiveSession(durationOverride: Double) {
        let totalKF = tracks.reduce(0) { $0 + $1.keyframes.count }
        keyframesRecorded = totalKF
        latestSession = RecordedSession(
            id: sessionID,
            createdAt: sessionCreatedAt,
            duration: max(0.0, durationOverride),
            wallpaper: canvasState?.wallpaper ?? initialWallpaper,
            canvasSize: canvasState?.canvasBounds ?? initialCanvasSize,
            initialActiveWindowID: initialActiveWindowID,
            tracks: tracks,
            events: recordedEvents,
            rawEventCount: rawEventsReceived
        )
    }

    private static func fallbackContent(for snapshot: WindowKeyframeSnapshot) -> WindowContent {
        switch snapshot.contentKind {
        case .video: .demoVideo
        case .codeSnippet: .demoCodeSnippet
        case .browser: .demoBrowser
        case .image: .demoImage
        }
    }
}
