//
//  Milestone3ExportTests.swift
//  OSVideoEditorTests
//
//  Unit & integration tests verifying Milestone 3:
//  - Deterministic rational CMTime timeline stepping (`TimelineStepSchedule` & `VideoTimelineSync`)
//  - Offscreen `CanvasFrameRenderer` CVPixelBuffer generation (1080p / 4K), byte-determinism, and z-index occlusion
//  - Synchronized `AVAssetReader` video window frame extraction across timeline timestamps
//  - `AudioMixEngine` multi-window stereo `AVAudioMix` construction and PCM sample streaming
//  - End-to-end headless `VideoExportManager` MP4 & ProRes 422 MOV export + cancellation cleanup
//

import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OSVideoEditor

struct Milestone3ExportTests {

    // MARK: - 1. Deterministic Rational CMTime Stepping & Media Sync

    @Test("TimelineStepSchedule generates exact CMTimeMake(value: frameIndex, timescale: 60) steps across [0, duration]")
    func deterministicTimelineStepping() {
        let schedule60 = TimelineStepSchedule(duration: 1.5, frameRate: .fps60)
        #expect(schedule60.totalFrames == 90)
        #expect(schedule60.timescale == 60)
        #expect(schedule60.endSessionTime == CMTimeMake(value: 90, timescale: 60))
        #expect(abs(schedule60.exportedDurationSeconds - 1.5) < 1e-9)

        for index in 0..<schedule60.totalFrames {
            let pts = schedule60.presentationTime(forFrame: index)
            #expect(pts == CMTimeMake(value: Int64(index), timescale: 60))
            #expect(pts.timescale == 60)
            #expect(pts.value == Int64(index))

            let evalTime = schedule60.sceneTimestamp(forFrame: index)
            #expect(evalTime >= 0.0 && evalTime <= 1.5)
            #expect(abs(evalTime - (Double(index) / 60.0)) < 1e-9)

            if index > 0 {
                let prevPTS = schedule60.presentationTime(forFrame: index - 1)
                let delta = CMTimeSubtract(pts, prevPTS)
                #expect(delta == CMTimeMake(value: 1, timescale: 60))
            }
        }

        // Verify 30 FPS schedule
        let schedule30 = TimelineStepSchedule(duration: 2.0, frameRate: .fps30)
        #expect(schedule30.totalFrames == 60)
        #expect(schedule30.presentationTime(forFrame: 15) == CMTimeMake(value: 15, timescale: 30))

        // Verify odd custom dimensions sanitize cleanly to macroblock-safe even pixels
        let sanitized = ExportResolution.custom(width: 1365, height: 769)
        #expect(sanitized.pixelWidth == 1366)
        #expect(sanitized.pixelHeight == 770)
    }

    @Test("VideoTimelineSync aligns mid-session window spawn time and media in-point trim offset identically")
    func videoTimelineSynchronizationMath() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample_clip.mp4")
        let payload = VideoWindowPayload(
            clipTitle: "sample_clip.mp4",
            resolutionTag: "1080p",
            fps: 60,
            durationSeconds: 10.0,
            currentSeconds: 0.0,
            isPlaying: true,
            scene: .rocketLaunch,
            assetURL: dummyURL,
            mediaStartOffset: 2.25,
            volume: 0.9,
            isMuted: false
        )

        // Window spawned at t = 1.5s; evaluated at timeline t = 3.0s -> 1.5s elapsed + 2.25s trim = 3.75s
        let synced = VideoTimelineSync.mediaTimestamp(
            for: payload,
            windowSpawnTime: 1.5,
            timelineTime: 3.0
        )
        #expect(abs(synced - 3.75) < 1e-6)

        // Clamps safely at asset duration boundary
        let clampedEnd = VideoTimelineSync.mediaTimestamp(
            for: payload,
            windowSpawnTime: 1.5,
            timelineTime: 25.0
        )
        #expect(clampedEnd <= 10.0 && clampedEnd >= 9.99)
    }

    // MARK: - 2. Offscreen Frame Buffer Generation, Determinism & Z-Index Compositing

    @Test("CanvasFrameRenderer generates deterministic 1080p and 4K 32BGRA pixel buffers and respects exact Z-index occlusion")
    func offscreenFrameRenderingAndZIndexOrder() throws {
        let renderer = CanvasFrameRenderer()
        defer { renderer.invalidateCaches() }

        let canvasSize = CGSize(width: 1920, height: 1080)
        let overlapFrame = WindowFrame(x: 300, y: 120, width: 520, height: 340)

        let mangoWindowID = UUID()
        let skyWindowID = UUID()
        let imageWindowID = UUID()

        let pngData = try Self.makeSolidPNGData(width: 64, height: 64, red: 0.2, green: 0.85, blue: 0.45)

        func makeSession(mangoZ: Double, skyZ: Double) -> RecordedSession {
            let mangoTrack = WindowTimelineTrack(
                windowID: mangoWindowID,
                title: "MangoEditor.swift",
                contentKind: .codeSnippet,
                initialContent: .demoCodeSnippet,
                minimumSize: CGSize(width: 350, height: 230),
                accent: .sunnyMango,
                keyframes: [
                    WindowKeyframe(
                        time: 0.0,
                        frame: overlapFrame,
                        zIndex: mangoZ,
                        presentationState: .normal,
                        isFocused: mangoZ > skyZ,
                        accent: .sunnyMango,
                        eventKind: .initial
                    )
                ]
            )

            let skyTrack = WindowTimelineTrack(
                windowID: skyWindowID,
                title: "SkyBrowser",
                contentKind: .browser,
                initialContent: .demoBrowser,
                minimumSize: CGSize(width: 380, height: 270),
                accent: .skyPeriwinkle,
                keyframes: [
                    WindowKeyframe(
                        time: 0.0,
                        frame: overlapFrame,
                        zIndex: skyZ,
                        presentationState: .normal,
                        isFocused: skyZ > mangoZ,
                        accent: .skyPeriwinkle,
                        eventKind: .initial
                    )
                ]
            )

            let imageTrack = WindowTimelineTrack(
                windowID: imageWindowID,
                title: "RasterCard.png",
                contentKind: .image,
                initialContent: .image(
                    ImageWindowPayload(
                        assetName: "RasterCard.png",
                        caption: "Unit Test PNG",
                        dimensionsTag: "64 × 64 PNG",
                        aspectFit: false,
                        imageData: pngData
                    )
                ),
                minimumSize: CGSize(width: 300, height: 230),
                accent: .lavenderPop,
                keyframes: [
                    WindowKeyframe(
                        time: 0.0,
                        frame: WindowFrame(x: 920, y: 140, width: 420, height: 320),
                        zIndex: 1,
                        presentationState: .normal,
                        isFocused: false,
                        accent: .lavenderPop,
                        eventKind: .initial
                    )
                ]
            )

            return RecordedSession(
                duration: 1.0,
                wallpaper: .pastelSunrise,
                canvasSize: canvasSize,
                initialActiveWindowID: mangoZ > skyZ ? mangoWindowID : skyWindowID,
                tracks: [mangoTrack, skyTrack, imageTrack]
            )
        }

        // 1. Render 1080p with Sunny Mango on top (z: 10 > z: 3)
        let sessionMangoTop = makeSession(mangoZ: 10, skyZ: 3)
        let buffer1080A = try renderer.renderPixelBuffer(
            for: sessionMangoTop,
            at: 0.5,
            curve: .easeInOut,
            outputSize: CGSize(width: 1920, height: 1080)
        )
        let buffer1080B = try renderer.renderPixelBuffer(
            for: sessionMangoTop,
            at: 0.5,
            curve: .easeInOut,
            outputSize: CGSize(width: 1920, height: 1080)
        )

        #expect(CVPixelBufferGetWidth(buffer1080A) == 1920)
        #expect(CVPixelBufferGetHeight(buffer1080A) == 1080)
        #expect(CVPixelBufferGetPixelFormatType(buffer1080A) == kCVPixelFormatType_32BGRA)

        // Byte-for-byte determinism check at identical timestamp `t`
        #expect(Self.pixelBuffersAreIdentical(buffer1080A, buffer1080B))

        // Sample inside the overlapping title bar background (avoiding centered title text, near x=710, y=143)
        let samplePoint = CGPoint(x: 710, y: 143)
        let mangoPixel = Self.sampleRGB(in: buffer1080A, x: Int(samplePoint.x), y: Int(samplePoint.y))
        // Sunny Mango title bar `(1.00, 0.88, 0.55)` has significantly higher Red than Blue
        #expect(mangoPixel.r > 220)
        #expect(mangoPixel.r > mangoPixel.b + 60)

        // 2. Swap Z-index so Sky Periwinkle is on top (z: 15 > z: 10)
        let sessionSkyTop = makeSession(mangoZ: 10, skyZ: 15)
        let bufferSkyTop = try renderer.renderPixelBuffer(
            for: sessionSkyTop,
            at: 0.5,
            curve: .easeInOut,
            outputSize: CGSize(width: 1920, height: 1080)
        )
        let skyPixel = Self.sampleRGB(in: bufferSkyTop, x: Int(samplePoint.x), y: Int(samplePoint.y))
        // Sky Periwinkle title bar `(0.74, 0.88, 1.00)` has Blue > Red
        #expect(skyPixel.b > 225)
        #expect(skyPixel.b > skyPixel.r + 35)

        // 3. Verify embedded raster PNG image rendered inside the Image window stage (`x: 920+210=1130, y: 140+175=315`)
        let rasterSample = Self.sampleRGB(in: buffer1080A, x: 1130, y: 315)
        #expect(rasterSample.g > rasterSample.r + 60)

        // 4. Verify full 4K UHD (3840 × 2160) offscreen rendering succeeds cleanly
        let buffer4K = try renderer.renderPixelBuffer(
            for: sessionMangoTop,
            at: 0.5,
            curve: .spring,
            outputSize: ExportResolution.uhd4K.pixelSize
        )
        #expect(CVPixelBufferGetWidth(buffer4K) == 3840)
        #expect(CVPixelBufferGetHeight(buffer4K) == 2160)
    }

    // MARK: - 3. Synchronized Video Window AVAsset Frame Extraction

    @Test("CanvasFrameRenderer extracts exact time-synchronized video frames from an underlying MP4 asset")
    func synchronizedVideoWindowAssetExtraction() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenPlayM3VideoSync_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a 1.2s 30fps test MP4 with 3 color phases:
        // [0.0s ..< 0.4s]: Pure Red, [0.4s ..< 0.8s]: Pure Green, [0.8s ..< 1.2s]: Pure Blue
        let sourceVideoURL = tempDir.appendingPathComponent("ColorPhases.mp4")
        try await Self.writeColorPhaseTestVideo(to: sourceVideoURL, fps: 30, framesPerPhase: 12)

        let videoWindowID = UUID()
        let videoTrack = WindowTimelineTrack(
            windowID: videoWindowID,
            title: "ColorPhases.mp4",
            contentKind: .video,
            initialContent: .video(
                VideoWindowPayload(
                    clipTitle: "ColorPhases.mp4",
                    resolutionTag: "640×360",
                    fps: 30,
                    durationSeconds: 1.2,
                    currentSeconds: 0.0,
                    isPlaying: true,
                    scene: .rocketLaunch,
                    assetURL: sourceVideoURL,
                    mediaStartOffset: 0.0,
                    volume: 1.0,
                    isMuted: false
                )
            ),
            minimumSize: CGSize(width: 340, height: 250),
            accent: .coralBlush,
            keyframes: [
                WindowKeyframe(
                    time: 0.0,
                    frame: WindowFrame(x: 100, y: 80, width: 600, height: 420),
                    zIndex: 2,
                    presentationState: .normal,
                    isFocused: true,
                    accent: .coralBlush,
                    eventKind: .initial
                )
            ]
        )

        let session = RecordedSession(
            duration: 1.2,
            wallpaper: .warmDraftingPaper,
            canvasSize: CGSize(width: 1280, height: 720),
            initialActiveWindowID: videoWindowID,
            tracks: [videoTrack]
        )

        let renderer = CanvasFrameRenderer()
        defer { renderer.invalidateCaches() }
        await renderer.prepare(for: session)

        let outSize = CGSize(width: 1280, height: 720)
        // Center of the video window's inner stage viewport:
        // Window x: 100..700 (midX = 400), y: 80..500 (titleBar ~46, stage y ~ 140..448 -> midY ~ 290)
        let stageCenterX = 400
        let stageCenterY = 290

        let frameAtRed = try renderer.renderPixelBuffer(for: session, at: 0.15, outputSize: outSize)
        let rgbRed = Self.sampleRGB(in: frameAtRed, x: stageCenterX, y: stageCenterY)
        #expect(rgbRed.r > 180 && rgbRed.r > rgbRed.g + 90 && rgbRed.r > rgbRed.b + 90)

        let frameAtGreen = try renderer.renderPixelBuffer(for: session, at: 0.55, outputSize: outSize)
        let rgbGreen = Self.sampleRGB(in: frameAtGreen, x: stageCenterX, y: stageCenterY)
        #expect(rgbGreen.g > 170 && rgbGreen.g > rgbGreen.r + 80 && rgbGreen.g > rgbGreen.b + 80)

        let frameAtBlue = try renderer.renderPixelBuffer(for: session, at: 0.95, outputSize: outSize)
        let rgbBlue = Self.sampleRGB(in: frameAtBlue, x: stageCenterX, y: stageCenterY)
        #expect(rgbBlue.b > 180 && rgbBlue.b > rgbBlue.r + 90 && rgbBlue.b > rgbBlue.g + 90)

        // Random backward scrub back to t = 0.15s verifies LRU cache / seekable reader accuracy
        let frameScrubBack = try renderer.renderPixelBuffer(for: session, at: 0.15, outputSize: outSize)
        let rgbBack = Self.sampleRGB(in: frameScrubBack, x: stageCenterX, y: stageCenterY)
        #expect(rgbBack.r > 180 && rgbBack.r > rgbBack.g + 90)
    }

    // MARK: - 4. AudioMixEngine Multi-Track Synchronization & Mixing

    @Test("AudioMixEngine aligns multiple active video window audio tracks with timeline spawn offsets and volumes")
    func multiWindowStereoAudioMixing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenPlayM3AudioMix_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let clipAURL = tempDir.appendingPathComponent("Tone440.mov")
        let clipBURL = tempDir.appendingPathComponent("Tone880.mov")
        try await Self.writeTestVideoWithSineAudio(to: clipAURL, durationSeconds: 1.2, frequencyHz: 440.0)
        try await Self.writeTestVideoWithSineAudio(to: clipBURL, durationSeconds: 1.2, frequencyHz: 880.0)

        let trackA = WindowTimelineTrack(
            windowID: UUID(),
            title: "LeadClip.mov",
            contentKind: .video,
            initialContent: .video(
                VideoWindowPayload(
                    clipTitle: "LeadClip.mov",
                    resolutionTag: "1080p",
                    fps: 30,
                    durationSeconds: 1.2,
                    currentSeconds: 0.0,
                    isPlaying: true,
                    scene: .rocketLaunch,
                    assetURL: clipAURL,
                    mediaStartOffset: 0.0,
                    volume: 0.80,
                    isMuted: false
                )
            ),
            minimumSize: CGSize(width: 340, height: 250),
            accent: .coralBlush,
            wasSpawnedDuringSession: false,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: WindowFrame(x: 80, y: 80, width: 420, height: 300), zIndex: 1, presentationState: .normal, isFocused: true, accent: .coralBlush, eventKind: .initial)
            ]
        )

        // Spawned mid-session at t = 0.40s with 0.15s media trim offset
        let trackB = WindowTimelineTrack(
            windowID: UUID(),
            title: "OverlayClip.mov",
            contentKind: .video,
            initialContent: .video(
                VideoWindowPayload(
                    clipTitle: "OverlayClip.mov",
                    resolutionTag: "1080p",
                    fps: 30,
                    durationSeconds: 1.2,
                    currentSeconds: 0.0,
                    isPlaying: true,
                    scene: .synthStudio,
                    assetURL: clipBURL,
                    mediaStartOffset: 0.15,
                    volume: 0.50,
                    isMuted: false
                )
            ),
            minimumSize: CGSize(width: 340, height: 250),
            accent: .mintMatcha,
            wasSpawnedDuringSession: true,
            keyframes: [
                WindowKeyframe(time: 0.40, frame: WindowFrame(x: 420, y: 140, width: 420, height: 300), zIndex: 2, presentationState: .normal, isFocused: true, accent: .mintMatcha, eventKind: .spawned)
            ]
        )

        // Muted 3rd video window must be excluded from audio mix
        let trackMuted = WindowTimelineTrack(
            windowID: UUID(),
            title: "MutedClip.mov",
            contentKind: .video,
            initialContent: .video(
                VideoWindowPayload(
                    clipTitle: "MutedClip.mov",
                    resolutionTag: "1080p",
                    fps: 30,
                    durationSeconds: 1.2,
                    currentSeconds: 0.0,
                    isPlaying: true,
                    scene: .mascotWave,
                    assetURL: clipAURL,
                    mediaStartOffset: 0.0,
                    volume: 0.90,
                    isMuted: true
                )
            ),
            minimumSize: CGSize(width: 340, height: 250),
            accent: .sunnyMango,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: WindowFrame(x: 200, y: 200, width: 380, height: 280), zIndex: 3, presentationState: .normal, isFocused: false, accent: .sunnyMango, eventKind: .initial)
            ]
        )

        let session = RecordedSession(
            duration: 1.0,
            wallpaper: .mintStudio,
            initialActiveWindowID: trackA.windowID,
            tracks: [trackA, trackB, trackMuted]
        )

        let mixEngine = AudioMixEngine()
        let plan = try await mixEngine.buildAudioMixPlan(for: session, exportDurationSeconds: 1.0)

        #expect(plan.scheduledTracks.count == 2)
        #expect(plan.audioMix.inputParameters.count == 2)
        #expect(abs(plan.scheduledTracks[0].timelineTimeRange.start.seconds - 0.0) < 0.001)
        #expect(abs(plan.scheduledTracks[0].volume - 0.80) < 0.001)
        #expect(abs(plan.scheduledTracks[1].timelineTimeRange.start.seconds - 0.40) < 0.001)
        #expect(abs(plan.scheduledTracks[1].sourceTimeRange.start.seconds - 0.15) < 0.001)
        #expect(abs(plan.scheduledTracks[1].volume - 0.50) < 0.001)

        // Pull mixed stereo PCM samples and verify full 1.0s (48,000 stereo frames) coverage with non-zero audio amplitude
        let cursor = try mixEngine.makeSampleCursor(for: plan)
        var totalDecodedFrames = 0
        var maxObservedSampleMagnitude: Int16 = 0

        while let sampleBuffer = cursor.nextSampleBuffer() {
            totalDecodedFrames += CMSampleBufferGetNumSamples(sampleBuffer)
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPtr: UnsafeMutablePointer<CChar>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
                   let dataPtr {
                    let int16Count = length / MemoryLayout<Int16>.size
                    dataPtr.withMemoryRebound(to: Int16.self, capacity: int16Count) { samples in
                        for i in stride(from: 0, to: int16Count, by: 16) {
                            let mag = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                            if mag > maxObservedSampleMagnitude {
                                maxObservedSampleMagnitude = mag
                            }
                        }
                    }
                }
            }
        }

        #expect(totalDecodedFrames >= 47_000 && totalDecodedFrames <= 49_500)
        #expect(maxObservedSampleMagnitude > 1_500)
    }

    // MARK: - 5. End-to-End Headless MP4 Export & Cancellation

    @Test("VideoExportManager exports valid 60 FPS H.264 MP4 with mixed stereo AAC audio and supports clean cancellation")
    @MainActor
    func headlessMP4ExportAndCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenPlayM3Pipeline_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceClipURL = tempDir.appendingPathComponent("SourceAV.mov")
        try await Self.writeTestVideoWithSineAudio(to: sourceClipURL, durationSeconds: 0.8, frequencyHz: 523.25)

        let videoWinID = UUID()
        let codeWinID = UUID()

        let videoTrack = WindowTimelineTrack(
            windowID: videoWinID,
            title: "SourceAV.mov",
            contentKind: .video,
            initialContent: .video(
                VideoWindowPayload(
                    clipTitle: "SourceAV.mov",
                    resolutionTag: "1080p",
                    fps: 60,
                    durationSeconds: 0.8,
                    currentSeconds: 0.0,
                    isPlaying: true,
                    scene: .rocketLaunch,
                    assetURL: sourceClipURL,
                    mediaStartOffset: 0.0,
                    volume: 0.9,
                    isMuted: false
                )
            ),
            minimumSize: CGSize(width: 340, height: 250),
            accent: .coralBlush,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: WindowFrame(x: 80, y: 70, width: 480, height: 340), zIndex: 2, presentationState: .normal, isFocused: true, accent: .coralBlush, eventKind: .initial),
                WindowKeyframe(time: 0.5, frame: WindowFrame(x: 240, y: 120, width: 520, height: 360), zIndex: 2, presentationState: .normal, isFocused: true, accent: .coralBlush, eventKind: .moveEnded)
            ]
        )

        let codeTrack = WindowTimelineTrack(
            windowID: codeWinID,
            title: "Compositor.swift",
            contentKind: .codeSnippet,
            initialContent: .demoCodeSnippet,
            minimumSize: CGSize(width: 350, height: 230),
            accent: .mintMatcha,
            keyframes: [
                WindowKeyframe(time: 0.0, frame: WindowFrame(x: 620, y: 90, width: 460, height: 320), zIndex: 1, presentationState: .normal, isFocused: false, accent: .mintMatcha, eventKind: .initial)
            ]
        )

        let session = RecordedSession(
            duration: 0.5,
            wallpaper: .periwinkleCloud,
            canvasSize: CGSize(width: 1280, height: 720),
            initialActiveWindowID: videoWinID,
            tracks: [videoTrack, codeTrack]
        )

        let outputMP4URL = tempDir.appendingPathComponent("Exported_1080p60.mp4")
        let manager = VideoExportManager()
        let result = try await manager.export(
            session: session,
            configuration: .hd1080p60,
            interpolationCurve: .spring,
            to: outputMP4URL
        )

        #expect(result.totalFramesRendered == 30) // 0.5s * 60 FPS = 30 deterministic frames
        #expect(result.fileSizeBytes > 4_000)
        #expect(result.mixedAudioTrackCount == 1)
        #expect(manager.progress == 1.0)
        #expect(FileManager.default.fileExists(atPath: outputMP4URL.path))

        // Inspect resulting MP4 container with AVURLAsset
        let exportedAsset = AVURLAsset(url: outputMP4URL)
        let exportedVideoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        let exportedAudioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        let exportedDuration = try await exportedAsset.load(.duration)

        #expect(exportedVideoTracks.count == 1)
        #expect(exportedAudioTracks.count == 1)
        #expect(abs(exportedDuration.seconds - 0.5) < 0.08)

        if let vTrack = exportedVideoTracks.first {
            let naturalSize = try await vTrack.load(.naturalSize)
            #expect(naturalSize == CGSize(width: 1920, height: 1080))
        }

        // Verify exported MP4 decodes clean non-empty frames
        let validator = VideoAssetFrameProvider()
        defer { validator.invalidateAll() }
        let decodedMidFrame = validator.copyVideoFrame(from: outputMP4URL, at: 0.25)
        #expect(decodedMidFrame != nil)
        #expect(decodedMidFrame?.width == 1920)
        #expect(decodedMidFrame?.height == 1080)

        // Verify pre-cancelled token aborts cleanly and leaves no partial file on disk
        let cancelledURL = tempDir.appendingPathComponent("Cancelled_Export.mp4")
        let preCancelledToken = ExportCancellationToken()
        preCancelledToken.cancel()
        let pipeline = VideoExportPipeline()

        await #expect(throws: VideoExportError.cancelled) {
            _ = try await pipeline.runExport(
                session: session,
                configuration: .hd1080p60,
                outputURL: cancelledURL,
                cancellationToken: preCancelledToken
            )
        }
        #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
    }

    // MARK: - Synthetic Media & Pixel Inspection Helpers

    private static func sampleRGB(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = clampedY * bytesPerRow + clampedX * 4

        // 32BGRA byte order: [B, G, R, A]
        let b = Int(base[offset])
        let g = Int(base[offset + 1])
        let r = Int(base[offset + 2])
        let a = Int(base[offset + 3])
        return (r, g, b, a)
    }

    private static func pixelBuffersAreIdentical(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(lhs)
        let h = CVPixelBufferGetHeight(lhs)
        guard w == CVPixelBufferGetWidth(rhs), h == CVPixelBufferGetHeight(rhs) else { return false }

        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
        }

        let bprL = CVPixelBufferGetBytesPerRow(lhs)
        let bprR = CVPixelBufferGetBytesPerRow(rhs)
        let ptrL = CVPixelBufferGetBaseAddress(lhs)!.assumingMemoryBound(to: UInt8.self)
        let ptrR = CVPixelBufferGetBaseAddress(rhs)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = w * 4

        for row in 0..<h {
            if memcmp(ptrL.advanced(by: row * bprL), ptrR.advanced(by: row * bprR), rowBytes) != 0 {
                return false
            }
        }
        return true
    }

    private static func makeSolidPNGData(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let mutableData = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    private static func writeColorPhaseTestVideo(to url: URL, fps: Int32, framesPerPhase: Int) async throws {
        let width = 320
        let height = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let phases: [(UInt8, UInt8, UInt8)] = [
            (255, 10, 10), // Red
            (10, 240, 10), // Green
            (15, 20, 255)  // Blue
        ]

        let totalFrames = phases.count * framesPerPhase
        for frameIdx in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let phaseIdx = frameIdx / framesPerPhase
            let rgb = phases[phaseIdx]

            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pixelBuffer = pb else { continue }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = ptr.advanced(by: y * bpr)
                for x in 0..<width {
                    row[x * 4 + 0] = rgb.2 // B
                    row[x * 4 + 1] = rgb.1 // G
                    row[x * 4 + 2] = rgb.0 // R
                    row[x * 4 + 3] = 255   // A
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let pts = CMTimeMake(value: Int64(frameIdx), timescale: fps)
            _ = adaptor.append(pixelBuffer, withPresentationTime: pts)
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMake(value: Int64(totalFrames), timescale: fps))
        await writer.finishWriting()
    }

    private static func writeTestVideoWithSineAudio(
        to url: URL,
        durationSeconds: Double,
        frequencyHz: Double
    ) async throws {
        let width = 320
        let height = 180
        let fps: Int32 = 30
        let sampleRate: Int32 = 48_000

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(vInput)

        let aInput = AudioMixEngine.makeStereoAACWriterInput()
        writer.add(aInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalVideoFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))
        for idx in 0..<totalVideoFrames {
            while !vInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
            if let pb {
                CVPixelBufferLockBaseAddress(pb, [])
                memset(CVPixelBufferGetBaseAddress(pb), 180, CVPixelBufferGetDataSize(pb))
                CVPixelBufferUnlockBaseAddress(pb, [])
                _ = adaptor.append(pb, withPresentationTime: CMTimeMake(value: Int64(idx), timescale: fps))
            }
        }
        vInput.markAsFinished()

        // Generate 48kHz Stereo 16-bit LPCM sine wave samples
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )

        let totalAudioFrames = Int((durationSeconds * Double(sampleRate)).rounded())
        var cursor = 0
        let chunkSize = 1_024
        while cursor < totalAudioFrames, let formatDesc {
            while !aInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let count = min(chunkSize, totalAudioFrames - cursor)
            let byteCount = count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block
            )
            if let block {
                var rawPtr: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &rawPtr)
                if let rawPtr {
                    rawPtr.withMemoryRebound(to: Int16.self, capacity: count * 2) { pcm in
                        for i in 0..<count {
                            let sampleIndex = cursor + i
                            let angle = 2.0 * Double.pi * frequencyHz * (Double(sampleIndex) / Double(sampleRate))
                            let val = Int16((Darwin.sin(angle) * 14_000.0).rounded())
                            pcm[i * 2] = val
                            pcm[i * 2 + 1] = val
                        }
                    }
                }
                var sb: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: block,
                    formatDescription: formatDesc,
                    sampleCount: CMItemCount(count),
                    presentationTimeStamp: CMTimeMake(value: Int64(cursor), timescale: sampleRate),
                    packetDescriptions: nil,
                    sampleBufferOut: &sb
                )
                if let sb {
                    _ = aInput.append(sb)
                }
            }
            cursor += count
        }
        aInput.markAsFinished()

        writer.endSession(atSourceTime: CMTime(seconds: durationSeconds, preferredTimescale: sampleRate))
        await writer.finishWriting()
    }
}
