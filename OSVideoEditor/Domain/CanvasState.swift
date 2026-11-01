//
//  CanvasState.swift
//  OSVideoEditor
//
//  Central observable state store for the ScreenPlay OS desktop canvas, z-index manager,
//  and timestamped state capture emitter for the upcoming recording/timeline engine.
//

import CoreGraphics
import Foundation
import Observation
import SwiftUI

@Observable
final class CanvasState {
    // MARK: - Desktop Domain State

    private(set) var windows: [DesktopWindow] = []
    private(set) var activeWindowID: UUID?
    var canvasBounds: CGSize = CGSize(width: 1280, height: 760)
    var wallpaper: CartoonWallpaper = .pastelSunrise

    // MARK: - State Capture Telemetry & Hooks

    /// Direct low-latency callback hook invoked synchronously on every state mutation.
    @ObservationIgnored
    var onStateCaptured: ((CanvasStateUpdate) -> Void)?

    private(set) var latestUpdate: CanvasStateUpdate?
    private(set) var recentUpdates: [CanvasStateUpdate] = []
    private(set) var totalCapturedEvents: UInt64 = 0

    // MARK: - Internal Bookkeeping

    @ObservationIgnored
    private var topZSeed: Double = 0
    @ObservationIgnored
    private var sequenceSeed: UInt64 = 0
    @ObservationIgnored
    private var captureClockOriginUptime: TimeInterval
    @ObservationIgnored
    private var captureSinks: [UUID: (CanvasStateUpdate) -> Void] = [:]
    @ObservationIgnored
    private var spawnedCountByKind: [WindowContent.Kind: Int] = [:]

    private let maxRecentHistoryCount = 80

    // MARK: - Initialization

    init(
        windows: [DesktopWindow]? = nil,
        wallpaper: CartoonWallpaper = .pastelSunrise,
        onStateCaptured: ((CanvasStateUpdate) -> Void)? = nil
    ) {
        self.wallpaper = wallpaper
        self.onStateCaptured = onStateCaptured
        self.captureClockOriginUptime = ProcessInfo.processInfo.systemUptime

        let initialWindows = windows ?? Self.makeDefaultWindows()
        self.windows = initialWindows
        self.topZSeed = initialWindows.map(\.zIndex).max() ?? 0
        self.activeWindowID = initialWindows.max(by: { $0.zIndex < $1.zIndex })?.id
    }

    // MARK: - Computed Queries

    var activeWindow: DesktopWindow? {
        guard let activeWindowID else { return nil }
        return windows.first(where: { $0.id == activeWindowID })
    }

    var visibleWindows: [DesktopWindow] {
        windows.filter { !$0.isMinimized }
    }

    var minimizedWindows: [DesktopWindow] {
        windows.filter(\.isMinimized)
    }

    // MARK: - Dynamic Z-Index Management

    /// Smoothly elevates `windowID` to the foreground z-index and marks it as the active desktop window.
    func bringToFront(_ windowID: UUID) {
        guard let target = windows.first(where: { $0.id == windowID }) else { return }

        let wasMinimized = target.isMinimized
        if wasMinimized {
            withAnimation(.spring(duration: 0.32, bounce: 0.22)) {
                target.isMinimized = false
            }
        }

        let currentMaxZ = windows.filter { !$0.isMinimized }.map(\.zIndex).max() ?? 0
        let isAlreadyTopAndActive = (activeWindowID == windowID) && (target.zIndex >= currentMaxZ) && !wasMinimized
        guard !isAlreadyTopAndActive else { return }

        withAnimation(.spring(duration: 0.26, bounce: 0.18)) {
            topZSeed += 1
            target.zIndex = topZSeed
            activeWindowID = windowID
            normalizeZIndicesIfNeeded()
        }

        emitUpdate(
            .windowFocused(
                windowID: target.id,
                windowTitle: target.title,
                zIndex: target.zIndex
            )
        )
    }

    private func normalizeZIndicesIfNeeded() {
        guard topZSeed > 5_000 else { return }
        let ordered = windows.sorted(by: { $0.zIndex < $1.zIndex })
        for (index, item) in ordered.enumerated() {
            item.zIndex = Double(index + 1)
        }
        topZSeed = Double(ordered.count)
    }

    // MARK: - High-Performance Drag & Resize Mutations

    /// Applies a drag gesture update relative to `startFrame` without implicit animation lag and emits a timestamped state update.
    func recordMove(
        windowID: UUID,
        startFrame: WindowFrame,
        translation: CGSize,
        phase: InteractionPhase
    ) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }

        let previousOrigin = window.frame.origin
        let nextFrame = startFrame.applyingTranslation(
            translation,
            constrainedTo: canvasBounds,
            topSafeInset: CartoonTheme.virtualMenuBarHeight
        )

        if phase == .changed && nextFrame.origin == previousOrigin {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if window.isMaximized && nextFrame != window.frame {
                window.isMaximized = false
                window.restoreFrame = nil
            }
            window.frame = nextFrame
        }

        let originFrom = (phase == .ended) ? startFrame.origin : previousOrigin
        emitUpdate(
            .windowMoved(
                windowID: window.id,
                windowTitle: window.title,
                from: originFrom,
                to: nextFrame.origin,
                phase: phase
            )
        )
    }

    /// Applies a corner resize update relative to `startFrame` with pinned opposite edges and emits a timestamped state update.
    func recordResize(
        windowID: UUID,
        corner: ResizeCorner,
        startFrame: WindowFrame,
        translation: CGSize,
        phase: InteractionPhase
    ) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }

        let previousFrame = window.frame
        let nextFrame = startFrame.applyingResize(
            corner: corner,
            translation: translation,
            minimumSize: window.minimumSize,
            constrainedTo: canvasBounds,
            topSafeInset: CartoonTheme.virtualMenuBarHeight
        )

        if phase == .changed && nextFrame == previousFrame {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if window.isMaximized && nextFrame != window.frame {
                window.isMaximized = false
                window.restoreFrame = nil
            }
            window.frame = nextFrame
        }

        let frameFrom = (phase == .ended) ? startFrame : previousFrame
        emitUpdate(
            .windowResized(
                windowID: window.id,
                windowTitle: window.title,
                corner: corner,
                from: frameFrom,
                to: nextFrame,
                phase: phase
            )
        )
    }

    // MARK: - Window Controls (Traffic Lights & Spawning)

    func closeWindow(_ windowID: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        let removedTitle = windows[index].title

        withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
            windows.remove(at: index)
            if activeWindowID == windowID {
                activeWindowID = visibleWindows.max(by: { $0.zIndex < $1.zIndex })?.id
            }
        }

        emitUpdate(.windowClosed(windowID: windowID, windowTitle: removedTitle))
    }

    func toggleMinimize(_ windowID: UUID) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }

        withAnimation(.spring(duration: 0.32, bounce: 0.20)) {
            window.isMinimized.toggle()
            if window.isMinimized {
                if activeWindowID == windowID {
                    activeWindowID = visibleWindows.max(by: { $0.zIndex < $1.zIndex })?.id
                }
            } else {
                topZSeed += 1
                window.zIndex = topZSeed
                activeWindowID = window.id
            }
        }

        emitUpdate(
            .windowPresentationChanged(
                windowID: window.id,
                windowTitle: window.title,
                state: window.presentationState,
                frame: window.frame
            )
        )
    }

    func toggleMaximize(_ windowID: UUID) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        bringToFront(windowID)

        withAnimation(.spring(duration: 0.34, bounce: 0.20)) {
            if window.isMaximized, let savedFrame = window.restoreFrame {
                window.frame = savedFrame
                window.isMaximized = false
                window.restoreFrame = nil
            } else {
                window.restoreFrame = window.frame
                let horizontalInset: CGFloat = 24
                let topInset: CGFloat = CartoonTheme.virtualMenuBarHeight + 16
                let bottomDockReserve: CGFloat = 92
                let targetWidth = max(window.minimumSize.width, canvasBounds.width - horizontalInset * 2)
                let targetHeight = max(window.minimumSize.height, canvasBounds.height - topInset - bottomDockReserve)
                window.frame = WindowFrame(
                    x: horizontalInset,
                    y: topInset,
                    width: targetWidth,
                    height: targetHeight
                )
                window.isMaximized = true
            }
        }

        emitUpdate(
            .windowPresentationChanged(
                windowID: window.id,
                windowTitle: window.title,
                state: window.presentationState,
                frame: window.frame
            )
        )
    }

    func spawnWindow(of kind: WindowContent.Kind) {
        let nextIndex = (spawnedCountByKind[kind] ?? 0) + 1
        spawnedCountByKind[kind] = nextIndex

        let cascadeOffset = CGFloat((windows.count % 6) * 28)
        topZSeed += 1

        let newWindow: DesktopWindow
        switch kind {
        case .video:
            let scenes = CartoonVideoScene.allCases
            let scene = scenes[nextIndex % scenes.count]
            newWindow = DesktopWindow(
                title: "Clip_Take_0\(nextIndex + 1).mov",
                frame: WindowFrame(x: 110 + cascadeOffset, y: 74 + cascadeOffset, width: 470, height: 330),
                content: .video(
                    VideoWindowPayload(
                        clipTitle: "Clip_Take_0\(nextIndex + 1).mov",
                        resolutionTag: "4K UHD",
                        fps: 60,
                        durationSeconds: 36.0,
                        currentSeconds: 8.4,
                        isPlaying: false,
                        scene: scene
                    )
                ),
                zIndex: topZSeed,
                accent: .coralBlush
            )

        case .codeSnippet:
            newWindow = DesktopWindow(
                title: "KeyframeTrack_\(nextIndex).swift",
                frame: WindowFrame(x: 240 + cascadeOffset, y: 96 + cascadeOffset, width: 460, height: 310),
                content: .demoCodeSnippet,
                zIndex: topZSeed,
                accent: .mintMatcha
            )

        case .browser:
            newWindow = DesktopWindow(
                title: "ScreenPlay Docs",
                frame: WindowFrame(x: 180 + cascadeOffset, y: 82 + cascadeOffset, width: 520, height: 360),
                content: .demoBrowser,
                zIndex: topZSeed,
                accent: .skyPeriwinkle
            )

        case .image:
            let presets = CartoonImagePreset.allCases
            let preset = presets[nextIndex % presets.count]
            newWindow = DesktopWindow(
                title: "KeyArt_0\(nextIndex + 1).png",
                frame: WindowFrame(x: 210 + cascadeOffset, y: 90 + cascadeOffset, width: 430, height: 320),
                content: .image(
                    ImageWindowPayload(
                        assetName: "KeyArt_0\(nextIndex + 1).png",
                        caption: "ScreenPlay Studio Raster Asset • sRGB",
                        dimensionsTag: "2400 × 1600 PNG",
                        aspectFit: true,
                        preset: preset
                    )
                ),
                zIndex: topZSeed,
                accent: .lavenderPop
            )
        }

        withAnimation(.spring(duration: 0.32, bounce: 0.24)) {
            windows.append(newWindow)
            activeWindowID = newWindow.id
        }

        emitUpdate(
            .windowAdded(
                windowID: newWindow.id,
                windowTitle: newWindow.title,
                kind: kind,
                frame: newWindow.frame
            )
        )
    }

    func resetToDemoWorkspace() {
        let defaults = Self.makeDefaultWindows()
        withAnimation(.spring(duration: 0.36, bounce: 0.22)) {
            windows = defaults
            topZSeed = defaults.map(\.zIndex).max() ?? 0
            activeWindowID = defaults.max(by: { $0.zIndex < $1.zIndex })?.id
        }
        emitUpdate(.workspaceReset)
    }

    func updateContent(for windowID: UUID, transform: (inout WindowContent) -> Void) {
        guard let window = windows.first(where: { $0.id == windowID }) else { return }
        transform(&window.content)
    }

    // MARK: - State Capture Hook Registration

    /// Registers an external state-capture observer (e.g. Milestone 2's Timeline Recorder) and returns a token for removal.
    @discardableResult
    func addCaptureSink(_ sink: @escaping (CanvasStateUpdate) -> Void) -> UUID {
        let token = UUID()
        captureSinks[token] = sink
        return token
    }

    func removeCaptureSink(_ token: UUID) {
        captureSinks.removeValue(forKey: token)
    }

    /// Creates an `AsyncStream` of timestamped `CanvasStateUpdate` emissions for structured concurrency consumers.
    func makeStateUpdateStream() -> AsyncStream<CanvasStateUpdate> {
        AsyncStream { continuation in
            let token = addCaptureSink { update in
                continuation.yield(update)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.removeCaptureSink(token)
                }
            }
        }
    }

    /// Current monotonic seconds elapsed since the capture clock origin.
    var currentCaptureElapsedSeconds: TimeInterval {
        max(0, ProcessInfo.processInfo.systemUptime - captureClockOriginUptime)
    }

    /// Resets the monotonic elapsed clock and clears buffered telemetry events.
    func resetCaptureClock() {
        captureClockOriginUptime = ProcessInfo.processInfo.systemUptime
        sequenceSeed = 0
        totalCapturedEvents = 0
        latestUpdate = nil
        recentUpdates.removeAll(keepingCapacity: true)
    }

    // MARK: - Deterministic Playback & Scrubbing Synchronization

    /// Applies an evaluated `InterpolatedSceneState` from `PlaybackEngine` directly to the desktop canvas
    /// without implicit SwiftUI animation lag and without echoing bogus capture events.
    func applyInterpolatedScene(_ scene: InterpolatedSceneState) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            if let targetWallpaper = scene.wallpaper, wallpaper != targetWallpaper {
                wallpaper = targetWallpaper
            }

            let existingByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
            var synchronizedWindows: [DesktopWindow] = []
            synchronizedWindows.reserveCapacity(scene.windows.count)

            for evaluated in scene.windows {
                if let existing = existingByID[evaluated.windowID] {
                    if existing.title != evaluated.title {
                        existing.title = evaluated.title
                    }
                    if existing.frame != evaluated.frame {
                        existing.frame = evaluated.frame
                    }
                    if existing.zIndex != evaluated.zIndex {
                        existing.zIndex = evaluated.zIndex
                    }
                    if existing.accent != evaluated.accent {
                        existing.accent = evaluated.accent
                    }
                    let shouldMinimize = (evaluated.presentationState == .minimized)
                    let shouldMaximize = (evaluated.presentationState == .maximized)
                    if existing.isMinimized != shouldMinimize {
                        existing.isMinimized = shouldMinimize
                    }
                    if existing.isMaximized != shouldMaximize {
                        existing.isMaximized = shouldMaximize
                    }
                    synchronizedWindows.append(existing)
                } else {
                    let reconstructed = DesktopWindow(
                        id: evaluated.windowID,
                        title: evaluated.title,
                        frame: evaluated.frame,
                        content: evaluated.initialContent,
                        zIndex: evaluated.zIndex,
                        accent: evaluated.accent,
                        isMinimized: evaluated.presentationState == .minimized,
                        isMaximized: evaluated.presentationState == .maximized,
                        minimumSize: evaluated.minimumSize
                    )
                    synchronizedWindows.append(reconstructed)
                }
            }

            if windows.map(\.id) != synchronizedWindows.map(\.id) {
                windows = synchronizedWindows
            }

            if activeWindowID != scene.activeWindowID {
                activeWindowID = scene.activeWindowID
            }

            let highestZ = synchronizedWindows.map(\.zIndex).max() ?? 0
            if highestZ > topZSeed {
                topZSeed = highestZ
            }
        }
    }

    private func emitUpdate(_ action: CanvasMutationAction) {
        sequenceSeed += 1
        let now = Date()
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - captureClockOriginUptime)
        let snapshot = windows
            .sorted(by: { $0.zIndex < $1.zIndex })
            .map(\.snapshot)

        let update = CanvasStateUpdate(
            id: UUID(),
            sequenceNumber: sequenceSeed,
            timestamp: now,
            elapsedSeconds: elapsed,
            action: action,
            windowsSnapshot: snapshot
        )

        totalCapturedEvents = sequenceSeed
        latestUpdate = update
        recentUpdates.append(update)
        if recentUpdates.count > maxRecentHistoryCount {
            recentUpdates.removeFirst(recentUpdates.count - maxRecentHistoryCount)
        }

        onStateCaptured?(update)
        for sink in captureSinks.values {
            sink(update)
        }
    }

    /// Synthesizes a static `RecordedSession` from the live desktop canvas when the user exports before recording a session.
    func makeLiveCanvasExportSession(defaultDuration: Double = 3.0) -> RecordedSession {
        let inferredVideoDuration = windows.compactMap { window -> Double? in
            guard !window.isMinimized, case let .video(payload) = window.content, payload.assetURL != nil else {
                return nil
            }
            return max(0.5, payload.durationSeconds - payload.mediaStartOffset)
        }.max()

        let effectiveDuration = max(1.0, inferredVideoDuration ?? defaultDuration)
        let snapshotTracks = windows.map { window in
            WindowTimelineTrack(
                windowID: window.id,
                title: window.title,
                contentKind: window.content.kind,
                initialContent: window.content,
                minimumSize: window.minimumSize,
                accent: window.accent,
                wasSpawnedDuringSession: false,
                keyframes: [
                    WindowKeyframe(
                        time: 0.0,
                        frame: window.frame,
                        zIndex: window.zIndex,
                        presentationState: window.presentationState,
                        isFocused: activeWindowID == window.id && !window.isMinimized,
                        isPresent: true,
                        accent: window.accent,
                        eventKind: .initial
                    )
                ]
            )
        }

        return RecordedSession(
            duration: effectiveDuration,
            wallpaper: wallpaper,
            canvasSize: canvasBounds,
            initialActiveWindowID: activeWindowID,
            tracks: snapshotTracks
        )
    }

    // MARK: - Default Showcase Layout

    static func makeDefaultWindows() -> [DesktopWindow] {
        [
            DesktopWindow(
                title: "ScreenPlay Browser",
                frame: WindowFrame(x: 64, y: 66, width: 540, height: 380),
                content: .demoBrowser,
                zIndex: 1,
                accent: .skyPeriwinkle
            ),
            DesktopWindow(
                title: "SpringTimeline.swift",
                frame: WindowFrame(x: 560, y: 84, width: 490, height: 330),
                content: .demoCodeSnippet,
                zIndex: 2,
                accent: .sunnyMango
            ),
            DesktopWindow(
                title: "Product_Launch_Cut_01.mov",
                frame: WindowFrame(x: 290, y: 280, width: 480, height: 345),
                content: .demoVideo,
                zIndex: 3,
                accent: .coralBlush
            )
        ]
    }
}
