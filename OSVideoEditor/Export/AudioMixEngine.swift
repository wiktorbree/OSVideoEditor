//
//  AudioMixEngine.swift
//  OSVideoEditor
//
//  Milestone 3 Stereo Audio Synchronization & Mixing Engine.
//  Collects audio tracks from all active video windows in a `RecordedSession`, aligns them
//  to timeline spawn/close offsets and media in-points, applies per-window volume & minimize ducking
//  via `AVMutableAudioMix`, and streams 48 kHz Stereo PCM into an AAC `AVAssetWriterInput`.
//

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

nonisolated struct AudioTrackScheduleSummary: Equatable, Sendable {
    let windowID: UUID
    let windowTitle: String
    let assetURL: URL
    let timelineTimeRange: CMTimeRange
    let sourceTimeRange: CMTimeRange
    let volume: Float
}

nonisolated final class PreparedAudioMixPlan: @unchecked Sendable {
    let composition: AVMutableComposition
    let compositionTracks: [AVMutableCompositionTrack]
    let audioMix: AVAudioMix
    let scheduledTracks: [AudioTrackScheduleSummary]
    let totalDuration: CMTime
    fileprivate let securityScopedURLs: [URL]

    init(
        composition: AVMutableComposition,
        compositionTracks: [AVMutableCompositionTrack],
        audioMix: AVAudioMix,
        scheduledTracks: [AudioTrackScheduleSummary],
        totalDuration: CMTime,
        securityScopedURLs: [URL]
    ) {
        self.composition = composition
        self.compositionTracks = compositionTracks
        self.audioMix = audioMix
        self.scheduledTracks = scheduledTracks
        self.totalDuration = totalDuration
        self.securityScopedURLs = securityScopedURLs
    }

    deinit {
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// Pull-based 48 kHz Stereo 16-bit LPCM sample stream feeding `AVAssetWriterInput` on the audio pump queue.
nonisolated final class AudioMixSampleCursor: @unchecked Sendable {
    static let sampleRate: Int32 = 48_000
    static let channels: UInt32 = 2
    static let bytesPerFrame: Int = 4

    private let plan: PreparedAudioMixPlan
    private let reader: AVAssetReader?
    private let mixOutput: AVAssetReaderAudioMixOutput?
    private let targetTotalFrames: Int64
    private let silenceFormatDescription: CMAudioFormatDescription?

    private var nextExpectedSampleFrame: Int64 = 0
    private var readerExhausted: Bool
    private var isCancelled: Bool = false

    fileprivate init(
        plan: PreparedAudioMixPlan,
        reader: AVAssetReader?,
        mixOutput: AVAssetReaderAudioMixOutput?,
        targetTotalFrames: Int64
    ) {
        self.plan = plan
        self.reader = reader
        self.mixOutput = mixOutput
        self.targetTotalFrames = max(0, targetTotalFrames)
        self.readerExhausted = (reader == nil || mixOutput == nil)
        self.silenceFormatDescription = Self.makeStereoPCMFormatDescription()
    }

    deinit {
        cancel()
    }

    /// Pulls the next mixed stereo `CMSampleBuffer` (or tail/full-span digital silence to match exact video duration).
    func nextSampleBuffer() -> CMSampleBuffer? {
        guard !isCancelled else { return nil }

        if !readerExhausted, let reader, let mixOutput {
            if reader.status == .reading, let sampleBuffer = mixOutput.copyNextSampleBuffer() {
                let numSamples = Int64(CMSampleBufferGetNumSamples(sampleBuffer))
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if pts.isNumeric {
                    let ptsFrames = CMTimeConvertScale(
                        pts,
                        timescale: Self.sampleRate,
                        method: .roundHalfAwayFromZero
                    ).value
                    nextExpectedSampleFrame = max(nextExpectedSampleFrame, ptsFrames + numSamples)
                } else {
                    nextExpectedSampleFrame += numSamples
                }
                return sampleBuffer
            } else {
                readerExhausted = true
            }
        }

        // Pad remaining timeline span with exact 48 kHz stereo silence so AAC track length equals video duration
        guard nextExpectedSampleFrame < targetTotalFrames,
              let formatDesc = silenceFormatDescription else {
            return nil
        }

        let remaining = targetTotalFrames - nextExpectedSampleFrame
        let chunkFrames = Int(min(1_024, remaining))
        guard let silenceBuffer = Self.makeSilenceSampleBuffer(
            startFrame: nextExpectedSampleFrame,
            frameCount: chunkFrames,
            formatDescription: formatDesc
        ) else {
            nextExpectedSampleFrame = targetTotalFrames
            return nil
        }

        nextExpectedSampleFrame += Int64(chunkFrames)
        return silenceBuffer
    }

    func cancel() {
        isCancelled = true
        if let reader, reader.status == .reading {
            reader.cancelReading()
        }
    }

    // MARK: - CoreMedia Stereo LPCM Silence Generator

    private static func makeStereoPCMFormatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var layout = AudioChannelLayout()
        memset(&layout, 0, MemoryLayout<AudioChannelLayout>.size)
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    private static func makeSilenceSampleBuffer(
        startFrame: Int64,
        frameCount: Int,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        guard frameCount > 0 else { return nil }
        let byteLength = frameCount * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let validBlock = blockBuffer else {
            return nil
        }

        let fillStatus = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: validBlock,
            offsetIntoDestination: 0,
            dataLength: byteLength
        )
        guard fillStatus == kCMBlockBufferNoErr else {
            return nil
        }

        let pts = CMTimeMake(value: startFrame, timescale: sampleRate)
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: validBlock,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleStatus == noErr ? sampleBuffer : nil
    }
}

// MARK: - AudioMixEngine

nonisolated final class AudioMixEngine: Sendable {

    static let outputSampleRate: Double = 48_000.0
    static let outputChannelCount: Int = 2
    static let defaultAACBitRate: Int = 192_000

    init() {}

    /// Inspects all active `.video` tracks in `session` and builds a synchronized `AVMutableComposition` + stereo `AVAudioMix`.
    func buildAudioMixPlan(
        for session: RecordedSession,
        exportDurationSeconds: Double? = nil
    ) async throws -> PreparedAudioMixPlan {
        let effectiveDuration = max(
            0.016,
            exportDurationSeconds ?? max(0.016, session.duration)
        )
        let totalDurationCM = CMTime(
            seconds: effectiveDuration,
            preferredTimescale: AudioMixSampleCursor.sampleRate
        )

        let composition = AVMutableComposition()
        var createdCompTracks: [AVMutableCompositionTrack] = []
        var inputParameters: [AVAudioMixInputParameters] = []
        var scheduledSummaries: [AudioTrackScheduleSummary] = []
        var activeScopedURLs: [URL] = []

        for track in session.tracks {
            guard case let .video(payload) = track.initialContent,
                  let assetURL = payload.assetURL,
                  !payload.isMuted,
                  payload.volume > 0.000_1 else {
                continue
            }

            guard let presence = track.activePresenceRange(totalDuration: effectiveDuration) else {
                continue
            }

            let timelineStart = max(0.0, presence.lowerBound)
            let timelineEnd = min(effectiveDuration, presence.upperBound)
            let requestedWindowSpan = timelineEnd - timelineStart
            guard requestedWindowSpan > 0.005 else {
                continue
            }

            let isScoped = assetURL.startAccessingSecurityScopedResource()
            if isScoped {
                activeScopedURLs.append(assetURL)
            }

            let asset = AVURLAsset(
                url: assetURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )

            guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                  let sourceAudioTrack = audioTracks.first else {
                continue
            }

            let assetDurationCM = (try? await asset.load(.duration)) ?? .zero
            let assetDurationSeconds = assetDurationCM.isNumeric ? max(0.0, assetDurationCM.seconds) : 0.0
            let sourceInSeconds = max(0.0, payload.mediaStartOffset)
            let availableSourceSeconds = max(0.0, assetDurationSeconds - sourceInSeconds)
            let clipSeconds = min(requestedWindowSpan, availableSourceSeconds)
            guard clipSeconds > 0.005 else {
                continue
            }

            guard let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            createdCompTracks.append(compAudioTrack)

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: sourceInSeconds, preferredTimescale: AudioMixSampleCursor.sampleRate),
                duration: CMTime(seconds: clipSeconds, preferredTimescale: AudioMixSampleCursor.sampleRate)
            )
            let timelineInsertTime = CMTime(
                seconds: timelineStart,
                preferredTimescale: AudioMixSampleCursor.sampleRate
            )

            do {
                try compAudioTrack.insertTimeRange(
                    sourceRange,
                    of: sourceAudioTrack,
                    at: timelineInsertTime
                )
            } catch {
                throw VideoExportError.audioMixFailed(
                    "Could not insert audio track for '\(track.title)': \(error.localizedDescription)"
                )
            }

            let clampedVolume = min(max(payload.volume, 0.0), 1.5)
            let mixParams = AVMutableAudioMixInputParameters(track: compAudioTrack)
            configureVolumeEnvelope(
                on: mixParams,
                track: track,
                baseVolume: clampedVolume,
                timelineStart: timelineStart,
                timelineEnd: timelineStart + clipSeconds
            )
            inputParameters.append(mixParams)

            let timelineRange = CMTimeRange(
                start: timelineInsertTime,
                duration: sourceRange.duration
            )
            scheduledSummaries.append(
                AudioTrackScheduleSummary(
                    windowID: track.windowID,
                    windowTitle: track.title,
                    assetURL: assetURL,
                    timelineTimeRange: timelineRange,
                    sourceTimeRange: sourceRange,
                    volume: clampedVolume
                )
            )
        }

        let mutableMix = AVMutableAudioMix()
        mutableMix.inputParameters = inputParameters

        return PreparedAudioMixPlan(
            composition: composition,
            compositionTracks: createdCompTracks,
            audioMix: mutableMix,
            scheduledTracks: scheduledSummaries,
            totalDuration: totalDurationCM,
            securityScopedURLs: activeScopedURLs
        )
    }

    /// Starts an `AVAssetReader` + `AVAssetReaderAudioMixOutput` cursor for streaming mixed stereo PCM into `AVAssetWriter`.
    func makeSampleCursor(for plan: PreparedAudioMixPlan) throws -> AudioMixSampleCursor {
        let totalFrames = max(
            1,
            Int64((plan.totalDuration.seconds * Self.outputSampleRate).rounded())
        )

        let compTracks = plan.compositionTracks
        guard !compTracks.isEmpty else {
            return AudioMixSampleCursor(
                plan: plan,
                reader: nil,
                mixOutput: nil,
                targetTotalFrames: totalFrames
            )
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: plan.composition)
        } catch {
            throw VideoExportError.audioMixFailed(
                "Failed creating AVAssetReader for audio composition: \(error.localizedDescription)"
            )
        }

        let pcmOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.outputSampleRate,
            AVNumberOfChannelsKey: Self.outputChannelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let mixOutput = AVAssetReaderAudioMixOutput(
            audioTracks: compTracks,
            audioSettings: pcmOutputSettings
        )
        mixOutput.audioMix = plan.audioMix
        mixOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(mixOutput) else {
            throw VideoExportError.audioMixFailed("AVAssetReader rejected AVAssetReaderAudioMixOutput.")
        }
        reader.add(mixOutput)
        reader.timeRange = CMTimeRange(start: .zero, duration: plan.totalDuration)

        guard reader.startReading() else {
            let reason = reader.error?.localizedDescription ?? "Unknown AVAssetReader failure"
            throw VideoExportError.audioMixFailed(reason)
        }

        return AudioMixSampleCursor(
            plan: plan,
            reader: reader,
            mixOutput: mixOutput,
            targetTotalFrames: totalFrames
        )
    }

    /// Configures a 48 kHz Stereo AAC `AVAssetWriterInput` ready to attach to `AVAssetWriter`.
    static func makeStereoAACWriterInput(bitRate: Int = defaultAACBitRate) -> AVAssetWriterInput {
        var channelLayout = AudioChannelLayout()
        memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: outputChannelCount,
            AVEncoderBitRateKey: bitRate,
            AVChannelLayoutKey: layoutData
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    // MARK: - Keyframe Minimize / Restore Volume Envelope

    private func configureVolumeEnvelope(
        on mixParams: AVMutableAudioMixInputParameters,
        track: WindowTimelineTrack,
        baseVolume: Float,
        timelineStart: Double,
        timelineEnd: Double
    ) {
        let initialMinimized = track.keyframes.first?.presentationState == .minimized
        mixParams.setVolume(initialMinimized ? 0.0 : baseVolume, at: .zero)

        var currentlyMinimized = initialMinimized
        for kf in track.keyframes where kf.time >= timelineStart && kf.time <= timelineEnd {
            let isMin = (kf.presentationState == .minimized)
            guard isMin != currentlyMinimized else { continue }
            currentlyMinimized = isMin

            let rampStart = CMTime(seconds: kf.time, preferredTimescale: AudioMixSampleCursor.sampleRate)
            let rampDuration = CMTime(seconds: 0.020, preferredTimescale: AudioMixSampleCursor.sampleRate)
            mixParams.setVolumeRamp(
                fromStartVolume: isMin ? baseVolume : 0.0,
                toEndVolume: isMin ? 0.0 : baseVolume,
                timeRange: CMTimeRange(start: rampStart, duration: rampDuration)
            )
        }
    }
}
