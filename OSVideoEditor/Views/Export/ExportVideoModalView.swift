//
//  ExportVideoModalView.swift
//  OSVideoEditor
//
//  Milestone 3 Cartoon-Styled Offline Video Export Modal Sheet.
//  Features 1080p60 / 4K60 / ProRes preset cards, custom aspect/FPS/codec controls,
//  live offscreen CanvasFrameRenderer preview, native NSSavePanel destination selection,
//  live ProgressView with elapsed time & ETA, cancellation, and Reveal in Finder completion alert.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportVideoModalView: View {
    @Bindable var exportManager: VideoExportManager
    let session: RecordedSession
    let interpolationCurve: InterpolationCurve
    let previewTimestamp: Double
    let isLiveSnapshotFallback: Bool
    let onDismiss: () -> Void

    @State private var previewImage: CGImage?
    @State private var showCompletionAlert: Bool = false
    @State private var customWidthText: String = "2560"
    @State private var customHeightText: String = "1600"
    @State private var selectedResolutionOption: ResolutionChoice = .hd1080p

    private enum ResolutionChoice: String, CaseIterable, Identifiable {
        case hd1080p
        case wuxga1200p
        case uhd4K
        case uhd4K16x10
        case customDimensions

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hd1080p: "1080p (1920×1080 • 16:9)"
            case .wuxga1200p: "1200p (1920×1200 • 16:10)"
            case .uhd4K: "4K UHD (3840×2160 • 16:9)"
            case .uhd4K16x10: "4K Mac (3840×2400 • 16:10)"
            case .customDimensions: "Custom Dimensions"
            }
        }
    }

    private var frameSchedule: TimelineStepSchedule {
        TimelineStepSchedule(
            duration: max(exportManager.configuration.frameRate.frameDurationSeconds, session.duration),
            frameRate: exportManager.configuration.frameRate
        )
    }

    private var activeVideoAudioWindowsCount: Int {
        session.tracks.filter { track in
            if case let .video(payload) = track.initialContent {
                return payload.assetURL != nil && !payload.isMuted && payload.volume > 0.001
            }
            return false
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            modalTitleBar

            Rectangle()
                .fill(CartoonTheme.ink)
                .frame(height: 2.2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    previewAndSummaryCard

                    presetSelectorSection

                    detailedSettingsCard

                    if exportManager.isExporting {
                        liveExportProgressCard
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else if case let .completed(result) = exportManager.phase {
                        exportCompletedCard(result: result)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    } else if case let .failed(errorMessage) = exportManager.phase {
                        exportStatusBanner(
                            icon: "exclamationmark.triangle.fill",
                            title: "Export Failed",
                            detail: errorMessage,
                            tint: CartoonTheme.trafficClose.opacity(0.28)
                        )
                    } else if exportManager.phase == .cancelled {
                        exportStatusBanner(
                            icon: "xmark.circle.fill",
                            title: "Export Cancelled",
                            detail: "Partial output file was cleaned up safely.",
                            tint: CartoonTheme.trafficMinimize.opacity(0.32)
                        )
                    }
                }
                .padding(18)
            }

            Rectangle()
                .fill(CartoonTheme.ink)
                .frame(height: 2)

            modalFooterBar
        }
        .frame(width: 640)
        .frame(minHeight: 560, maxHeight: 720)
        .background(CartoonTheme.surfacePaper)
        .onAppear {
            syncResolutionPickerFromConfig()
            refreshOffscreenPreview()
        }
        .onChange(of: exportManager.configuration.resolution) { _, _ in
            syncResolutionPickerFromConfig()
            refreshOffscreenPreview()
        }
        .onChange(of: exportManager.configuration.includeDesktopMenuBar) { _, _ in
            refreshOffscreenPreview()
        }
        .onChange(of: exportManager.phase) { _, newPhase in
            if case .completed = newPhase {
                showCompletionAlert = true
            }
        }
        .alert("Video Export Complete!", isPresented: $showCompletionAlert) {
            if let result = exportManager.latestResult {
                Button("Reveal in Finder") {
                    revealInFinder(url: result.outputURL)
                }
                Button("Open Video") {
                    NSWorkspace.shared.open(result.outputURL)
                }
            }
            Button("Done", role: .cancel) {}
        } message: {
            if let result = exportManager.latestResult {
                Text(
                    "Saved \(result.outputURL.lastPathComponent) (\(formatByteCount(result.fileSizeBytes))) • \(result.totalFramesRendered) frames rendered in \(String(format: "%.1fs", result.renderElapsedSeconds))."
                )
            }
        }
    }

    // MARK: - Cartoon Modal Title Bar

    private var modalTitleBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.9))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Export Desktop Cinema")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)

                    Text("Headless Offscreen Compositor • AVAssetWriter Pipeline")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }
            }

            Spacer()

            Text(isLiveSnapshotFallback ? "LIVE SNAPSHOT" : "TIMELINE SESSION")
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundStyle(CartoonTheme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isLiveSnapshotFallback ? CartoonAccent.mintMatcha.titleBarFill : CartoonAccent.skyPeriwinkle.titleBarFill)
                )
                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.6))

            if !exportManager.isExporting {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.88)))
                        .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.7))
                }
                .buttonStyle(.plain)
                .help("Close Export Sheet")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(CartoonAccent.sunnyMango.titleBarFill)
    }

    // MARK: - Live Offscreen Frame Preview & Session Telemetry

    private var previewAndSummaryCard: some View {
        HStack(spacing: 14) {
            // Actual offscreen CanvasFrameRenderer thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CartoonTheme.surfaceSecondary)

                if let cgImage = previewImage {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 224, height: 132)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CartoonTheme.ink, lineWidth: 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    summaryBadge(
                        icon: "clock.fill",
                        text: TimelineTimeFormatter.formatTimecode(session.duration),
                        tint: CartoonAccent.sunnyMango.softTint
                    )
                    summaryBadge(
                        icon: "number.square.fill",
                        text: "\(frameSchedule.totalFrames) Frames",
                        tint: CartoonAccent.mintMatcha.softTint
                    )
                    summaryBadge(
                        icon: interpolationCurve.systemImage,
                        text: interpolationCurve.displayName,
                        tint: CartoonAccent.coralBlush.softTint
                    )
                }

                Text("\(exportManager.configuration.resolution.pixelWidth) × \(exportManager.configuration.resolution.pixelHeight) • \(exportManager.configuration.frameRate.displayName) • \(exportManager.configuration.codec.displayName)")
                    .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                Text(audioSummaryDescription)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)

                if isLiveSnapshotFallback {
                    Text("Tip: Record window motions on the Timeline to export choreographed animations.")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
        .shadow(color: CartoonTheme.ink.opacity(0.12), radius: 1, x: 0, y: 3)
    }

    private var audioSummaryDescription: String {
        guard exportManager.configuration.includeAudioTrack else {
            return "Audio track disabled (video-only container)."
        }
        if activeVideoAudioWindowsCount > 0 {
            return "Stereo 48 kHz AAC Audio Mix: \(activeVideoAudioWindowsCount) active video window track(s) synchronized."
        }
        return "Stereo 48 kHz AAC Audio Track: Clean silent stereo bed aligned to timeline duration."
    }

    private func summaryBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .black))
            Text(text)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
        }
        .foregroundStyle(CartoonTheme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tint))
        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.4))
    }

    // MARK: - Preset Selector Cards (1080p60 / 4K60 / ProRes)

    private var presetSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXPORT PRESETS")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(CartoonTheme.inkSubtle)

            HStack(spacing: 10) {
                ForEach([ExportPreset.hd1080p60, .uhd4K60, .proRes]) { preset in
                    presetCard(for: preset)
                }
            }
        }
        .disabled(exportManager.isExporting)
        .opacity(exportManager.isExporting ? 0.65 : 1.0)
    }

    private func presetCard(for preset: ExportPreset) -> some View {
        let isSelected = exportManager.configuration.preset == preset
        let cardTint: Color = switch preset {
        case .hd1080p60: CartoonAccent.mintMatcha.titleBarFill
        case .uhd4K60: CartoonAccent.skyPeriwinkle.titleBarFill
        case .proRes: CartoonAccent.coralBlush.titleBarFill
        case .custom: CartoonAccent.lavenderPop.titleBarFill
        }

        return Button {
            withAnimation(.spring(duration: 0.22, bounce: 0.22)) {
                exportManager.applyPreset(preset)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.systemImage)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)

                    Spacer()

                    Text(preset.badge)
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.2))
                }

                Text(preset.title)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                Text(preset.subtitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? cardTint : Color.white)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CartoonTheme.ink, lineWidth: isSelected ? 2.4 : 1.7)
            }
            .shadow(
                color: CartoonTheme.ink.opacity(isSelected ? 0.20 : 0.08),
                radius: 1,
                x: 0,
                y: isSelected ? 3.5 : 2
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Fine-Grained Format, Aspect Ratio, Frame Rate & Codec Settings

    private var detailedSettingsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("FORMAT & ENCODER SETTINGS")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(CartoonTheme.inkSubtle)

                Spacer()

                if exportManager.configuration.preset == .custom {
                    Text("CUSTOM OVERRIDE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CartoonAccent.lavenderPop.titleBarFill))
                        .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.3))
                }
            }

            HStack(spacing: 12) {
                // Resolution & Aspect Ratio Picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution & Aspect Ratio")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)

                    Picker("Resolution", selection: $selectedResolutionOption) {
                        ForEach(ResolutionChoice.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedResolutionOption) { _, newChoice in
                        applyResolutionChoice(newChoice)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Frame Rate Picker (30 / 60 FPS)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame Rate")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)

                    HStack(spacing: 4) {
                        ForEach(ExportFrameRate.allCases) { fps in
                            let selected = exportManager.configuration.frameRate == fps
                            Button {
                                exportManager.configuration.frameRate = fps
                                markCustomPresetIfModified()
                            } label: {
                                Text(fps.displayName)
                                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                                    .foregroundStyle(CartoonTheme.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? CartoonAccent.sunnyMango.titleBarFill : CartoonTheme.surfaceSecondary)
                                    )
                                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if selectedResolutionOption == .customDimensions {
                HStack(spacing: 10) {
                    Text("Custom Size:")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)

                    TextField("Width", text: $customWidthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .onSubmit(commitCustomDimensions)

                    Text("×")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))

                    TextField("Height", text: $customHeightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .onSubmit(commitCustomDimensions)

                    Button("Apply 16:9") {
                        let w = Int(customWidthText) ?? 2560
                        let res = ExportResolution.custom(width: w, aspectRatio: .widescreen16x9)
                        customWidthText = "\(res.pixelWidth)"
                        customHeightText = "\(res.pixelHeight)"
                        exportManager.configuration.resolution = res
                        exportManager.configuration.preset = .custom
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Apply 16:10") {
                        let w = Int(customWidthText) ?? 2560
                        let res = ExportResolution.custom(width: w, aspectRatio: .desktop16x10)
                        customWidthText = "\(res.pixelWidth)"
                        customHeightText = "\(res.pixelHeight)"
                        exportManager.configuration.resolution = res
                        exportManager.configuration.preset = .custom
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Video Codec Selector
            VStack(alignment: .leading, spacing: 5) {
                Text("Video Codec & Container")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                HStack(spacing: 8) {
                    ForEach(ExportVideoCodec.allCases) { codec in
                        let isSelected = exportManager.configuration.codec == codec
                        Button {
                            exportManager.configuration.codec = codec
                            markCustomPresetIfModified()
                        } label: {
                            Text(codec.displayName)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(CartoonTheme.ink)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? CartoonAccent.lavenderPop.titleBarFill : CartoonTheme.surfaceSecondary)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(CartoonTheme.ink, lineWidth: isSelected ? 2.0 : 1.4)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            HStack(spacing: 18) {
                Toggle("Include Virtual macOS Menu Bar", isOn: $exportManager.configuration.includeDesktopMenuBar)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)

                Toggle("Mix Stereo AAC Audio Track", isOn: $exportManager.configuration.includeAudioTrack)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
        .disabled(exportManager.isExporting)
        .opacity(exportManager.isExporting ? 0.65 : 1.0)
    }

    // MARK: - Live Progress, Elapsed Time, ETA & Cancel Card

    private var liveExportProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)

                    Text(exportManager.phase == .preparing ? "Preparing Assets & Stereo Audio Mix…" : "Rendering Offscreen Desktop Frames…")
                        .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                }

                Spacer()

                Text("\(Int((exportManager.progress * 100.0).rounded()))%")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(CartoonAccent.sunnyMango.titleBarFill))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))
            }

            ProgressView(value: exportManager.progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(CartoonAccent.mintMatcha.vibrantPop)

            HStack(spacing: 14) {
                Label(
                    "Frame \(exportManager.renderedFrames) / \(max(1, exportManager.totalFrames))",
                    systemImage: "film"
                )
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(CartoonTheme.ink)

                Label(
                    "Elapsed: \(formatDurationShort(exportManager.elapsedSeconds))",
                    systemImage: "stopwatch.fill"
                )
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(CartoonTheme.inkSubtle)

                Spacer()

                if let eta = exportManager.estimatedRemainingSeconds {
                    Text("ETA ~\(formatDurationShort(eta))")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(CartoonTheme.ink)
                } else {
                    Text("Calculating ETA…")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(CartoonAccent.mintMatcha.softTint)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
    }

    // MARK: - Completion Card with Reveal in Finder

    private func exportCompletedCard(result: VideoExportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(CartoonTheme.trafficZoom)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Completed — \(result.outputURL.lastPathComponent)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)

                    Text("\(result.totalFramesRendered) frames • \(formatByteCount(result.fileSizeBytes)) • Rendered in \(String(format: "%.2fs", result.renderElapsedSeconds))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(CartoonTheme.inkSubtle)
                }

                Spacer()

                Button {
                    revealInFinder(url: result.outputURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11, weight: .black))
                        Text("Reveal in Finder")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(CartoonAccent.sunnyMango.titleBarFill))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                }
                .buttonStyle(.plain)

                Button {
                    NSWorkspace.shared.open(result.outputURL)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 11, weight: .black))
                        Text("Open")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(CartoonAccent.mintMatcha.titleBarFill.opacity(0.45))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
    }

    private func exportStatusBanner(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(CartoonTheme.ink)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
    }

    // MARK: - Footer Action Bar & Native NSSavePanel

    private var modalFooterBar: some View {
        HStack(spacing: 10) {
            if exportManager.isExporting {
                Button {
                    exportManager.cancelExport()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 12, weight: .black))
                        Text("Cancel Export")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(red: 0.94, green: 0.24, blue: 0.29)))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 2))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Encoding via AVAssetWriter • Multi-Threaded Queue Pump")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
            } else {
                Button("Close", action: onDismiss)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                    .buttonStyle(.plain)

                Spacer()

                Button(action: chooseDestinationAndStartExport) {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 12, weight: .black))
                        Text("Choose Destination & Export…")
                            .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(CartoonAccent.coralBlush.titleBarFill))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 2.1))
                    .shadow(color: CartoonTheme.ink.opacity(0.22), radius: 0.8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(CartoonTheme.surfaceSecondary)
    }

    // MARK: - Actions & Helpers

    private func chooseDestinationAndStartExport() {
        if selectedResolutionOption == .customDimensions {
            commitCustomDimensions()
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export ScreenPlay OS Video"
        savePanel.prompt = "Export Video"
        savePanel.nameFieldLabel = "Export As:"
        savePanel.nameFieldStringValue = exportManager.configuration.suggestedFileName
        savePanel.allowedContentTypes = [exportManager.configuration.codec.contentType]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        let handleChoice: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destinationURL = savePanel.url else { return }
            exportManager.startExport(
                session: session,
                configuration: exportManager.configuration,
                interpolationCurve: interpolationCurve,
                destinationURL: destinationURL
            )
        }

        if let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            savePanel.beginSheetModal(for: hostWindow, completionHandler: handleChoice)
        } else {
            handleChoice(savePanel.runModal())
        }
    }

    private func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshOffscreenPreview() {
        let aspect = CGFloat(exportManager.configuration.resolution.pixelWidth)
            / CGFloat(max(1, exportManager.configuration.resolution.pixelHeight))
        let thumbW: CGFloat = 640
        let thumbH = (thumbW / aspect).rounded()
        let includeBar = exportManager.configuration.includeDesktopMenuBar
        let snapSession = session
        let curve = interpolationCurve
        let sampleTime = min(max(0.0, previewTimestamp), max(0.0, session.duration))

        Task.detached(priority: .userInitiated) {
            let renderer = CanvasFrameRenderer()
            await renderer.prepare(for: snapSession)
            let cgImg = try? renderer.renderCGImage(
                for: snapSession,
                at: sampleTime,
                curve: curve,
                outputSize: CGSize(width: thumbW, height: thumbH),
                includeMenuBar: includeBar
            )
            renderer.invalidateCaches()
            await MainActor.run {
                self.previewImage = cgImg
            }
        }
    }

    private func syncResolutionPickerFromConfig() {
        switch exportManager.configuration.resolution {
        case .hd1080p:
            selectedResolutionOption = .hd1080p
        case .wuxga1200p:
            selectedResolutionOption = .wuxga1200p
        case .uhd4K:
            selectedResolutionOption = .uhd4K
        case .uhd4K16x10:
            selectedResolutionOption = .uhd4K16x10
        case let .custom(w, h):
            selectedResolutionOption = .customDimensions
            customWidthText = "\(w)"
            customHeightText = "\(h)"
        }
    }

    private func applyResolutionChoice(_ choice: ResolutionChoice) {
        switch choice {
        case .hd1080p:
            exportManager.configuration.resolution = .hd1080p
        case .wuxga1200p:
            exportManager.configuration.resolution = .wuxga1200p
        case .uhd4K:
            exportManager.configuration.resolution = .uhd4K
        case .uhd4K16x10:
            exportManager.configuration.resolution = .uhd4K16x10
        case .customDimensions:
            commitCustomDimensions()
        }
        markCustomPresetIfModified()
    }

    private func commitCustomDimensions() {
        let w = ExportResolution.sanitizeDimension(Int(customWidthText) ?? 2560)
        let h = ExportResolution.sanitizeDimension(Int(customHeightText) ?? 1600)
        customWidthText = "\(w)"
        customHeightText = "\(h)"
        exportManager.configuration.resolution = .custom(width: w, height: h)
        exportManager.configuration.preset = .custom
    }

    private func markCustomPresetIfModified() {
        let cfg = exportManager.configuration
        if cfg.resolution == .hd1080p && cfg.frameRate == .fps60 && cfg.codec == .h264 {
            exportManager.configuration.preset = .hd1080p60
        } else if cfg.resolution == .uhd4K && cfg.frameRate == .fps60 && cfg.codec == .hevc {
            exportManager.configuration.preset = .uhd4K60
        } else if cfg.resolution == .uhd4K && cfg.frameRate == .fps60 && cfg.codec == .proRes422 {
            exportManager.configuration.preset = .proRes
        } else {
            exportManager.configuration.preset = .custom
        }
    }

    private func formatDurationShort(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded()))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
