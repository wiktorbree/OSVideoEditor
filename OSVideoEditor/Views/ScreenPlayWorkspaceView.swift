//
//  ScreenPlayWorkspaceView.swift
//  OSVideoEditor
//
//  Milestone 1 + 2 Workspace: Virtual Cartoon macOS Desktop Canvas, Top Menu Bar,
//  Launcher/Window Dock, Live Session Recorder, Deterministic Playback Engine,
//  and Bottom Cartoon Keyframe Timeline Drawer.
//

import SwiftUI

struct ScreenPlayWorkspaceView: View {
    @State private var canvasState = CanvasState()
    @State private var sessionRecorder = SessionRecorder()
    @State private var playbackEngine = PlaybackEngine()
    @State private var exportManager = VideoExportManager()

    @State private var workspaceMode: WorkspaceMode = .liveCanvas
    @State private var isTimelineExpanded: Bool = true
    @State private var isCaptureFeedExpanded: Bool = false
    @State private var isExportModalPresented: Bool = false
    @State private var pendingExportSession: RecordedSession?
    @State private var isExportingLiveSnapshot: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Upper Interactive Virtual Desktop Stage
            ZStack {
                DesktopCanvasView(canvasState: canvasState)
                    .allowsHitTesting(workspaceMode == .liveCanvas)

                // Virtual Desktop Chrome Overlay (Top Menu Bar, Review Mode Banner, Dock, Capture HUD)
                VStack(spacing: 0) {
                    virtualDesktopMenuBar

                    if workspaceMode == .reviewTimeline {
                        reviewModeBanner
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 0)

                    ZStack(alignment: .bottom) {
                        if workspaceMode == .liveCanvas {
                            cartoonDesktopDock
                                .frame(maxWidth: .infinity)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        HStack {
                            Spacer()
                            StateCaptureHUDView(
                                canvasState: canvasState,
                                recorder: sessionRecorder,
                                isExpanded: $isCaptureFeedExpanded
                            )
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Bottom Cartoon Keyframe Timeline & Transport Dock
            TimelineView(
                canvasState: canvasState,
                recorder: sessionRecorder,
                playbackEngine: playbackEngine,
                workspaceMode: $workspaceMode,
                isExpanded: $isTimelineExpanded,
                onToggleRecord: handleToggleRecord,
                onTogglePlayPause: handleTogglePlayPause,
                onStop: handleStop,
                onScrub: handleScrub,
                onSelectMode: switchWorkspaceMode
            )
        }
        .frame(minWidth: 1040, minHeight: 720)
        .background(CartoonTheme.surfacePaper)
        .onAppear {
            playbackEngine.bind(to: canvasState)
        }
        .sheet(isPresented: $isExportModalPresented) {
            let exportSession = pendingExportSession
                ?? playbackEngine.session
                ?? sessionRecorder.latestSession
                ?? canvasState.makeLiveCanvasExportSession()
            ExportVideoModalView(
                exportManager: exportManager,
                session: exportSession,
                interpolationCurve: playbackEngine.interpolationCurve,
                previewTimestamp: playbackEngine.currentTime,
                isLiveSnapshotFallback: isExportingLiveSnapshot,
                onDismiss: {
                    if !exportManager.isExporting {
                        isExportModalPresented = false
                    }
                }
            )
            .interactiveDismissDisabled(exportManager.isExporting)
        }
    }

    // MARK: - Export Modal Coordinator

    private func handlePresentExportModal() {
        if sessionRecorder.isRecording {
            finishRecordingAndEnterReview(autoPlay: false)
        } else {
            playbackEngine.pause()
        }

        if let recorded = playbackEngine.session ?? sessionRecorder.latestSession, !recorded.tracks.isEmpty {
            pendingExportSession = recorded
            isExportingLiveSnapshot = false
        } else {
            pendingExportSession = canvasState.makeLiveCanvasExportSession()
            isExportingLiveSnapshot = true
        }

        exportManager.reset()
        isExportModalPresented = true
    }

    // MARK: - Recording, Playback & Mode Switching Coordinator

    private func handleToggleRecord() {
        if sessionRecorder.isRecording {
            finishRecordingAndEnterReview(autoPlay: false)
        } else {
            playbackEngine.pause()
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) {
                workspaceMode = .liveCanvas
                isTimelineExpanded = true
            }
            sessionRecorder.startRecording(canvasState: canvasState)
        }
    }

    private func finishRecordingAndEnterReview(autoPlay: Bool) {
        guard let recorded = sessionRecorder.stopRecording() else { return }
        let targetSeek = autoPlay ? 0.0 : recorded.duration
        playbackEngine.loadSession(recorded, canvasState: canvasState, seekTo: targetSeek)

        withAnimation(.spring(duration: 0.25, bounce: 0.2)) {
            workspaceMode = .reviewTimeline
            isTimelineExpanded = true
        }

        if autoPlay {
            playbackEngine.play()
        }
    }

    private func handleTogglePlayPause() {
        if sessionRecorder.isRecording {
            finishRecordingAndEnterReview(autoPlay: true)
            return
        }

        guard playbackEngine.hasRecordedSession else { return }

        if workspaceMode != .reviewTimeline {
            withAnimation(.spring(duration: 0.22, bounce: 0.18)) {
                workspaceMode = .reviewTimeline
            }
            playbackEngine.seek(to: playbackEngine.currentTime)
        }
        playbackEngine.togglePlayPause()
    }

    private func handleStop() {
        if sessionRecorder.isRecording {
            finishRecordingAndEnterReview(autoPlay: false)
            return
        }

        if workspaceMode != .reviewTimeline, playbackEngine.hasRecordedSession {
            withAnimation(.spring(duration: 0.22, bounce: 0.18)) {
                workspaceMode = .reviewTimeline
            }
        }
        playbackEngine.stop()
    }

    private func handleScrub(to targetTime: Double) {
        if sessionRecorder.isRecording {
            guard let recorded = sessionRecorder.stopRecording() else { return }
            playbackEngine.loadSession(recorded, canvasState: canvasState, seekTo: targetTime)
            withAnimation(.spring(duration: 0.22, bounce: 0.18)) {
                workspaceMode = .reviewTimeline
            }
            return
        }

        guard playbackEngine.hasRecordedSession else { return }

        if playbackEngine.isPlaying {
            playbackEngine.pause()
        }
        if workspaceMode != .reviewTimeline {
            withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                workspaceMode = .reviewTimeline
            }
        }
        playbackEngine.seek(to: targetTime)
    }

    private func switchWorkspaceMode(to targetMode: WorkspaceMode) {
        switch targetMode {
        case .liveCanvas:
            if sessionRecorder.isRecording { return }
            playbackEngine.pause()
            withAnimation(.spring(duration: 0.24, bounce: 0.2)) {
                workspaceMode = .liveCanvas
            }

        case .reviewTimeline:
            if sessionRecorder.isRecording {
                finishRecordingAndEnterReview(autoPlay: false)
                return
            }
            guard playbackEngine.hasRecordedSession else { return }
            withAnimation(.spring(duration: 0.24, bounce: 0.2)) {
                workspaceMode = .reviewTimeline
            }
            // Deterministically synchronize CanvasState to the exact interpolated scene at currentTime
            playbackEngine.seek(to: playbackEngine.currentTime)
        }
    }

    // MARK: - Cartoon Virtual macOS Menu Bar

    private var virtualDesktopMenuBar: some View {
        HStack(spacing: 10) {
            // Brand Pill
            HStack(spacing: 7) {
                Image(systemName: "movieclapper.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                Text("ScreenPlay OS")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(CartoonAccent.sunnyMango.titleBarFill)
            )
            .overlay {
                Capsule()
                    .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
            }

            // Live Mode / Recording Status Badge
            menuBarSessionStatusBadge

            // Active Window Indicator
            if let active = canvasState.activeWindow {
                HStack(spacing: 6) {
                    Circle()
                        .fill(active.accent.vibrantPop)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.2))

                    Text(active.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .lineLimit(1)

                    Text("z:\(Int(active.zIndex))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.white.opacity(0.75)))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink.opacity(0.25), lineWidth: 1.2))
            }

            Spacer(minLength: 10)

            // Wallpaper Preset Switcher
            HStack(spacing: 5) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CartoonTheme.inkSubtle)

                ForEach(CartoonWallpaper.allCases) { preset in
                    let isSelected = canvasState.wallpaper == preset
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            canvasState.wallpaper = preset
                        }
                    } label: {
                        Text(preset.title)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(CartoonTheme.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white : Color.clear)
                            )
                            .overlay {
                                if isSelected {
                                    Capsule()
                                        .strokeBorder(CartoonTheme.ink, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.55)))
            .overlay(Capsule().strokeBorder(CartoonTheme.ink.opacity(0.25), lineWidth: 1.2))

            // Reset Demo Scene Button
            Button {
                playbackEngine.pause()
                if workspaceMode != .liveCanvas {
                    withAnimation(.spring(duration: 0.22, bounce: 0.18)) {
                        workspaceMode = .liveCanvas
                    }
                }
                canvasState.resetToDemoWorkspace()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .black))
                    Text("Reset Scene")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.88)))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
            }
            .buttonStyle(.plain)

            // Master Toolbar Export Video CTA Button
            Button(action: handlePresentExportModal) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up.fill")
                        .font(.system(size: 10.5, weight: .black))
                    Text("Export Video")
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(CartoonAccent.coralBlush.titleBarFill))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                .shadow(color: CartoonTheme.ink.opacity(0.18), radius: 0.6, x: 0, y: 1.5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: [.command])
            .help("Export Offline MP4 / ProRes Video (⌘E)")
        }
        .padding(.horizontal, 14)
        .frame(height: CartoonTheme.virtualMenuBarHeight)
        .background(Color.white.opacity(0.78))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CartoonTheme.ink)
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private var menuBarSessionStatusBadge: some View {
        if sessionRecorder.isRecording {
            Button(action: handleToggleRecord) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                    Text("REC \(TimelineTimeFormatter.formatTimecode(sessionRecorder.elapsedTime))")
                        .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color(red: 0.96, green: 0.22, blue: 0.27)))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
                .shadow(color: Color.red.opacity(0.45), radius: 6, x: 0, y: 0)
            }
            .buttonStyle(.plain)
            .help("Recording active — click to stop and review")
        } else if workspaceMode == .reviewTimeline {
            Button {
                switchWorkspaceMode(to: .liveCanvas)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: playbackEngine.isPlaying ? "play.fill" : "film")
                        .font(.system(size: 9.5, weight: .black))
                    Text(playbackEngine.isPlaying ? "PLAYING" : "REVIEW")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(CartoonAccent.skyPeriwinkle.titleBarFill))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
            }
            .buttonStyle(.plain)
            .help("Click to return to interactive Live Canvas")
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(CartoonTheme.trafficZoom)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.1))
                Text("LIVE CANVAS")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(CartoonAccent.mintMatcha.softTint))
            .overlay(Capsule().strokeBorder(CartoonTheme.ink.opacity(0.45), lineWidth: 1.4))
        }
    }

    // MARK: - Review / Scrub Timeline Mode Floating Banner

    private var reviewModeBanner: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)

                Text("Reviewing Recorded Timeline")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                Text("• \(playbackEngine.interpolationCurve.displayName) Curve")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
            }

            Button {
                switchWorkspaceMode(to: .liveCanvas)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 10, weight: .black))
                    Text("Edit Live Canvas")
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(CartoonAccent.mintMatcha.titleBarFill))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.93))
        )
        .overlay {
            Capsule()
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
        .shadow(color: CartoonTheme.ink.opacity(0.16), radius: 1, x: 0, y: 3)
    }

    // MARK: - Cartoon Floating Desktop Dock

    private var cartoonDesktopDock: some View {
        HStack(spacing: 8) {
            // Spawners for Video, Code Snippet, and Browser windows
            ForEach(WindowContent.Kind.allCases) { kind in
                DockSpawnerButton(kind: kind) {
                    canvasState.spawnWindow(of: kind)
                }
            }

            if !canvasState.windows.isEmpty {
                RoundedRectangle(cornerRadius: 1)
                    .fill(CartoonTheme.ink.opacity(0.22))
                    .frame(width: 2, height: 26)
                    .padding(.horizontal, 4)

                // Active & Minimized Window Pills
                HStack(spacing: 6) {
                    ForEach(canvasState.windows) { window in
                        let isActive = (canvasState.activeWindowID == window.id) && !window.isMinimized
                        Button {
                            if window.isMinimized {
                                canvasState.toggleMinimize(window.id)
                            } else {
                                canvasState.bringToFront(window.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: window.content.systemImage)
                                    .font(.system(size: 10.5, weight: .black))
                                Text(window.title)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .frame(maxWidth: 110)

                                if window.isMinimized {
                                    Text("MIN")
                                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(CartoonTheme.trafficMinimize))
                                }
                            }
                            .foregroundStyle(CartoonTheme.ink)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isActive ? window.accent.titleBarFill : Color.white.opacity(0.85))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        CartoonTheme.ink.opacity(window.isMinimized ? 0.55 : 1.0),
                                        lineWidth: isActive ? 2.0 : 1.5
                                    )
                            }
                            .opacity(window.isMinimized ? 0.78 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .help(window.isMinimized ? "Restore \(window.title)" : "Focus \(window.title)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.88))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2.2)
        }
        .shadow(color: CartoonTheme.ink.opacity(0.18), radius: 1, x: 0, y: 4)
        .shadow(color: CartoonTheme.ink.opacity(0.10), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Dock Launcher Button

private struct DockSpawnerButton: View {
    let kind: WindowContent.Kind
    let action: () -> Void

    @State private var isHovered = false

    private var tint: Color {
        switch kind {
        case .video: CartoonAccent.coralBlush.titleBarFill
        case .codeSnippet: CartoonAccent.sunnyMango.titleBarFill
        case .browser: CartoonAccent.skyPeriwinkle.titleBarFill
        case .image: CartoonAccent.lavenderPop.titleBarFill
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .black))
                Image(systemName: kind.systemImage)
                    .font(.system(size: 11, weight: .black))
                Text(kind.shortBadge)
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(CartoonTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .offset(y: isHovered ? -2 : 0)
            .animation(.spring(duration: 0.18, bounce: 0.35), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("New \(kind.displayName) Window")
    }
}

// MARK: - Isolated State Capture Telemetry HUD

private struct StateCaptureHUDView: View {
    let canvasState: CanvasState
    let recorder: SessionRecorder
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isExpanded {
                expandedStreamCard
                    .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }

            // Compact Toggle Pill
            Button {
                withAnimation(.spring(duration: 0.25, bounce: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(recorder.isRecording ? Color(red: 0.96, green: 0.22, blue: 0.27) : CartoonTheme.trafficZoom)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.3))

                    Text("Capture Stream")
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))

                    Text("#\(canvasState.totalCapturedEvents)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(CartoonAccent.mintMatcha.titleBarFill))
                        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.3))

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9.5, weight: .black))
                }
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(Capsule().fill(Color.white.opacity(0.94)))
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                .shadow(color: CartoonTheme.ink.opacity(0.18), radius: 0.5, x: 0, y: 2.5)
            }
            .buttonStyle(.plain)
        }
    }

    private var expandedStreamCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("State Capture & Sampler", systemImage: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                Spacer()

                if recorder.rawEventsReceived > 0 {
                    Text("\(recorder.rawEventsReceived) raw → \(recorder.keyframesRecorded) kf")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }

                Button("Clear") {
                    canvasState.resetCaptureClock()
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(CartoonTheme.inkSubtle)
                .buttonStyle(.plain)
            }

            Divider()

            if canvasState.recentUpdates.isEmpty {
                Text("Drag, resize, or focus any window to emit timestamped keyframes…")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(canvasState.recentUpdates.suffix(5).reversed()) { event in
                        HStack(spacing: 6) {
                            Text(event.formattedElapsed)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CartoonTheme.inkSubtle)

                            Text(event.action.badgeText)
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(CartoonTheme.ink)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(badgeFill(for: event.action)))
                                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.1))

                            Text(event.action.summaryDescription)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CartoonTheme.ink)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
        .shadow(color: CartoonTheme.ink.opacity(0.18), radius: 1, x: 0, y: 4)
    }

    private func badgeFill(for action: CanvasMutationAction) -> Color {
        switch action {
        case .windowMoved: CartoonAccent.sunnyMango.titleBarFill
        case .windowResized: CartoonAccent.lavenderPop.titleBarFill
        case .windowFocused: CartoonAccent.mintMatcha.titleBarFill
        case .windowPresentationChanged: CartoonAccent.skyPeriwinkle.titleBarFill
        case .windowAdded, .windowClosed, .workspaceReset: CartoonAccent.coralBlush.titleBarFill
        }
    }
}
