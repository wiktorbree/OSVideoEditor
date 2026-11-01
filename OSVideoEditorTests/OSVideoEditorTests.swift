//
//  OSVideoEditorTests.swift
//  OSVideoEditorTests
//
//  Unit tests verifying Milestone 1 domain models, dynamic z-index stacking,
//  zero-drift 4-corner resize geometry, and timestamped state-capture emissions.
//

import CoreGraphics
import Foundation
import Testing
@testable import OSVideoEditor

@MainActor
struct ScreenPlayCanvasTests {

    @Test("Clicking a background window elevates its z-index to foreground and emits focus event")
    func dynamicZIndexManagement() {
        var captured: [CanvasStateUpdate] = []
        let state = CanvasState { update in
            captured.append(update)
        }

        let sortedInitial = state.windows.sorted(by: { $0.zIndex < $1.zIndex })
        #expect(sortedInitial.count == 3)

        let backmostWindow = sortedInitial[0]
        let previousTopZ = sortedInitial[2].zIndex

        state.bringToFront(backmostWindow.id)

        #expect(state.activeWindowID == backmostWindow.id)
        #expect(backmostWindow.zIndex > previousTopZ)
        #expect(captured.count == 1)

        if case let .windowFocused(focusedID, _, emittedZ) = captured[0].action {
            #expect(focusedID == backmostWindow.id)
            #expect(emittedZ == backmostWindow.zIndex)
        } else {
            Issue.record("Expected .windowFocused mutation action")
        }

        // Clicking an already-focused topmost window should not emit redundant focus updates
        state.bringToFront(backmostWindow.id)
        #expect(captured.count == 1)
    }

    @Test("Top-leading corner resize strictly pins bottom-trailing edges even past minimum size")
    func topLeadingResizePinsOppositeCorner() {
        let initial = WindowFrame(x: 200, y: 180, width: 400, height: 300)
        let minSize = CGSize(width: 280, height: 220)

        // Drag inward by (+250, +200), exceeding minimum size thresholds
        let clamped = initial.applyingResize(
            corner: .topLeading,
            translation: CGSize(width: 250, height: 200),
            minimumSize: minSize
        )

        #expect(clamped.size == minSize)
        #expect(clamped.maxX == initial.maxX)
        #expect(clamped.maxY == initial.maxY)
        #expect(clamped.origin.x == initial.maxX - minSize.width)
        #expect(clamped.origin.y == initial.maxY - minSize.height)
    }

    @Test("All four corners resize accurately in outward expansion")
    func fourCornerExpansionGeometry() {
        let base = WindowFrame(x: 300, y: 200, width: 400, height: 300)

        let br = base.applyingResize(corner: .bottomTrailing, translation: CGSize(width: 50, height: 40))
        #expect(br == WindowFrame(x: 300, y: 200, width: 450, height: 340))

        let tr = base.applyingResize(corner: .topTrailing, translation: CGSize(width: 60, height: -30))
        #expect(tr == WindowFrame(x: 300, y: 170, width: 460, height: 330))

        let bl = base.applyingResize(corner: .bottomLeading, translation: CGSize(width: -40, height: 50))
        #expect(bl == WindowFrame(x: 260, y: 200, width: 440, height: 350))
    }

    @Test("Move and resize gestures emit monotonic timestamped updates across began/changed/ended phases")
    func stateCaptureHookEmissions() {
        let state = CanvasState()
        state.canvasBounds = CGSize(width: 1400, height: 900)

        var sinkEvents: [CanvasStateUpdate] = []
        let token = state.addCaptureSink { event in
            sinkEvents.append(event)
        }
        defer { state.removeCaptureSink(token) }

        let target = state.windows[0]
        let anchor = target.frame

        state.recordMove(windowID: target.id, startFrame: anchor, translation: .zero, phase: .began)
        state.recordMove(windowID: target.id, startFrame: anchor, translation: CGSize(width: 45, height: 30), phase: .changed)
        state.recordMove(windowID: target.id, startFrame: anchor, translation: CGSize(width: 80, height: 55), phase: .ended)

        let resizeAnchor = target.frame
        state.recordResize(windowID: target.id, corner: .bottomTrailing, startFrame: resizeAnchor, translation: .zero, phase: .began)
        state.recordResize(windowID: target.id, corner: .bottomTrailing, startFrame: resizeAnchor, translation: CGSize(width: 60, height: 40), phase: .changed)
        state.recordResize(windowID: target.id, corner: .bottomTrailing, startFrame: resizeAnchor, translation: CGSize(width: 60, height: 40), phase: .ended)

        #expect(sinkEvents.count == 6)
        #expect(state.totalCapturedEvents == 6)

        // Verify strictly increasing sequence numbers and non-decreasing monotonic timestamps
        for idx in 1..<sinkEvents.count {
            #expect(sinkEvents[idx].sequenceNumber == sinkEvents[idx - 1].sequenceNumber + 1)
            #expect(sinkEvents[idx].elapsedSeconds >= sinkEvents[idx - 1].elapsedSeconds)
            #expect(sinkEvents[idx].windowsSnapshot.count == 3)
        }

        #expect(target.frame.origin == CGPoint(x: anchor.origin.x + 80, y: anchor.origin.y + 55))
        #expect(target.frame.size == CGSize(width: anchor.size.width + 60, height: anchor.size.height + 40))
    }
}

// MARK: - Milestone 2: Session Recorder, Interpolation & Playback Engine Tests

@MainActor
struct ScreenPlayTimelineTests {

    @Test("SessionRecorder throttles 240Hz drag bursts to ~60Hz while preserving exact began and ended keyframes")
    func highFrequencyDragNormalization() {
        let canvas = CanvasState()
        canvas.canvasBounds = CGSize(width: 1400, height: 900)

        let recorder = SessionRecorder(
            samplingConfiguration: RecordingSamplingConfiguration(
                maxSampleRateHz: 60.0,
                minimumPositionDelta: 1.5,
                minimumSizeDelta: 1.5,
                discreteTransitionDuration: 0.20
            )
        )
        recorder.startRecording(canvasState: canvas)

        let target = canvas.windows[0]
        let startFrame = target.frame

        // Intercept emitted CanvasStateUpdates and feed synthetic 240Hz timestamps over 0.5 seconds (120 events)
        var latestEmitted: CanvasStateUpdate?
        let sinkToken = canvas.addCaptureSink { update in
            latestEmitted = update
        }
        defer { canvas.removeCaptureSink(sinkToken) }

        canvas.recordMove(windowID: target.id, startFrame: startFrame, translation: .zero, phase: .began)
        if let beganUpdate = latestEmitted {
            recorder.recordUpdate(beganUpdate, overrideElapsedSeconds: 0.100)
        }

        let totalChangedSteps = 120
        for step in 1...totalChangedSteps {
            let syntheticTime = 0.100 + Double(step) * (1.0 / 240.0)
            let dx = CGFloat(step) * 2.0
            let dy = CGFloat(step) * 1.0
            canvas.recordMove(
                windowID: target.id,
                startFrame: startFrame,
                translation: CGSize(width: dx, height: dy),
                phase: .changed
            )
            if let changedUpdate = latestEmitted {
                recorder.recordUpdate(changedUpdate, overrideElapsedSeconds: syntheticTime)
            }
        }

        let finalTranslation = CGSize(width: 260, height: 130)
        canvas.recordMove(
            windowID: target.id,
            startFrame: startFrame,
            translation: finalTranslation,
            phase: .ended
        )
        if let endedUpdate = latestEmitted {
            recorder.recordUpdate(endedUpdate, overrideElapsedSeconds: 0.610)
        }

        let session = recorder.stopRecording()
        #expect(session != nil)
        guard let session,
              let track = session.tracks.first(where: { $0.windowID == target.id }) else {
            Issue.record("Missing recorded track for moved window")
            return
        }

        // 122 raw updates must be throttled down to ~31-34 clean keyframes (initial + began + ~30 samples + ended)
        #expect(session.rawEventCount == 122)
        #expect(track.keyframes.count >= 25 && track.keyframes.count <= 36)
        #expect(track.keyframes.contains(where: { $0.eventKind == .moveBegan }))
        #expect(track.keyframes.last?.eventKind == .moveEnded)
        #expect(track.keyframes.last?.frame.origin == CGPoint(x: startFrame.origin.x + 260, y: startFrame.origin.y + 130))
    }

    @Test("PlaybackEngine deterministically interpolates WindowFrame across Linear, Ease-In-Out Bezier, and Spring curves")
    func windowFrameCurveInterpolation() {
        let canvas = CanvasState()
        let window = canvas.windows[0]

        let frameA = WindowFrame(x: 100, y: 120, width: 400, height: 300)
        let frameB = WindowFrame(x: 300, y: 220, width: 600, height: 400)

        let track = WindowTimelineTrack(
            windowID: window.id,
            title: window.title,
            contentKind: window.content.kind,
            initialContent: window.content,
            minimumSize: window.minimumSize,
            accent: window.accent,
            keyframes: [
                WindowKeyframe(
                    time: 0.0,
                    frame: frameA,
                    zIndex: 1,
                    presentationState: .normal,
                    isFocused: true,
                    accent: window.accent,
                    eventKind: .initial
                ),
                WindowKeyframe(
                    time: 2.0,
                    frame: frameB,
                    zIndex: 1,
                    presentationState: .normal,
                    isFocused: true,
                    accent: window.accent,
                    eventKind: .moveEnded
                )
            ]
        )

        let session = RecordedSession(
            duration: 2.0,
            wallpaper: .pastelSunrise,
            initialActiveWindowID: window.id,
            tracks: [track]
        )

        let engine = PlaybackEngine(canvasState: canvas)
        engine.interpolationCurve = .linear
        engine.loadSession(session, canvasState: canvas, seekTo: 0.0)
        #expect(canvas.windows.first?.frame == frameA)

        // Midpoint t = 1.0 (u = 0.5) under Linear must be exact arithmetic midpoint
        let eventsBeforeScrub = canvas.totalCapturedEvents
        engine.seek(to: 1.0)
        #expect(canvas.windows.first?.frame == WindowFrame(x: 200, y: 170, width: 500, height: 350))
        // Scrubbing must never echo bogus capture events back into CanvasState
        #expect(canvas.totalCapturedEvents == eventsBeforeScrub)

        // Quarter point t = 0.5 (u = 0.25): Ease-In-Out Bezier eases in slower than Linear
        engine.interpolationCurve = .easeInOut
        engine.seek(to: 0.5)
        let bezierQuarterX = canvas.windows.first?.frame.origin.x ?? 0
        #expect(bezierQuarterX > 100 && bezierQuarterX < 150)

        // Spring curve produces characteristic overshoot (> 300) near peak bounce and settles to exact endpoint at t = 2.0
        engine.interpolationCurve = .spring
        engine.seek(to: 0.72) // u = 0.36
        let springBounceX = canvas.windows.first?.frame.origin.x ?? 0
        #expect(springBounceX > 300)

        engine.seek(to: 2.0)
        #expect(canvas.windows.first?.frame == frameB)
    }

    @Test("PlaybackEngine applies discrete Z-index, minimize state, focus, and spawn/close transitions deterministically")
    func discreteStateTransitionsDuringScrubbing() {
        let canvas = CanvasState()
        let winA = canvas.windows[0]
        let winB = canvas.windows[1]
        let spawnedID = UUID()

        let trackA = WindowTimelineTrack(
            windowID: winA.id,
            title: winA.title,
            contentKind: winA.content.kind,
            initialContent: winA.content,
            minimumSize: winA.minimumSize,
            accent: winA.accent,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: winA.frame, zIndex: 1, presentationState: .normal, isFocused: false, accent: winA.accent, eventKind: .initial),
                WindowKeyframe(time: 1.0, frame: winA.frame, zIndex: 5, presentationState: .normal, isFocused: true, accent: winA.accent, eventKind: .focused),
                WindowKeyframe(time: 2.0, frame: winA.frame, zIndex: 5, presentationState: .minimized, isFocused: false, accent: winA.accent, eventKind: .presentationChanged)
            ]
        )

        let trackB = WindowTimelineTrack(
            windowID: winB.id,
            title: winB.title,
            contentKind: winB.content.kind,
            initialContent: winB.content,
            minimumSize: winB.minimumSize,
            accent: winB.accent,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: winB.frame, zIndex: 2, presentationState: .normal, isFocused: true, accent: winB.accent, eventKind: .initial),
                WindowKeyframe(time: 1.0, frame: winB.frame, zIndex: 2, presentationState: .normal, isFocused: false, accent: winB.accent, eventKind: .hold),
                WindowKeyframe(time: 2.0, frame: winB.frame, zIndex: 2, presentationState: .normal, isFocused: true, accent: winB.accent, eventKind: .focused),
                WindowKeyframe(time: 3.0, frame: winB.frame, zIndex: 2, presentationState: .normal, isFocused: false, isPresent: false, accent: winB.accent, eventKind: .closed)
            ]
        )

        let trackSpawned = WindowTimelineTrack(
            windowID: spawnedID,
            title: "Clip_Take_02.mov",
            contentKind: .video,
            initialContent: .demoVideo,
            minimumSize: CGSize(width: 340, height: 250),
            accent: .coralBlush,
            wasSpawnedDuringSession: true,
            keyframes: [
                WindowKeyframe(
                    time: 1.5,
                    frame: WindowFrame(x: 160, y: 110, width: 470, height: 330),
                    zIndex: 6,
                    presentationState: .normal,
                    isFocused: true,
                    isPresent: true,
                    accent: .coralBlush,
                    eventKind: .spawned
                )
            ]
        )

        let session = RecordedSession(
            duration: 3.5,
            wallpaper: .mintStudio,
            initialActiveWindowID: winB.id,
            tracks: [trackA, trackB, trackSpawned]
        )

        let engine = PlaybackEngine(canvasState: canvas)
        engine.loadSession(session, canvasState: canvas, seekTo: 0.5)

        // At t = 0.5: winA (z:1) & winB (z:2, focused), spawned window does not exist yet
        #expect(canvas.windows.count == 2)
        #expect(canvas.activeWindowID == winB.id)
        #expect(canvas.windows.first(where: { $0.id == winA.id })?.zIndex == 1)

        // At t = 1.2: winA jumped discretely to z:5 and took focus; spawned window still absent (< 1.5s)
        engine.seek(to: 1.2)
        #expect(canvas.windows.count == 2)
        #expect(canvas.activeWindowID == winA.id)
        #expect(canvas.windows.first(where: { $0.id == winA.id })?.zIndex == 5)

        // At t = 2.2: winA is minimized, spawned window exists (z:6)
        engine.seek(to: 2.2)
        #expect(canvas.windows.count == 3)
        #expect(canvas.windows.first(where: { $0.id == winA.id })?.isMinimized == true)
        #expect(canvas.windows.contains(where: { $0.id == spawnedID }))

        // At t = 3.2: winB closed -> removed from canvas; scrubbing backward to t = 0.5 restores winB!
        engine.seek(to: 3.2)
        #expect(!canvas.windows.contains(where: { $0.id == winB.id }))

        engine.seek(to: 0.5)
        #expect(canvas.windows.contains(where: { $0.id == winB.id }))
        #expect(!canvas.windows.contains(where: { $0.id == spawnedID }))
    }
}
