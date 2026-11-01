//
//  VideoExportPipeline.swift
//  OSVideoEditor
//
//  Milestone 3 Headless MP4 / MOV Export Pipeline & Observable Export Manager.
//  Drives `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` and `AudioMixEngine`
//  across concurrent media-pumping queues using deterministic rational `CMTime` stepping.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation

// MARK: - Thread-Safe Export Cancellation Token

nonisolated final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func onCancel(_ handler: @escaping () -> Void) {
        var fireImmediately = false
        lock.lock()
        if cancelled {
            fireImmediately = true
        } else {
            handlers.append(handler)
        }
        lock.unlock()

        if fireImmediately {
            handler()
        }
    }

    func cancel() {
        var callbacks: [() -> Void] = []
        lock.lock()
        if !cancelled {
            cancelled = true
            callbacks = handlers
            handlers.removeAll()
        }
        lock.unlock()

        for cb in callbacks {
            cb()
        }
    }
}

// MARK: - Headless Offscreen Video Export Pipeline

nonisolated final class VideoExportPipeline: @unchecked Sendable {

    private let frameRenderer: CanvasFrameRenderer
    private let audioMixEngine: AudioMixEngine

    init(
        frameRenderer: CanvasFrameRenderer = CanvasFrameRenderer(),
        audioMixEngine: AudioMixEngine = AudioMixEngine()
    ) {
        self.frameRenderer = frameRenderer
        self.audioMixEngine = audioMixEngine
    }

    /// Executes a deterministic offline export of `session` to `outputURL`.
    func runExport(
        session: RecordedSession,
        configuration: ExportConfiguration,
        interpolationCurve: InterpolationCurve = .easeInOut,
        outputURL: URL,
        cancellationToken: ExportCancellationToken = ExportCancellationToken(),
        onProgress: (@Sendable (ExportProgressSnapshot) -> Void)? = nil
    ) async throws -> VideoExportResult {
        let schedule = TimelineStepSchedule(
            duration: max(configuration.frameRate.frameDurationSeconds, session.duration),
            frameRate: configuration.frameRate
        )
        guard schedule.totalFrames > 0 else {
            throw VideoExportError.invalidSessionDuration
        }

        let startUptime = ProcessInfo.processInfo.systemUptime
        let isSecurityScopedDest = outputURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScopedDest {
                outputURL.stopAccessingSecurityScopedResource()
            }
            frameRenderer.invalidateCaches()
        }

        if cancellationToken.isCancelled {
            throw VideoExportError.cancelled
        }

        // Pre-warm video frame decoders and build synchronized stereo audio mix composition
        await frameRenderer.prepare(for: session)

        let audioPlan: PreparedAudioMixPlan?
        let audioCursor: AudioMixSampleCursor?
        if configuration.includeAudioTrack {
            let plan = try await audioMixEngine.buildAudioMixPlan(
                for: session,
                exportDurationSeconds: schedule.exportedDurationSeconds
            )
            audioPlan = plan
            audioCursor = try audioMixEngine.makeSampleCursor(for: plan)
        } else {
            audioPlan = nil
            audioCursor = nil
        }

        if cancellationToken.isCancelled {
            audioCursor?.cancel()
            throw VideoExportError.cancelled
        }

        // Ensure parent directory exists and remove any pre-existing file at `outputURL`
        let fileManager = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw VideoExportError.writerInitializationFailed(
                    "Could not overwrite existing destination file: \(error.localizedDescription)"
                )
            }
        }

        // Configure AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: outputURL,
                fileType: configuration.codec.containerFileType
            )
        } catch {
            audioCursor?.cancel()
            throw VideoExportError.writerInitializationFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let pixelWidth = configuration.resolution.pixelWidth
        let pixelHeight = configuration.resolution.pixelHeight
        let videoSettings = Self.makeVideoOutputSettings(
            width: pixelWidth,
            height: pixelHeight,
            configuration: configuration
        )

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            audioCursor?.cancel()
            throw VideoExportError.videoInputCannotBeAdded
        }
        writer.add(videoInput)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: pixelWidth,
            kCVPixelBufferHeightKey as String: pixelHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        var audioInput: AVAssetWriterInput?
        if configuration.includeAudioTrack {
            let aacInput = AudioMixEngine.makeStereoAACWriterInput()
            guard writer.canAdd(aacInput) else {
                audioCursor?.cancel()
                throw VideoExportError.audioInputCannotBeAdded
            }
            writer.add(aacInput)
            audioInput = aacInput
        }

        guard writer.startWriting() else {
            audioCursor?.cancel()
            let msg = writer.error?.localizedDescription ?? "AVAssetWriter failed to start writing."
            throw VideoExportError.writerInitializationFailed(msg)
        }
        writer.startSession(atSourceTime: .zero)

        let mixedAudioCount = audioPlan?.scheduledTracks.count ?? 0

        return try await withTaskCancellationHandler {
            try await pumpMediaQueues(
                writer: writer,
                videoInput: videoInput,
                adaptor: pixelBufferAdaptor,
                audioInput: audioInput,
                audioCursor: audioCursor,
                session: session,
                configuration: configuration,
                interpolationCurve: interpolationCurve,
                schedule: schedule,
                outputURL: outputURL,
                startUptime: startUptime,
                mixedAudioCount: mixedAudioCount,
                cancellationToken: cancellationToken,
                onProgress: onProgress
            )
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    // MARK: - Concurrent Multi-Queue Frame & Audio Pumping

    private func pumpMediaQueues(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioInput: AVAssetWriterInput?,
        audioCursor: AudioMixSampleCursor?,
        session: RecordedSession,
        configuration: ExportConfiguration,
        interpolationCurve: InterpolationCurve,
        schedule: TimelineStepSchedule,
        outputURL: URL,
        startUptime: TimeInterval,
        mixedAudioCount: Int,
        cancellationToken: ExportCancellationToken,
        onProgress: (@Sendable (ExportProgressSnapshot) -> Void)?
    ) async throws -> VideoExportResult {
        nonisolated final class PumpCoordinator: @unchecked Sendable {
            let lock = NSLock()
            let writer: AVAssetWriter
            let videoInput: AVAssetWriterInput
            let adaptor: AVAssetWriterInputPixelBufferAdaptor
            let audioInput: AVAssetWriterInput?
            let audioCursor: AudioMixSampleCursor?

            var nextFrameIndex: Int = 0
            var videoFinished: Bool = false
            var audioFinished: Bool
            var finalizationStarted: Bool = false
            var continuationResumed: Bool = false
            var smoothedFrameDuration: Double?

            init(
                writer: AVAssetWriter,
                videoInput: AVAssetWriterInput,
                adaptor: AVAssetWriterInputPixelBufferAdaptor,
                audioInput: AVAssetWriterInput?,
                audioCursor: AudioMixSampleCursor?
            ) {
                self.writer = writer
                self.videoInput = videoInput
                self.adaptor = adaptor
                self.audioInput = audioInput
                self.audioCursor = audioCursor
                self.audioFinished = !(audioInput != nil && audioCursor != nil)
            }
        }

        let coordinator = PumpCoordinator(
            writer: writer,
            videoInput: videoInput,
            adaptor: adaptor,
            audioInput: audioInput,
            audioCursor: audioCursor
        )
        let videoPumpQueue = DispatchQueue(
            label: "com.screenplay.export.videoPump",
            qos: .userInitiated
        )
        let audioPumpQueue = DispatchQueue(
            label: "com.screenplay.export.audioPump",
            qos: .userInitiated
        )
        let completionQueue = DispatchQueue(
            label: "com.screenplay.export.completion",
            qos: .userInitiated
        )

        let outputSize = configuration.resolution.pixelSize
        let includeMenuBar = configuration.includeDesktopMenuBar
        let renderer = self.frameRenderer

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VideoExportResult, Error>) in
            @Sendable func resumeOnce(with result: Result<VideoExportResult, Error>) {
                coordinator.lock.lock()
                if coordinator.continuationResumed {
                    coordinator.lock.unlock()
                    return
                }
                coordinator.continuationResumed = true
                coordinator.lock.unlock()

                continuation.resume(with: result)
            }

            @Sendable func abortExport(with error: VideoExportError) {
                completionQueue.async {
                    coordinator.audioCursor?.cancel()
                    if coordinator.writer.status == .writing {
                        coordinator.writer.cancelWriting()
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    resumeOnce(with: .failure(error))
                }
            }

            @Sendable func finalizeIfBothStreamsComplete() {
                coordinator.lock.lock()
                let shouldFinalize = coordinator.videoFinished
                    && coordinator.audioFinished
                    && !coordinator.finalizationStarted
                    && !coordinator.continuationResumed
                if shouldFinalize {
                    coordinator.finalizationStarted = true
                }
                coordinator.lock.unlock()

                guard shouldFinalize else { return }

                if cancellationToken.isCancelled {
                    abortExport(with: .cancelled)
                    return
                }

                completionQueue.async {
                    let activeWriter = coordinator.writer
                    guard activeWriter.status == .writing else {
                        let reason = activeWriter.error?.localizedDescription ?? "Writer entered unexpected status \(activeWriter.status.rawValue)"
                        try? FileManager.default.removeItem(at: outputURL)
                        resumeOnce(with: .failure(VideoExportError.writerFailed(reason)))
                        return
                    }

                    activeWriter.endSession(atSourceTime: schedule.endSessionTime)
                    activeWriter.finishWriting {
                        if cancellationToken.isCancelled || activeWriter.status == .cancelled {
                            try? FileManager.default.removeItem(at: outputURL)
                            resumeOnce(with: .failure(VideoExportError.cancelled))
                            return
                        }

                        guard activeWriter.status == .completed else {
                            let reason = activeWriter.error?.localizedDescription ?? "Unknown AVAssetWriter completion error."
                            try? FileManager.default.removeItem(at: outputURL)
                            resumeOnce(with: .failure(VideoExportError.writerFailed(reason)))
                            return
                        }

                        let totalElapsed = max(0.001, ProcessInfo.processInfo.systemUptime - startUptime)
                        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

                        let exportResult = VideoExportResult(
                            outputURL: outputURL,
                            configuration: configuration,
                            totalFramesRendered: schedule.totalFrames,
                            exportedDurationSeconds: schedule.exportedDurationSeconds,
                            renderElapsedSeconds: totalElapsed,
                            fileSizeBytes: fileSize,
                            mixedAudioTrackCount: mixedAudioCount
                        )
                        resumeOnce(with: .success(exportResult))
                    }
                }
            }

            // Wire immediate cancellation callback
            cancellationToken.onCancel {
                abortExport(with: .cancelled)
            }

            // 1. Video Frame Pump via `requestMediaDataWhenReady(on:)`
            coordinator.videoInput.requestMediaDataWhenReady(on: videoPumpQueue) {
                let vInput = coordinator.videoInput
                let vAdaptor = coordinator.adaptor
                let activeWriter = coordinator.writer

                while vInput.isReadyForMoreMediaData {
                    var shouldExitLoop = false

                    autoreleasepool {
                        if cancellationToken.isCancelled {
                            coordinator.lock.lock()
                            let alreadyDone = coordinator.videoFinished
                            coordinator.videoFinished = true
                            coordinator.lock.unlock()
                            if !alreadyDone {
                                vInput.markAsFinished()
                            }
                            abortExport(with: .cancelled)
                            shouldExitLoop = true
                            return
                        }

                        coordinator.lock.lock()
                        if coordinator.videoFinished || coordinator.continuationResumed {
                            coordinator.lock.unlock()
                            shouldExitLoop = true
                            return
                        }

                        if coordinator.nextFrameIndex >= schedule.totalFrames {
                            coordinator.videoFinished = true
                            coordinator.lock.unlock()
                            vInput.markAsFinished()
                            finalizeIfBothStreamsComplete()
                            shouldExitLoop = true
                            return
                        }

                        let frameIndex = coordinator.nextFrameIndex
                        coordinator.nextFrameIndex += 1
                        coordinator.lock.unlock()

                        let frameRenderStart = ProcessInfo.processInfo.systemUptime
                        let pts = schedule.presentationTime(forFrame: frameIndex)
                        let sceneTime = schedule.sceneTimestamp(forFrame: frameIndex)

                        do {
                            let pixelBuffer = try renderer.renderPixelBuffer(
                                for: session,
                                at: sceneTime,
                                curve: interpolationCurve,
                                outputSize: outputSize,
                                includeMenuBar: includeMenuBar,
                                pixelBufferPool: vAdaptor.pixelBufferPool
                            )

                            if cancellationToken.isCancelled {
                                coordinator.lock.lock()
                                let alreadyDone = coordinator.videoFinished
                                coordinator.videoFinished = true
                                coordinator.lock.unlock()
                                if !alreadyDone {
                                    vInput.markAsFinished()
                                }
                                abortExport(with: .cancelled)
                                shouldExitLoop = true
                                return
                            }

                            guard activeWriter.status == .writing,
                                  vAdaptor.append(pixelBuffer, withPresentationTime: pts) else {
                                let writerReason = activeWriter.error?.localizedDescription ?? "PixelBuffer adaptor append returned false."
                                coordinator.lock.lock()
                                coordinator.videoFinished = true
                                coordinator.lock.unlock()
                                vInput.markAsFinished()
                                abortExport(with: .frameEncodingFailed(frameIndex: frameIndex, reason: writerReason))
                                shouldExitLoop = true
                                return
                            }
                        } catch {
                            coordinator.lock.lock()
                            coordinator.videoFinished = true
                            coordinator.lock.unlock()
                            vInput.markAsFinished()
                            abortExport(
                                with: .frameEncodingFailed(
                                    frameIndex: frameIndex,
                                    reason: error.localizedDescription
                                )
                            )
                            shouldExitLoop = true
                            return
                        }

                        // Emit Progress & Smoothed ETA
                        let now = ProcessInfo.processInfo.systemUptime
                        let frameDt = max(0.000_1, now - frameRenderStart)
                        let completedFrames = frameIndex + 1
                        let remainingFrames = max(0, schedule.totalFrames - completedFrames)
                        let elapsed = max(0.0, now - startUptime)

                        coordinator.lock.lock()
                        let updatedAvg: Double
                        if let prev = coordinator.smoothedFrameDuration {
                            updatedAvg = prev * 0.85 + frameDt * 0.15
                        } else {
                            updatedAvg = frameDt
                        }
                        coordinator.smoothedFrameDuration = updatedAvg
                        coordinator.lock.unlock()

                        let eta: Double? = completedFrames >= 2
                            ? max(0.0, Double(remainingFrames) * updatedAvg)
                            : nil
                        let fraction = min(1.0, Double(completedFrames) / Double(schedule.totalFrames))

                        onProgress?(
                            ExportProgressSnapshot(
                                renderedFrames: completedFrames,
                                totalFrames: schedule.totalFrames,
                                fractionCompleted: fraction,
                                elapsedSeconds: elapsed,
                                estimatedRemainingSeconds: eta,
                                currentFrameTimestamp: sceneTime
                            )
                        )
                    }

                    if shouldExitLoop {
                        break
                    }
                }
            }

            // 2. Concurrent Stereo AAC Audio Pump via `requestMediaDataWhenReady(on:)`
            if let initialAudioInput = coordinator.audioInput, coordinator.audioCursor != nil {
                initialAudioInput.requestMediaDataWhenReady(on: audioPumpQueue) {
                    guard let aInput = coordinator.audioInput,
                          let aCursor = coordinator.audioCursor else {
                        return
                    }
                    let activeWriter = coordinator.writer

                    while aInput.isReadyForMoreMediaData {
                        var shouldStopAudio = false

                        autoreleasepool {
                            if cancellationToken.isCancelled {
                                coordinator.lock.lock()
                                let alreadyDone = coordinator.audioFinished
                                coordinator.audioFinished = true
                                coordinator.lock.unlock()
                                aCursor.cancel()
                                if !alreadyDone {
                                    aInput.markAsFinished()
                                }
                                abortExport(with: .cancelled)
                                shouldStopAudio = true
                                return
                            }

                            coordinator.lock.lock()
                            if coordinator.audioFinished || coordinator.continuationResumed {
                                coordinator.lock.unlock()
                                shouldStopAudio = true
                                return
                            }
                            coordinator.lock.unlock()

                            if let sampleBuffer = aCursor.nextSampleBuffer() {
                                guard activeWriter.status == .writing,
                                      aInput.append(sampleBuffer) else {
                                    let reason = activeWriter.error?.localizedDescription ?? "AAC audio append failed."
                                    coordinator.lock.lock()
                                    coordinator.audioFinished = true
                                    coordinator.lock.unlock()
                                    aCursor.cancel()
                                    aInput.markAsFinished()
                                    abortExport(with: .audioMixFailed(reason))
                                    shouldStopAudio = true
                                    return
                                }
                            } else {
                                coordinator.lock.lock()
                                coordinator.audioFinished = true
                                coordinator.lock.unlock()
                                aInput.markAsFinished()
                                finalizeIfBothStreamsComplete()
                                shouldStopAudio = true
                            }
                        }

                        if shouldStopAudio {
                            break
                        }
                    }
                }
            }
        }
    }

    // MARK: - VideoToolbox Output Settings Builder

    private static func makeVideoOutputSettings(
        width: Int,
        height: Int,
        configuration: ExportConfiguration
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: configuration.codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        switch configuration.codec {
        case .h264:
            var compression: [String: Any] = [
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue * 2,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate.rawValue
            ]
            if let bitRate = configuration.codec.targetAverageBitRate(
                width: width,
                height: height,
                frameRate: configuration.frameRate
            ) {
                compression[AVVideoAverageBitRateKey] = bitRate
            }
            settings[AVVideoCompressionPropertiesKey] = compression

        case .hevc:
            var compression: [String: Any] = [
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue * 2,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate.rawValue
            ]
            if let bitRate = configuration.codec.targetAverageBitRate(
                width: width,
                height: height,
                frameRate: configuration.frameRate
            ) {
                compression[AVVideoAverageBitRateKey] = bitRate
            }
            settings[AVVideoCompressionPropertiesKey] = compression

        case .proRes422:
            break
        }

        return settings
    }
}

// MARK: - Main-Actor Observable Export Manager (UI & Programmatic Coordinator)

@Observable
final class VideoExportManager {

    enum Phase: Equatable {
        case idle
        case preparing
        case exporting
        case completed(VideoExportResult)
        case cancelled
        case failed(String)
    }

    // MARK: - Observable State

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0.0
    private(set) var renderedFrames: Int = 0
    private(set) var totalFrames: Int = 0
    private(set) var elapsedSeconds: Double = 0.0
    private(set) var estimatedRemainingSeconds: Double?
    private(set) var currentFrameTimestamp: Double = 0.0
    private(set) var latestResult: VideoExportResult?

    var configuration: ExportConfiguration = .hd1080p60

    var isExporting: Bool {
        switch phase {
        case .preparing, .exporting:
            true
        default:
            false
        }
    }

    // MARK: - Internal Pipeline Handles

    @ObservationIgnored
    private let pipeline: VideoExportPipeline
    @ObservationIgnored
    private var activeTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeCancellationToken: ExportCancellationToken?
    @ObservationIgnored
    private var exportClockTask: Task<Void, Never>?
    @ObservationIgnored
    private var exportStartUptime: TimeInterval = 0

    // MARK: - Initialization

    init(pipeline: VideoExportPipeline = VideoExportPipeline()) {
        self.pipeline = pipeline
    }

    // MARK: - Preset Selection

    func applyPreset(_ preset: ExportPreset) {
        guard !isExporting else { return }
        configuration = ExportConfiguration.forPreset(preset)
    }

    func reset() {
        guard !isExporting else { return }
        phase = .idle
        progress = 0.0
        renderedFrames = 0
        totalFrames = 0
        elapsedSeconds = 0.0
        estimatedRemainingSeconds = nil
        currentFrameTimestamp = 0.0
    }

    // MARK: - Fire-and-Observe UI Export Entry Point

    func startExport(
        session: RecordedSession,
        configuration: ExportConfiguration? = nil,
        interpolationCurve: InterpolationCurve,
        destinationURL: URL
    ) {
        guard !isExporting else { return }
        let activeConfig = configuration ?? self.configuration
        self.configuration = activeConfig

        activeTask = Task {
            do {
                _ = try await export(
                    session: session,
                    configuration: activeConfig,
                    interpolationCurve: interpolationCurve,
                    to: destinationURL
                )
            } catch {
                // Phase transitions (.cancelled / .failed) are already published by `export(...)`
            }
        }
    }

    // MARK: - Structured Async Export Entry Point

    @discardableResult
    func export(
        session: RecordedSession,
        configuration: ExportConfiguration,
        interpolationCurve: InterpolationCurve = .easeInOut,
        to destinationURL: URL
    ) async throws -> VideoExportResult {
        let schedule = TimelineStepSchedule(
            duration: max(configuration.frameRate.frameDurationSeconds, session.duration),
            frameRate: configuration.frameRate
        )

        let token = ExportCancellationToken()
        self.activeCancellationToken = token
        self.configuration = configuration
        self.phase = .preparing
        self.progress = 0.0
        self.renderedFrames = 0
        self.totalFrames = schedule.totalFrames
        self.elapsedSeconds = 0.0
        self.estimatedRemainingSeconds = nil
        self.currentFrameTimestamp = 0.0
        self.latestResult = nil
        self.exportStartUptime = ProcessInfo.processInfo.systemUptime

        startLiveElapsedTicker()
        defer {
            stopLiveElapsedTicker()
            if activeCancellationToken === token {
                activeCancellationToken = nil
            }
        }

        let pipelineRef = self.pipeline
        let onProgress: @Sendable (ExportProgressSnapshot) -> Void = { [weak self] snapshot in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.applyProgressSnapshot(snapshot, token: token)
            }
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await pipelineRef.runExport(
                    session: session,
                    configuration: configuration,
                    interpolationCurve: interpolationCurve,
                    outputURL: destinationURL,
                    cancellationToken: token,
                    onProgress: onProgress
                )
            }.value

            self.renderedFrames = result.totalFramesRendered
            self.totalFrames = result.totalFramesRendered
            self.progress = 1.0
            self.elapsedSeconds = result.renderElapsedSeconds
            self.estimatedRemainingSeconds = 0.0
            self.latestResult = result
            self.phase = .completed(result)
            return result
        } catch let exportErr as VideoExportError {
            if case .cancelled = exportErr {
                self.phase = .cancelled
            } else {
                self.phase = .failed(exportErr.localizedDescription)
            }
            throw exportErr
        } catch is CancellationError {
            token.cancel()
            self.phase = .cancelled
            throw VideoExportError.cancelled
        } catch {
            self.phase = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Cancellation

    func cancelExport() {
        activeCancellationToken?.cancel()
        activeTask?.cancel()
        activeTask = nil
        stopLiveElapsedTicker()
        if isExporting {
            phase = .cancelled
        }
    }

    // MARK: - Smooth Elapsed Timer While Encoding Heavy 4K Frames

    private func startLiveElapsedTicker() {
        exportClockTask?.cancel()
        exportClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.isExporting else { break }
                self.elapsedSeconds = max(
                    self.elapsedSeconds,
                    ProcessInfo.processInfo.systemUptime - self.exportStartUptime
                )
            }
        }
    }

    private func applyProgressSnapshot(
        _ snapshot: ExportProgressSnapshot,
        token: ExportCancellationToken
    ) {
        guard activeCancellationToken === token else { return }
        if phase == .preparing {
            phase = .exporting
        }
        renderedFrames = snapshot.renderedFrames
        totalFrames = snapshot.totalFrames
        progress = snapshot.fractionCompleted
        elapsedSeconds = max(elapsedSeconds, snapshot.elapsedSeconds)
        estimatedRemainingSeconds = snapshot.estimatedRemainingSeconds
        currentFrameTimestamp = snapshot.currentFrameTimestamp
    }

    private func stopLiveElapsedTicker() {
        exportClockTask?.cancel()
        exportClockTask = nil
    }
}
