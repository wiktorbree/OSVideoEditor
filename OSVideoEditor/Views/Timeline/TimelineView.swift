//
//  TimelineView.swift
//  OSVideoEditor
//
//  Cartoon-styled bottom dock/drawer timeline featuring glowing red recording controls,
//  transport & timecode readout, smooth magnetic playhead scrubber, time-axis zoom,
//  and per-window horizontal keyframe diamond/motion-bar tracks.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct TimelineView: View {
    let canvasState: CanvasState
    let recorder: SessionRecorder
    @Bindable var playbackEngine: PlaybackEngine
    @Binding var workspaceMode: WorkspaceMode
    @Binding var isExpanded: Bool

    let onToggleRecord: () -> Void
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void
    let onScrub: (Double) -> Void
    let onSelectMode: (WorkspaceMode) -> Void

    // MARK: - Timeline Viewport & Interaction State

    @State private var pixelsPerSecond: CGFloat = 115
    @State private var isSnapEnabled: Bool = true
    @State private var isActivelyScrubbing: Bool = false
    @State private var isCurrentlySnapped: Bool = false
    @State private var timelineViewportWidth: CGFloat = 820
    @State private var recPulse: Bool = false

    private let sidebarWidth: CGFloat = 212
    private let rulerHeight: CGFloat = 28
    private let trackRowHeight: CGFloat = 38
    private let trackLeadInset: CGFloat = 18
    private let trackTrailInset: CGFloat = 44

    private let minZoomPPS: CGFloat = 45
    private let maxZoomPPS: CGFloat = 360
    private let baseZoomPPS: CGFloat = 115

    // MARK: - Derived Timeline Model

    private var activeSession: RecordedSession? {
        if recorder.isRecording {
            return recorder.latestSession
        }
        return playbackEngine.session ?? recorder.latestSession
    }

    private var displayedTracks: [WindowTimelineTrack] {
        if let session = activeSession, !session.tracks.isEmpty {
            return session.tracks
        }
        // Before first recording, preview live desktop windows as armed tracks
        return canvasState.windows.map { window in
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
                        isFocused: canvasState.activeWindowID == window.id,
                        isPresent: true,
                        accent: window.accent,
                        eventKind: .initial
                    )
                ]
            )
        }
    }

    private var displayedTime: Double {
        if recorder.isRecording {
            return recorder.elapsedTime
        }
        return playbackEngine.currentTime
    }

    private var recordedDuration: Double {
        if recorder.isRecording {
            return recorder.elapsedTime
        }
        return activeSession?.duration ?? 0.0
    }

    /// Visible time span on the horizontal ruler (provides comfortable lookahead runway).
    private var axisDuration: Double {
        if recorder.isRecording {
            return max(8.0, (recorder.elapsedTime + 2.5).rounded(.up))
        }
        if let session = activeSession, session.duration > 0 {
            return max(4.0, session.duration + 0.5)
        }
        return 8.0
    }

    private var timelineCanvasWidth: CGFloat {
        let computed = trackLeadInset + trackTrailInset + CGFloat(axisDuration) * pixelsPerSecond
        return max(timelineViewportWidth, computed)
    }

    private var tracksStackHeight: CGFloat {
        CGFloat(max(1, displayedTracks.count)) * trackRowHeight
    }

    private var zoomPercentage: Int {
        Int(((pixelsPerSecond / baseZoomPPS) * 100.0).rounded())
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            transportToolbar

            if isExpanded {
                Rectangle()
                    .fill(CartoonTheme.ink)
                    .frame(height: 2)

                timelineDrawerBody
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(CartoonTheme.surfacePaper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CartoonTheme.ink)
                .frame(height: 2.5)
        }
        .shadow(color: CartoonTheme.ink.opacity(0.14), radius: 10, x: 0, y: -3)
        .onChange(of: recorder.isRecording, initial: true) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    recPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    recPulse = false
                }
            }
        }
    }

    // MARK: - Top Transport & Controls Bar

    private var transportToolbar: some View {
        HStack(spacing: 10) {
            // 1. Record, Play/Pause, Stop, Keyframe Step Cluster
            HStack(spacing: 7) {
                recordButton

                playPauseButton

                stopButton

                HStack(spacing: 3) {
                    TimelineIconButton(
                        symbol: "backward.end.fill",
                        isDisabled: recorder.isRecording || activeSession == nil,
                        helpText: "Previous Keyframe"
                    ) {
                        onSelectMode(.reviewTimeline)
                        playbackEngine.stepToAdjacentKeyframe(forward: false)
                    }

                    TimelineIconButton(
                        symbol: "forward.end.fill",
                        isDisabled: recorder.isRecording || activeSession == nil,
                        helpText: "Next Keyframe"
                    ) {
                        onSelectMode(.reviewTimeline)
                        playbackEngine.stepToAdjacentKeyframe(forward: true)
                    }
                }

                TimelineToggleIconButton(
                    symbol: "repeat",
                    isOn: playbackEngine.isLooping,
                    activeTint: CartoonAccent.mintMatcha.titleBarFill,
                    helpText: "Loop Playback"
                ) {
                    playbackEngine.isLooping.toggle()
                }
            }

            // 2. Monospaced Current Time / Duration Counter
            timecodeCounterPill

            Spacer(minLength: 6)

            // 3. Mode Switcher (Live Canvas vs Review Timeline)
            workspaceModePicker

            // 4. Interpolation Curve Picker (Linear / Ease-In-Out / Spring)
            interpolationCurvePicker

            Spacer(minLength: 6)

            // 5. Snapping & Time-Axis Zoom Controls
            HStack(spacing: 7) {
                snapControlButton

                zoomControlsCluster

                drawerCollapseButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack(alignment: .top) {
                CartoonTheme.surfaceSecondary
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(height: 1.5)
            }
        )
    }

    private var recordButton: some View {
        let isRec = recorder.isRecording
        let recRed = Color(red: 0.96, green: 0.22, blue: 0.27)

        return Button(action: onToggleRecord) {
            HStack(spacing: 6) {
                ZStack {
                    if isRec {
                        Circle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 15, height: 15)
                            .scaleEffect(recPulse ? 1.35 : 0.85)
                    }

                    Circle()
                        .fill(isRec ? Color.white : recRed)
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle()
                                .strokeBorder(CartoonTheme.ink, lineWidth: isRec ? 0 : 1.4)
                        }
                }
                .frame(width: 14, height: 14)

                Text(isRec ? "REC" : "Record")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(isRec ? Color.white : CartoonTheme.ink)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(isRec ? recRed : Color.white)
            )
            .overlay {
                Capsule()
                    .strokeBorder(CartoonTheme.ink, lineWidth: 2)
            }
            // Glowing red recording state
            .shadow(
                color: isRec ? recRed.opacity(recPulse ? 0.72 : 0.35) : CartoonTheme.ink.opacity(0.18),
                radius: isRec ? (recPulse ? 11 : 5) : 0.5,
                x: 0,
                y: isRec ? 0 : 2.5
            )
        }
        .buttonStyle(.plain)
        .help(isRec ? "Stop Recording Session" : "Start Live Session Recording")
    }

    private var playPauseButton: some View {
        let canPlay = recorder.isRecording || (activeSession != nil && (activeSession?.duration ?? 0) > 0)
        let isPlaying = playbackEngine.isPlaying

        return Button(action: onTogglePlayPause) {
            HStack(spacing: 5) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .black))
                Text(isPlaying ? "Pause" : "Play")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(CartoonTheme.ink.opacity(canPlay ? 1.0 : 0.42))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        !canPlay
                            ? Color.white.opacity(0.55)
                            : (isPlaying ? CartoonAccent.mintMatcha.titleBarFill : CartoonAccent.sunnyMango.titleBarFill)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(CartoonTheme.ink.opacity(canPlay ? 1.0 : 0.4), lineWidth: 2)
            }
            .shadow(color: CartoonTheme.ink.opacity(canPlay ? 0.16 : 0.0), radius: 0.5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .help(isPlaying ? "Pause Playback" : "Play Recorded Timeline")
    }

    private var stopButton: some View {
        let canStop = recorder.isRecording || playbackEngine.isPlaying || playbackEngine.currentTime > 0.001

        return Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10.5, weight: .black))
                .foregroundStyle(CartoonTheme.ink.opacity(canStop ? 1.0 : 0.38))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(canStop ? 0.92 : 0.5))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(CartoonTheme.ink.opacity(canStop ? 1.0 : 0.38), lineWidth: 1.8)
                }
        }
        .buttonStyle(.plain)
        .disabled(!canStop)
        .help(recorder.isRecording ? "Stop Recording" : "Stop and Rewind to 00:00.00")
    }

    private var timecodeCounterPill: some View {
        let isRec = recorder.isRecording
        let currentStr = TimelineTimeFormatter.formatTimecode(displayedTime)
        let durationStr = isRec
            ? "LIVE"
            : TimelineTimeFormatter.formatTimecode(recordedDuration)

        return HStack(spacing: 6) {
            if isRec {
                Circle()
                    .fill(Color(red: 0.98, green: 0.25, blue: 0.30))
                    .frame(width: 7, height: 7)
                    .opacity(recPulse ? 1.0 : 0.35)
            }

            Text(currentStr)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(isRec ? Color(red: 1.0, green: 0.48, blue: 0.50) : Color.white)

            Text("/")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))

            Text(durationStr)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isRec ? CartoonAccent.sunnyMango.titleBarFill : Color.white.opacity(0.76))
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CartoonTheme.ink)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isRec ? Color(red: 0.98, green: 0.32, blue: 0.36) : CartoonTheme.ink,
                    lineWidth: 1.6
                )
        }
    }

    private var workspaceModePicker: some View {
        HStack(spacing: 3) {
            ForEach(WorkspaceMode.allCases) { mode in
                let isSelected = (workspaceMode == mode)
                let isDisabled = (mode == .reviewTimeline && (recorder.isRecording || activeSession == nil))

                Button {
                    onSelectMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 10, weight: .black))
                        Text(mode.shortLabel)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(CartoonTheme.ink.opacity(isDisabled ? 0.38 : 1.0))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(
                                isSelected
                                    ? (mode == .liveCanvas
                                        ? CartoonAccent.mintMatcha.titleBarFill
                                        : CartoonAccent.skyPeriwinkle.titleBarFill)
                                    : Color.clear
                            )
                    )
                    .overlay {
                        if isSelected {
                            Capsule()
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help("Switch to \(mode.displayName) mode")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.82)))
        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
    }

    private var interpolationCurvePicker: some View {
        HStack(spacing: 3) {
            ForEach(InterpolationCurve.allCases) { curve in
                let isSelected = (playbackEngine.interpolationCurve == curve)
                Button {
                    playbackEngine.interpolationCurve = curve
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: curve.systemImage)
                            .font(.system(size: 9.5, weight: .bold))
                        Text(curve.shortBadge)
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? CartoonAccent.coralBlush.titleBarFill : Color.clear)
                    )
                    .overlay {
                        if isSelected {
                            Capsule()
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("\(curve.displayName) Window Frame Interpolation")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.82)))
        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
    }

    private var snapControlButton: some View {
        Button {
            isSnapEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scope")
                    .font(.system(size: 10.5, weight: .black))
                Text(isCurrentlySnapped && isActivelyScrubbing ? "SNAPPED" : "Snap")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(CartoonTheme.ink)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(
                        isCurrentlySnapped && isActivelyScrubbing
                            ? CartoonAccent.sunnyMango.titleBarFill
                            : (isSnapEnabled ? CartoonAccent.lavenderPop.titleBarFill : Color.white.opacity(0.75))
                    )
            )
            .overlay {
                Capsule()
                    .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
            }
        }
        .buttonStyle(.plain)
        .help("Magnetic Playhead Snapping to Keyframes (Hold Option while scrubbing to bypass)")
    }

    private var zoomControlsCluster: some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.spring(duration: 0.2, bounce: 0.2)) {
                    pixelsPerSecond = max(minZoomPPS, (pixelsPerSecond / 1.28).rounded())
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10.5, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Zoom Out Time Axis")

            Slider(value: $pixelsPerSecond, in: minZoomPPS...maxZoomPPS)
                .frame(width: 68)
                .controlSize(.mini)

            Button {
                withAnimation(.spring(duration: 0.2, bounce: 0.2)) {
                    pixelsPerSecond = min(maxZoomPPS, (pixelsPerSecond * 1.28).rounded())
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10.5, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Zoom In Time Axis")

            Button {
                fitTimelineToViewport()
            } label: {
                Text("\(zoomPercentage)%")
                    .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(CartoonTheme.surfaceSecondary))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink.opacity(0.45), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .help("Click to Fit Recording Duration to Timeline Width")
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.88)))
        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))
    }

    private var drawerCollapseButton: some View {
        Button {
            withAnimation(.spring(duration: 0.28, bounce: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 10.5, weight: .black))
                .foregroundStyle(CartoonTheme.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.9)))
                .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.7))
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse Timeline Tracks" : "Expand Timeline Tracks")
    }

    // MARK: - Split Sidebar + Scrollable Multi-Track Timeline Body

    private var timelineDrawerBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                // Left Fixed Window Track Headers Column
                trackHeadersSidebar
                    .frame(width: sidebarWidth)

                Rectangle()
                    .fill(CartoonTheme.ink)
                    .frame(width: 2, height: rulerHeight + tracksStackHeight)

                // Right Horizontally Scrollable Ruler, Keyframe Tracks & Playhead Scrubber
                scrollableTimelineAxis
            }
        }
        .frame(height: min(204, rulerHeight + tracksStackHeight))
        .background(CartoonTheme.surfacePaper)
    }

    // MARK: - Left Window Track Headers

    private var trackHeadersSidebar: some View {
        VStack(spacing: 0) {
            // Top Corner Header Cell (matches Ruler height = 28pt)
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(CartoonTheme.inkSubtle)

                Text("WINDOW TRACKS")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(CartoonTheme.inkSubtle)

                Spacer()

                if let session = activeSession {
                    Text("\(session.totalKeyframeCount) KF")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(CartoonTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(CartoonAccent.sunnyMango.titleBarFill))
                        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.2))
                } else {
                    Text("ARMED")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(CartoonAccent.coralBlush.titleBarFill))
                        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.2))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rulerHeight)
            .background(CartoonTheme.surfaceSecondary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CartoonTheme.ink)
                    .frame(height: 1.6)
            }

            // Window Track Rows
            if displayedTracks.isEmpty {
                HStack {
                    Text("No desktop windows")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: trackRowHeight)
            } else {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                    trackHeaderRow(for: track, rowIndex: index)
                }
            }
        }
    }

    private func trackHeaderRow(for track: WindowTimelineTrack, rowIndex: Int) -> some View {
        let isFocusedOnCanvas = canvasState.activeWindowID == track.windowID
        let hasRecordedData = activeSession != nil

        return Button {
            if workspaceMode == .liveCanvas {
                canvasState.bringToFront(track.windowID)
            } else if let firstMotion = track.majorKeyframes.dropFirst().first ?? track.majorKeyframes.first {
                onScrub(firstMotion.time)
            }
        } label: {
            HStack(spacing: 8) {
                // Window Accent Strip
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(track.accent.vibrantPop)
                    .frame(width: 4, height: 22)

                // Window Icon Badge
                Image(systemName: track.contentKind.systemImage)
                    .font(.system(size: 10.5, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(track.accent.titleBarFill)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(CartoonTheme.ink, lineWidth: 1.5)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .lineLimit(1)

                    Text(hasRecordedData ? "\(track.majorKeyframes.count) keys • \(track.keyframes.count) pts" : "Ready to record")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                if isFocusedOnCanvas {
                    Circle()
                        .fill(track.accent.vibrantPop)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.2))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: trackRowHeight)
            .background(
                isFocusedOnCanvas
                    ? track.accent.softTint.opacity(0.85)
                    : (rowIndex.isMultiple(of: 2) ? CartoonTheme.surfacePaper : CartoonTheme.surfaceSecondary.opacity(0.55))
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CartoonTheme.ink.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Scrollable Time Axis, Keyframe Lanes & Playhead

    private var scrollableTimelineAxis: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                // Background Grid + Ruler + Track Lanes
                VStack(spacing: 0) {
                    TimelineRulerCanvas(
                        axisDuration: axisDuration,
                        recordedDuration: recordedDuration,
                        pixelsPerSecond: pixelsPerSecond,
                        leadInset: trackLeadInset,
                        isRecording: recorder.isRecording,
                        snapLandmarks: activeSession?.snapTimestamps ?? []
                    )
                    .frame(width: timelineCanvasWidth, height: rulerHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(CartoonTheme.ink)
                            .frame(height: 1.6)
                    }

                    // Per-Window Horizontal Keyframe Lanes
                    ZStack {
                        VStack(spacing: 0) {
                            if displayedTracks.isEmpty {
                                Color.clear
                                    .frame(width: timelineCanvasWidth, height: trackRowHeight)
                            } else {
                                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                                    TimelineWindowTrackLaneView(
                                        track: track,
                                        rowIndex: index,
                                        sessionDuration: max(recordedDuration, 0.05),
                                        hasActiveSession: activeSession != nil,
                                        isRecording: recorder.isRecording,
                                        currentTime: displayedTime,
                                        pixelsPerSecond: pixelsPerSecond,
                                        leadInset: trackLeadInset,
                                        axisDuration: axisDuration,
                                        onSelectKeyframe: { keyframeTime in
                                            guard !recorder.isRecording, activeSession != nil else { return }
                                            onScrub(keyframeTime)
                                        }
                                    )
                                    .frame(width: timelineCanvasWidth, height: trackRowHeight)
                                }
                            }
                        }

                        // Friendly Onboarding Pill Before First Recording
                        if activeSession == nil && !recorder.isRecording {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color(red: 0.96, green: 0.22, blue: 0.27))
                                    .frame(width: 8, height: 8)
                                Text("Click Record, then drag, resize, or focus desktop windows to generate live keyframes")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(CartoonTheme.ink)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.94)))
                            .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                            .shadow(color: CartoonTheme.ink.opacity(0.14), radius: 1, x: 0, y: 3)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(timelineScrubGesture)

                // Playhead Scrubber Overlay spanning Ruler + All Tracks
                playheadScrubberOverlay
            }
            .frame(width: timelineCanvasWidth, height: rulerHeight + tracksStackHeight)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            if newWidth > 0 {
                timelineViewportWidth = newWidth
            }
        }
    }

    // MARK: - Playhead Scrubber & Magnetic Drag Gesture

    private var playheadScrubberOverlay: some View {
        let totalHeight = rulerHeight + tracksStackHeight
        let xPosition = trackLeadInset + CGFloat(max(0, displayedTime)) * pixelsPerSecond
        let isRec = recorder.isRecording
        let headColor: Color = isRec
            ? Color(red: 0.96, green: 0.22, blue: 0.27)
            : (isCurrentlySnapped && isActivelyScrubbing
                ? CartoonAccent.sunnyMango.vibrantPop
                : CartoonTheme.trafficClose)

        return ZStack(alignment: .top) {
            // Vertical Playhead Stem
            Rectangle()
                .fill(headColor)
                .frame(width: 2.4, height: totalHeight)
                .shadow(color: CartoonTheme.ink.opacity(0.28), radius: 0.5, x: 1, y: 0)

            // Cartoon Pointed Playhead Cap in the Ruler
            PlayheadCapShape()
                .fill(headColor)
                .frame(width: 17, height: 21)
                .overlay {
                    PlayheadCapShape()
                        .stroke(CartoonTheme.ink, lineWidth: 2)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 3, height: 6)
                        .padding(.top, 4)
                }
                .scaleEffect(isActivelyScrubbing ? 1.12 : 1.0)
                .animation(.spring(duration: 0.16, bounce: 0.35), value: isActivelyScrubbing)
        }
        .frame(width: 28, height: totalHeight, alignment: .top)
        .contentShape(Rectangle())
        .position(x: xPosition, y: totalHeight * 0.5)
        .gesture(timelineScrubGesture)
    }

    private var timelineScrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard activeSession != nil || recorder.isRecording else { return }
                isActivelyScrubbing = true
                let optionBypass = NSEvent.modifierFlags.contains(.option)
                let resolved = resolveScrubTime(
                    forLocationX: drag.location.x,
                    allowMagneticSnap: !optionBypass
                )
                isCurrentlySnapped = resolved.snapped
                onScrub(resolved.time)
            }
            .onEnded { _ in
                isActivelyScrubbing = false
                isCurrentlySnapped = false
            }
    }

    private func resolveScrubTime(
        forLocationX locationX: CGFloat,
        allowMagneticSnap: Bool
    ) -> (time: Double, snapped: Bool) {
        let maxScrubDuration = recorder.isRecording
            ? recorder.elapsedTime
            : (activeSession?.duration ?? 0.0)
        guard maxScrubDuration > 0, pixelsPerSecond > 0 else {
            return (0.0, false)
        }

        let rawSeconds = Double((locationX - trackLeadInset) / pixelsPerSecond)
        let clamped = min(max(rawSeconds, 0.0), maxScrubDuration)

        guard allowMagneticSnap && isSnapEnabled, !recorder.isRecording else {
            return (clamped, false)
        }

        // 1. Primary Magnetic Snap: Major Keyframe Landmarks (9pt radius)
        let landmarkRadiusSeconds = Double(9.0 / pixelsPerSecond)
        let candidates = activeSession?.snapTimestamps ?? [0.0, maxScrubDuration]

        var closestLandmark: Double?
        var smallestDelta = landmarkRadiusSeconds

        for candidate in candidates {
            let delta = abs(candidate - clamped)
            if delta <= smallestDelta {
                smallestDelta = delta
                closestLandmark = candidate
            }
        }

        if let closestLandmark {
            return (min(max(closestLandmark, 0.0), maxScrubDuration), true)
        }

        // 2. Secondary Subtle Ruler Grid Snap (4pt radius)
        let gridInterval = TimelineTickScale.forZoom(pixelsPerSecond: pixelsPerSecond).minorStep
        let nearestGrid = (clamped / gridInterval).rounded() * gridInterval
        if abs(nearestGrid - clamped) <= Double(4.0 / pixelsPerSecond) {
            return (min(max(nearestGrid, 0.0), maxScrubDuration), true)
        }

        return (clamped, false)
    }

    private func fitTimelineToViewport() {
        let targetDuration = max(2.0, recordedDuration > 0.1 ? recordedDuration : 8.0)
        let usableWidth = max(240, timelineViewportWidth - trackLeadInset - trackTrailInset - 20)
        let fittedPPS = usableWidth / CGFloat(targetDuration)
        withAnimation(.spring(duration: 0.25, bounce: 0.18)) {
            pixelsPerSecond = min(maxZoomPPS, max(minZoomPPS, fittedPPS.rounded()))
        }
    }
}

// MARK: - Adaptive Time Ruler Scale & Canvas

private struct TimelineTickScale {
    let majorStep: Double
    let minorStep: Double
    let showTenths: Bool

    static func forZoom(pixelsPerSecond: CGFloat) -> TimelineTickScale {
        if pixelsPerSecond >= 240 {
            TimelineTickScale(majorStep: 0.5, minorStep: 0.1, showTenths: true)
        } else if pixelsPerSecond >= 110 {
            TimelineTickScale(majorStep: 1.0, minorStep: 0.25, showTenths: false)
        } else if pixelsPerSecond >= 65 {
            TimelineTickScale(majorStep: 2.0, minorStep: 0.5, showTenths: false)
        } else {
            TimelineTickScale(majorStep: 5.0, minorStep: 1.0, showTenths: false)
        }
    }
}

private struct TimelineRulerCanvas: View {
    let axisDuration: Double
    let recordedDuration: Double
    let pixelsPerSecond: CGFloat
    let leadInset: CGFloat
    let isRecording: Bool
    let snapLandmarks: [Double]

    var body: some View {
        Canvas { context, size in
            // Background fill
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(CartoonTheme.surfaceSecondary)
            )

            // Highlight recorded active duration region on the ruler
            if recordedDuration > 0 {
                let recordedWidth = CGFloat(recordedDuration) * pixelsPerSecond
                let activeRect = CGRect(
                    x: leadInset,
                    y: 0,
                    width: max(2, recordedWidth),
                    height: size.height
                )
                let tint = isRecording
                    ? Color(red: 1.0, green: 0.85, blue: 0.86).opacity(0.65)
                    : CartoonAccent.sunnyMango.softTint.opacity(0.85)
                context.fill(Path(activeRect), with: .color(tint))

                // End-of-session boundary flag
                let endX = leadInset + recordedWidth
                var endLine = Path()
                endLine.move(to: CGPoint(x: endX, y: 0))
                endLine.addLine(to: CGPoint(x: endX, y: size.height))
                context.stroke(
                    endLine,
                    with: .color(CartoonTheme.ink.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                )
            }

            let scale = TimelineTickScale.forZoom(pixelsPerSecond: pixelsPerSecond)
            let totalMinorTicks = Int((axisDuration / scale.minorStep).rounded(.up))
            let majorRatio = max(1, Int((scale.majorStep / scale.minorStep).rounded()))

            for tickIndex in 0...totalMinorTicks {
                let t = Double(tickIndex) * scale.minorStep
                let x = leadInset + CGFloat(t) * pixelsPerSecond
                if x > size.width - 6 { break }

                let isMajor = (tickIndex % majorRatio == 0)
                let tickHeight: CGFloat = isMajor ? 11 : 5
                var tickPath = Path()
                tickPath.move(to: CGPoint(x: x, y: size.height - tickHeight))
                tickPath.addLine(to: CGPoint(x: x, y: size.height))

                context.stroke(
                    tickPath,
                    with: .color(CartoonTheme.ink.opacity(isMajor ? 0.72 : 0.28)),
                    lineWidth: isMajor ? 1.5 : 1.0
                )

                if isMajor {
                    let label = TimelineTimeFormatter.formatRulerLabel(t, showTenths: scale.showTenths)
                    let text = Text(label)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(CartoonTheme.inkSubtle)
                    context.draw(
                        text,
                        at: CGPoint(x: x + 3, y: 3),
                        anchor: .topLeading
                    )
                }
            }

            // Subtle landmark notches at the bottom of the ruler for snap targets
            for landmark in snapLandmarks where landmark > 0 {
                let lx = leadInset + CGFloat(landmark) * pixelsPerSecond
                let dotRect = CGRect(x: lx - 2, y: size.height - 4, width: 4, height: 4)
                context.fill(Path(ellipseIn: dotRect), with: .color(CartoonTheme.ink.opacity(0.45)))
            }
        }
    }
}

// MARK: - Horizontal Per-Window Keyframe Track Lane

private struct TimelineWindowTrackLaneView: View {
    let track: WindowTimelineTrack
    let rowIndex: Int
    let sessionDuration: Double
    let hasActiveSession: Bool
    let isRecording: Bool
    let currentTime: Double
    let pixelsPerSecond: CGFloat
    let leadInset: CGFloat
    let axisDuration: Double
    let onSelectKeyframe: (Double) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // 1. Background Grid & Motion Bars rendered in single fast Canvas pass
            Canvas { context, size in
                let baseBg = rowIndex.isMultiple(of: 2)
                    ? CartoonTheme.surfacePaper
                    : CartoonTheme.surfaceSecondary.opacity(0.48)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(baseBg))

                // Vertical major grid lines
                let scale = TimelineTickScale.forZoom(pixelsPerSecond: pixelsPerSecond)
                let majorCount = Int((axisDuration / scale.majorStep).rounded(.up))
                for idx in 0...majorCount {
                    let gx = leadInset + CGFloat(Double(idx) * scale.majorStep) * pixelsPerSecond
                    if gx > size.width { break }
                    var line = Path()
                    line.move(to: CGPoint(x: gx, y: 0))
                    line.addLine(to: CGPoint(x: gx, y: size.height))
                    context.stroke(line, with: .color(CartoonTheme.ink.opacity(0.08)), lineWidth: 1)
                }

                // Active presence span bar for this window
                if hasActiveSession || isRecording,
                   let presence = track.activePresenceRange(totalDuration: sessionDuration) {
                    let startX = leadInset + CGFloat(presence.lowerBound) * pixelsPerSecond
                    let endX = leadInset + CGFloat(presence.upperBound) * pixelsPerSecond
                    let barWidth = max(6, endX - startX)
                    let presenceRect = CGRect(
                        x: startX,
                        y: (size.height - 20) * 0.5,
                        width: barWidth,
                        height: 20
                    )
                    let rounded = Path(roundedRect: presenceRect, cornerRadius: 7)
                    context.fill(rounded, with: .color(track.accent.softTint))
                    context.stroke(
                        rounded,
                        with: .color(CartoonTheme.ink.opacity(0.24)),
                        lineWidth: 1.2
                    )
                }

                // Continuous Motion Bars (Drag / Resize / Animated Zoom transitions)
                for span in track.motionSpans {
                    let sx = leadInset + CGFloat(span.startTime) * pixelsPerSecond
                    let ex = leadInset + CGFloat(span.endTime) * pixelsPerSecond
                    let spanWidth = max(6, ex - sx)
                    let barRect = CGRect(
                        x: sx,
                        y: (size.height - 13) * 0.5,
                        width: spanWidth,
                        height: 13
                    )
                    let barPath = Path(roundedRect: barRect, cornerRadius: 6.5)
                    let fill: Color = switch span.kind {
                    case .move: track.accent.titleBarFill
                    case .resize: CartoonAccent.lavenderPop.titleBarFill
                    case .presentation: CartoonAccent.mintMatcha.titleBarFill
                    }
                    context.fill(barPath, with: .color(fill))
                    context.stroke(barPath, with: .color(CartoonTheme.ink), lineWidth: 1.6)
                }

                // Normalized 60 Hz intermediate sample micro-dots inside motion bars
                for sample in track.sampleKeyframes {
                    let px = leadInset + CGFloat(sample.time) * pixelsPerSecond
                    let dotRect = CGRect(x: px - 1.6, y: size.height * 0.5 - 1.6, width: 3.2, height: 3.2)
                    context.fill(Path(ellipseIn: dotRect), with: .color(CartoonTheme.ink.opacity(0.45)))
                }
            }

            // 2. Clickable Major Keyframe Diamonds
            ForEach(track.majorKeyframes) { keyframe in
                let kx = leadInset + CGFloat(keyframe.time) * pixelsPerSecond
                let isAtPlayhead = hasActiveSession && !isRecording && abs(currentTime - keyframe.time) < 0.008

                KeyframeDiamondMarker(
                    keyframe: keyframe,
                    trackAccent: track.accent,
                    isHighlighted: isAtPlayhead
                ) {
                    onSelectKeyframe(keyframe.time)
                }
                .position(x: kx, y: 19)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CartoonTheme.ink.opacity(0.14))
                .frame(height: 1)
        }
    }
}

// MARK: - Cartoon Keyframe Diamond Marker

private struct KeyframeDiamondMarker: View {
    let keyframe: WindowKeyframe
    let trackAccent: CartoonAccent
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var markerFill: Color {
        switch keyframe.eventKind {
        case .closed:
            CartoonTheme.trafficClose
        case .focused:
            CartoonAccent.mintMatcha.vibrantPop
        case .presentationChanged:
            CartoonTheme.trafficMinimize
        case .resizeBegan, .resizeEnded:
            CartoonAccent.lavenderPop.vibrantPop
        default:
            trackAccent.vibrantPop
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(isHighlighted ? Color.white : markerFill)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Rectangle()
                            .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
                    }
                    .rotationEffect(.degrees(45))

                if isHighlighted {
                    Circle()
                        .fill(markerFill)
                        .frame(width: 4.5, height: 4.5)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .scaleEffect(isHovered || isHighlighted ? 1.24 : 1.0)
            .animation(.spring(duration: 0.16, bounce: 0.38), value: isHovered)
            .animation(.spring(duration: 0.16, bounce: 0.38), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("\(keyframeLabel) @ \(TimelineTimeFormatter.formatTimecode(keyframe.time))")
    }

    private var keyframeLabel: String {
        switch keyframe.eventKind {
        case .initial: "Initial Anchor"
        case .moveBegan: "Move Start"
        case .moveSample: "Move Sample"
        case .moveEnded: "Move End"
        case .resizeBegan: "Resize Start"
        case .resizeSample: "Resize Sample"
        case .resizeEnded: "Resize End"
        case .focused: "Focus / Z-Order"
        case .presentationChanged: "Window State (\(keyframe.presentationState.rawValue))"
        case .spawned: "Window Spawned"
        case .closed: "Window Closed"
        case .hold: "Hold Anchor"
        }
    }
}

// MARK: - Cartoon Playhead Cap Shape & Compact Buttons

private struct PlayheadCapShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner: CGFloat = 4
        let shoulderY = rect.minY + rect.height * 0.58

        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + corner),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + corner, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct TimelineIconButton: View {
    let symbol: String
    let isDisabled: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(CartoonTheme.ink.opacity(isDisabled ? 0.35 : 1.0))
                .frame(width: 26, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isDisabled ? 0.45 : 0.9))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(CartoonTheme.ink.opacity(isDisabled ? 0.35 : 1.0), lineWidth: 1.6)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
    }
}

private struct TimelineToggleIconButton: View {
    let symbol: String
    let isOn: Bool
    let activeTint: Color
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .black))
                .foregroundStyle(CartoonTheme.ink)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? activeTint : Color.white.opacity(0.85))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(CartoonTheme.ink, lineWidth: isOn ? 1.9 : 1.6)
                }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
