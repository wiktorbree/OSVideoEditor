//
//  ExportModels.swift
//  OSVideoEditor
//
//  Milestone 3 configuration models, presets, rational CMTime deterministic stepping schedule,
//  and shared timeline-to-media synchronization math.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UniformTypeIdentifiers

// MARK: - High-Level Export Presets

nonisolated enum ExportPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd1080p60
    case uhd4K60
    case proRes
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hd1080p60: "1080p60"
        case .uhd4K60: "4K60"
        case .proRes: "ProRes"
        case .custom: "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .hd1080p60: "1920×1080 • 60 FPS • H.264 MP4"
        case .uhd4K60: "3840×2160 • 60 FPS • HEVC MP4"
        case .proRes: "3840×2160 • 60 FPS • ProRes 422 MOV"
        case .custom: "Custom Aspect, FPS & Codec"
        }
    }

    var badge: String {
        switch self {
        case .hd1080p60: "WEB / SOCIAL"
        case .uhd4K60: "RETINA UHD"
        case .proRes: "STUDIO MASTER"
        case .custom: "MANUAL"
        }
    }

    var systemImage: String {
        switch self {
        case .hd1080p60: "sparkles.tv.fill"
        case .uhd4K60: "4k.tv.fill"
        case .proRes: "film.stack.fill"
        case .custom: "slider.horizontal.3"
        }
    }
}

// MARK: - Aspect Ratio, Resolution, Frame Rate & Codec

nonisolated enum ExportAspectRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case widescreen16x9
    case desktop16x10

    var id: String { rawValue }

    var label: String {
        switch self {
        case .widescreen16x9: "16:9 Widescreen"
        case .desktop16x10: "16:10 Mac Display"
        }
    }

    var shortLabel: String {
        switch self {
        case .widescreen16x9: "16:9"
        case .desktop16x10: "16:10"
        }
    }

    var numericRatio: CGFloat {
        switch self {
        case .widescreen16x9: 16.0 / 9.0
        case .desktop16x10: 16.0 / 10.0
        }
    }
}

nonisolated enum ExportResolution: Equatable, Codable, Sendable, Hashable {
    case hd1080p
    case wuxga1200p
    case uhd4K
    case uhd4K16x10
    case custom(width: Int, height: Int)

    /// Macroblock-aligned even pixel width (`>= 64`).
    var pixelWidth: Int {
        switch self {
        case .hd1080p, .wuxga1200p:
            1920
        case .uhd4K, .uhd4K16x10:
            3840
        case let .custom(width, _):
            Self.sanitizeDimension(width)
        }
    }

    /// Macroblock-aligned even pixel height (`>= 64`).
    var pixelHeight: Int {
        switch self {
        case .hd1080p:
            1080
        case .wuxga1200p:
            1200
        case .uhd4K:
            2160
        case .uhd4K16x10:
            2400
        case let .custom(_, height):
            Self.sanitizeDimension(height)
        }
    }

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    var aspectRatio: ExportAspectRatio? {
        let ratio = CGFloat(pixelWidth) / CGFloat(max(1, pixelHeight))
        if abs(ratio - (16.0 / 9.0)) < 0.02 {
            return .widescreen16x9
        }
        if abs(ratio - (16.0 / 10.0)) < 0.02 {
            return .desktop16x10
        }
        return nil
    }

    var displayName: String {
        switch self {
        case .hd1080p:
            "1080p HD (1920×1080 • 16:9)"
        case .wuxga1200p:
            "1200p Mac (1920×1200 • 16:10)"
        case .uhd4K:
            "4K UHD (3840×2160 • 16:9)"
        case .uhd4K16x10:
            "4K Mac (3840×2400 • 16:10)"
        case .custom:
            "Custom (\(pixelWidth)×\(pixelHeight))"
        }
    }

    var shortBadge: String {
        "\(pixelWidth)×\(pixelHeight)"
    }

    static let standardChoices: [ExportResolution] = [
        .hd1080p,
        .wuxga1200p,
        .uhd4K,
        .uhd4K16x10
    ]

    static func custom(width: Int, aspectRatio: ExportAspectRatio) -> ExportResolution {
        let cleanW = sanitizeDimension(width)
        let rawH = Int((CGFloat(cleanW) / aspectRatio.numericRatio).rounded())
        let cleanH = sanitizeDimension(rawH)
        return .custom(width: cleanW, height: cleanH)
    }

    static func sanitizeDimension(_ value: Int) -> Int {
        let clamped = min(max(value, 64), 7680)
        return (clamped % 2 == 0) ? clamped : (clamped + 1)
    }
}

nonisolated enum ExportFrameRate: Int, CaseIterable, Codable, Sendable, Identifiable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var timescale: Int32 {
        Int32(rawValue)
    }

    var frameDurationSeconds: Double {
        1.0 / Double(rawValue)
    }

    var displayName: String {
        "\(rawValue) FPS"
    }
}

nonisolated enum ExportVideoCodec: String, CaseIterable, Codable, Sendable, Identifiable {
    case h264
    case hevc
    case proRes422

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: "H.264 (MP4)"
        case .hevc: "HEVC / H.265 (MP4)"
        case .proRes422: "Apple ProRes 422 (MOV)"
        }
    }

    var shortBadge: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422: "ProRes 422"
        }
    }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
    }

    /// Container file type compatible with `AVAssetWriter` on macOS (ProRes 422 requires QuickTime `.mov`).
    var containerFileType: AVFileType {
        switch self {
        case .h264, .hevc:
            .mp4
        case .proRes422:
            .mov
        }
    }

    var fileExtension: String {
        switch self {
        case .h264, .hevc:
            "mp4"
        case .proRes422:
            "mov"
        }
    }

    var contentType: UTType {
        switch self {
        case .h264, .hevc:
            .mpeg4Movie
        case .proRes422:
            .quickTimeMovie
        }
    }

    /// Target average video bitrate (bits/sec) scaled proportionally to pixel area and frame rate.
    func targetAverageBitRate(width: Int, height: Int, frameRate: ExportFrameRate) -> Int? {
        switch self {
        case .proRes422:
            // ProRes 422 uses intrinsic profile quantization rather than average bit rate keys
            return nil
        case .h264:
            let pixelsPerFrame = Double(width * height)
            let base1080p60 = 18_000_000.0
            let areaRatio = pixelsPerFrame / (1920.0 * 1080.0)
            let fpsRatio = frameRate == .fps60 ? 1.0 : 0.68
            return max(2_000_000, Int((base1080p60 * areaRatio * fpsRatio).rounded()))
        case .hevc:
            let pixelsPerFrame = Double(width * height)
            let base1080p60 = 13_000_000.0
            let areaRatio = pixelsPerFrame / (1920.0 * 1080.0)
            let fpsRatio = frameRate == .fps60 ? 1.0 : 0.68
            return max(1_500_000, Int((base1080p60 * areaRatio * fpsRatio).rounded()))
        }
    }
}

// MARK: - Complete Export Configuration

nonisolated struct ExportConfiguration: Equatable, Codable, Sendable {
    var preset: ExportPreset
    var resolution: ExportResolution
    var frameRate: ExportFrameRate
    var codec: ExportVideoCodec
    var includeDesktopMenuBar: Bool
    var includeAudioTrack: Bool

    init(
        preset: ExportPreset = .hd1080p60,
        resolution: ExportResolution = .hd1080p,
        frameRate: ExportFrameRate = .fps60,
        codec: ExportVideoCodec = .h264,
        includeDesktopMenuBar: Bool = true,
        includeAudioTrack: Bool = true
    ) {
        self.preset = preset
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.includeDesktopMenuBar = includeDesktopMenuBar
        self.includeAudioTrack = includeAudioTrack
    }

    static let hd1080p60 = ExportConfiguration(
        preset: .hd1080p60,
        resolution: .hd1080p,
        frameRate: .fps60,
        codec: .h264
    )

    static let uhd4K60 = ExportConfiguration(
        preset: .uhd4K60,
        resolution: .uhd4K,
        frameRate: .fps60,
        codec: .hevc
    )

    static let proResMaster = ExportConfiguration(
        preset: .proRes,
        resolution: .uhd4K,
        frameRate: .fps60,
        codec: .proRes422
    )

    static func forPreset(_ preset: ExportPreset) -> ExportConfiguration {
        switch preset {
        case .hd1080p60:
            .hd1080p60
        case .uhd4K60:
            .uhd4K60
        case .proRes:
            .proResMaster
        case .custom:
            ExportConfiguration(
                preset: .custom,
                resolution: .wuxga1200p,
                frameRate: .fps60,
                codec: .hevc
            )
        }
    }

    var suggestedFileName: String {
        let tag = switch preset {
        case .hd1080p60: "1080p60"
        case .uhd4K60: "4K60"
        case .proRes: "ProRes"
        case .custom: "\(resolution.pixelWidth)x\(resolution.pixelHeight)_\(frameRate.rawValue)fps"
        }
        return "ScreenPlay_\(tag).\(codec.fileExtension)"
    }
}

// MARK: - Deterministic Rational CMTime Frame Schedule

/// Pure deterministic frame-stepping schedule mapping `frameIndex in 0..<totalFrames`
/// to exact rational `CMTimeMake(value: frameIndex, timescale: fps)` and scene evaluation timestamps.
nonisolated struct TimelineStepSchedule: Equatable, Sendable {
    let sessionDuration: Double
    let frameRate: ExportFrameRate
    let totalFrames: Int

    var timescale: Int32 {
        frameRate.timescale
    }

    init(duration: Double, frameRate: ExportFrameRate) {
        let clampedDuration = max(0.0, duration)
        self.sessionDuration = clampedDuration
        self.frameRate = frameRate

        let fps = Double(frameRate.rawValue)
        if clampedDuration <= 0.0 {
            self.totalFrames = 1
        } else {
            // Rational frame count covering [0, duration]; e.g. 1.0s @ 60fps -> 60 frames (indices 0..<60)
            let rawCount = (clampedDuration * fps).rounded(.up)
            self.totalFrames = max(1, Int(rawCount))
        }
    }

    /// Exact presentation timestamp `CMTimeMake(value: Int64(frameIndex), timescale: timescale)` (e.g. 60).
    func presentationTime(forFrame frameIndex: Int) -> CMTime {
        CMTimeMake(value: Int64(max(0, frameIndex)), timescale: timescale)
    }

    /// Exact deterministic scene evaluation timestamp `t` (seconds) for `frameIndex`, clamped to `[0, sessionDuration]`.
    func sceneTimestamp(forFrame frameIndex: Int) -> Double {
        guard sessionDuration > 0 else { return 0.0 }
        let rawSeconds = Double(max(0, frameIndex)) / Double(frameRate.rawValue)
        return min(max(0.0, rawSeconds), sessionDuration)
    }

    /// Exact container end-of-session `CMTimeMake(value: Int64(totalFrames), timescale: timescale)`.
    var endSessionTime: CMTime {
        CMTimeMake(value: Int64(totalFrames), timescale: timescale)
    }

    var exportedDurationSeconds: Double {
        Double(totalFrames) / Double(frameRate.rawValue)
    }
}

// MARK: - Shared Video-to-Timeline Synchronization

nonisolated enum VideoTimelineSync {
    /// Computes the synchronized video asset timestamp for `payload` when the desktop timeline is at `timelineTime`.
    /// Shared identically by `CanvasFrameRenderer` and `AudioMixEngine` to guarantee sub-millisecond A/V sync.
    static func mediaTimestamp(
        for payload: VideoWindowPayload,
        windowSpawnTime: Double,
        timelineTime: Double
    ) -> Double {
        let localElapsed = max(0.0, timelineTime - max(0.0, windowSpawnTime))
        if payload.assetURL != nil {
            let target = max(0.0, payload.mediaStartOffset) + localElapsed
            if payload.durationSeconds > 0 {
                // Clamp slightly inside asset duration so the final frame remains valid
                return min(target, max(0.0, payload.durationSeconds - 0.001))
            }
            return target
        } else {
            // Procedural cartoon video stage advances smoothly from its baseline `currentSeconds`
            let cycle = max(1.0, payload.durationSeconds)
            return (max(0.0, payload.currentSeconds) + localElapsed).truncatingRemainder(dividingBy: cycle)
        }
    }
}

// MARK: - Export Progress, Result & Errors

nonisolated struct ExportProgressSnapshot: Equatable, Sendable {
    let renderedFrames: Int
    let totalFrames: Int
    let fractionCompleted: Double
    let elapsedSeconds: Double
    let estimatedRemainingSeconds: Double?
    let currentFrameTimestamp: Double
}

nonisolated struct VideoExportResult: Equatable, Sendable {
    let outputURL: URL
    let configuration: ExportConfiguration
    let totalFramesRendered: Int
    let exportedDurationSeconds: Double
    let renderElapsedSeconds: Double
    let fileSizeBytes: Int64
    let mixedAudioTrackCount: Int
}

nonisolated enum VideoExportError: LocalizedError, Equatable, Sendable {
    case invalidSessionDuration
    case writerInitializationFailed(String)
    case videoInputCannotBeAdded
    case audioInputCannotBeAdded
    case pixelBufferPoolUnavailable
    case frameEncodingFailed(frameIndex: Int, reason: String)
    case audioMixFailed(String)
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSessionDuration:
            "The session has no exportable timeline frames."
        case let .writerInitializationFailed(message):
            "Could not initialize AVAssetWriter: \(message)"
        case .videoInputCannotBeAdded:
            "The selected video codec and resolution cannot be added to the export container."
        case .audioInputCannotBeAdded:
            "The stereo AAC audio track could not be attached to AVAssetWriter."
        case .pixelBufferPoolUnavailable:
            "CVPixelBufferPool was unavailable on AVAssetWriterInputPixelBufferAdaptor."
        case let .frameEncodingFailed(frameIndex, reason):
            "Failed encoding video frame #\(frameIndex): \(reason)"
        case let .audioMixFailed(reason):
            "Audio synchronization and mixing failed: \(reason)"
        case let .writerFailed(reason):
            "Video file finalization failed: \(reason)"
        case .cancelled:
            "Video export was cancelled."
        }
    }
}
