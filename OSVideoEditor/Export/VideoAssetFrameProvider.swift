//
//  VideoAssetFrameProvider.swift
//  OSVideoEditor
//
//  Thread-safe offscreen video & raster asset frame decoder combining sequential `AVAssetReader`
//  streaming, random-access GOP seeking, orientation transform normalization, and bounded LRU caching.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

nonisolated final class VideoAssetFrameProvider: @unchecked Sendable {

    // MARK: - Prepared Asset Metadata

    private struct PreparedVideoDescriptor {
        let url: URL
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let durationSeconds: Double
        let isSecurityScoped: Bool
    }

    private final class SequentialReaderState {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        var currentImage: CGImage?
        var currentPTS: Double = -.greatestFiniteMagnitude
        var nextImage: CGImage?
        var nextPTS: Double = -.greatestFiniteMagnitude
        var reachedEOF: Bool = false

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
            self.reader = reader
            self.output = output
        }

        func cancel() {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }
    }

    private struct FrameCacheKey: Hashable {
        let url: URL
        /// Quantized at 1/120s buckets for deterministic sub-frame cache hits across 30/60fps.
        let quantizedTick: Int64
    }

    // MARK: - State & Synchronization

    private let lock = NSLock()
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    private var descriptorsByURL: [URL: PreparedVideoDescriptor] = [:]
    private var activeReadersByURL: [URL: SequentialReaderState] = [:]

    private var frameCache: [FrameCacheKey: CGImage] = [:]
    private var frameCacheOrder: [FrameCacheKey] = []
    private let maxCachedVideoFrames: Int

    private var rasterImageCacheByURL: [URL: CGImage] = [:]
    private var rasterImageCacheByHash: [Int: CGImage] = [:]

    // MARK: - Initialization & Teardown

    init(maxCachedVideoFrames: Int = 72) {
        self.maxCachedVideoFrames = max(8, maxCachedVideoFrames)
    }

    deinit {
        invalidateAll()
    }

    /// Cancels all open `AVAssetReader` cursors, releases security-scoped resources, and clears frame caches.
    func invalidateAll() {
        lock.lock()
        let readers = Array(activeReadersByURL.values)
        let descriptors = Array(descriptorsByURL.values)
        activeReadersByURL.removeAll()
        descriptorsByURL.removeAll()
        frameCache.removeAll()
        frameCacheOrder.removeAll()
        rasterImageCacheByURL.removeAll()
        rasterImageCacheByHash.removeAll()
        lock.unlock()

        for state in readers {
            state.cancel()
        }
        for desc in descriptors where desc.isSecurityScoped {
            desc.url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Async Pre-Warming for Export Sessions

    /// Asynchronously loads video track descriptors for all video windows in `session` prior to frame pumping.
    func prepareAssets(for session: RecordedSession) async {
        var uniqueURLs: Set<URL> = []
        for track in session.tracks {
            if case let .video(payload) = track.initialContent, let url = payload.assetURL {
                uniqueURLs.insert(url)
            }
        }

        for url in uniqueURLs {
            _ = await loadOrPrepareDescriptorAsync(for: url)
        }
    }

    // MARK: - Synchronized Video Frame Extraction

    /// Extracts the exact video frame `CGImage` at `timeSeconds` from `url`.
    /// Uses sequential `AVAssetReader` streaming during linear export and targeted range readers + LRU cache for random scrubs.
    func copyVideoFrame(from url: URL, at timeSeconds: Double) -> CGImage? {
        guard let descriptor = resolveDescriptorSynchronouslyIfNeeded(for: url) else {
            return nil
        }

        let clampedTime: Double
        if descriptor.durationSeconds > 0 {
            clampedTime = min(max(0.0, timeSeconds), max(0.0, descriptor.durationSeconds - 0.001))
        } else {
            clampedTime = max(0.0, timeSeconds)
        }

        let cacheKey = FrameCacheKey(
            url: url,
            quantizedTick: Int64((clampedTime * 120.0).rounded())
        )

        lock.lock()
        if let cached = frameCache[cacheKey] {
            lock.unlock()
            return cached
        }

        let resolvedImage = decodeFrameLocked(
            descriptor: descriptor,
            targetTime: clampedTime
        )

        if let resolvedImage {
            insertIntoFrameCacheLocked(image: resolvedImage, for: cacheKey)
        }
        lock.unlock()
        return resolvedImage
    }

    // MARK: - Raster Image Asset & Snapshot Decoding

    func rasterImage(fromData data: Data?) -> CGImage? {
        guard let data, !data.isEmpty else { return nil }
        let digest = data.hashValue

        lock.lock()
        if let cached = rasterImageCacheByHash[digest] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        lock.lock()
        if rasterImageCacheByHash.count > 32 {
            rasterImageCacheByHash.removeAll(keepingCapacity: true)
        }
        rasterImageCacheByHash[digest] = image
        lock.unlock()
        return image
    }

    func rasterImage(fromURL url: URL?) -> CGImage? {
        guard let url else { return nil }

        lock.lock()
        if let cached = rasterImageCacheByURL[url] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        lock.lock()
        if rasterImageCacheByURL.count > 32 {
            rasterImageCacheByURL.removeAll(keepingCapacity: true)
        }
        rasterImageCacheByURL[url] = image
        lock.unlock()
        return image
    }

    // MARK: - Internal Sequential & Seekable AVAssetReader Engine

    private func decodeFrameLocked(
        descriptor: PreparedVideoDescriptor,
        targetTime: Double
    ) -> CGImage? {
        // Reuse active sequential reader when stepping forward monotonically within 1.5s
        if let existing = activeReadersByURL[descriptor.url],
           existing.reader.status == .reading || existing.reachedEOF,
           targetTime >= existing.currentPTS - 0.002,
           targetTime - max(0.0, existing.currentPTS) <= 1.5 {
            if let image = advanceReaderLocked(existing, descriptor: descriptor, to: targetTime) {
                return image
            }
        }

        // Otherwise open a new reader positioned slightly ahead of `targetTime`
        if let old = activeReadersByURL.removeValue(forKey: descriptor.url) {
            old.cancel()
        }

        guard let freshState = makeReaderState(for: descriptor, startingNear: targetTime) else {
            return nil
        }
        activeReadersByURL[descriptor.url] = freshState
        return advanceReaderLocked(freshState, descriptor: descriptor, to: targetTime)
    }

    private func makeReaderState(
        for descriptor: PreparedVideoDescriptor,
        startingNear targetTime: Double
    ) -> SequentialReaderState? {
        guard let reader = try? AVAssetReader(asset: descriptor.asset) else {
            return nil
        }

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        let output = AVAssetReaderTrackOutput(
            track: descriptor.videoTrack,
            outputSettings: pixelAttributes
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        // Start slightly prior to `targetTime` so the frame active at `targetTime` is captured cleanly
        let leadIn = max(0.0, targetTime - 0.05)
        if leadIn > 0.001 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: leadIn, preferredTimescale: 600),
                duration: .positiveInfinity
            )
        }

        guard reader.startReading() else {
            return nil
        }

        return SequentialReaderState(reader: reader, output: output)
    }

    private func advanceReaderLocked(
        _ state: SequentialReaderState,
        descriptor: PreparedVideoDescriptor,
        to targetTime: Double
    ) -> CGImage? {
        let epsilon = 0.000_5

        // Prime first sample if newly opened
        if state.currentImage == nil && !state.reachedEOF {
            if let firstSample = pullNextImage(from: state, descriptor: descriptor) {
                state.currentImage = firstSample.image
                state.currentPTS = firstSample.pts
            } else {
                state.reachedEOF = true
                return nil
            }
        }

        // Prime lookahead sample if missing
        if state.nextImage == nil && !state.reachedEOF {
            if let secondSample = pullNextImage(from: state, descriptor: descriptor) {
                state.nextImage = secondSample.image
                state.nextPTS = secondSample.pts
            } else {
                state.reachedEOF = true
            }
        }

        // Step forward while `nextPTS <= targetTime`
        while let nextImg = state.nextImage, state.nextPTS <= targetTime + epsilon {
            state.currentImage = nextImg
            state.currentPTS = state.nextPTS

            if !state.reachedEOF, let upcoming = pullNextImage(from: state, descriptor: descriptor) {
                state.nextImage = upcoming.image
                state.nextPTS = upcoming.pts
            } else {
                state.nextImage = nil
                state.nextPTS = .greatestFiniteMagnitude
                state.reachedEOF = true
                break
            }
        }

        return state.currentImage
    }

    private func pullNextImage(
        from state: SequentialReaderState,
        descriptor: PreparedVideoDescriptor
    ) -> (image: CGImage, pts: Double)? {
        while state.reader.status == .reading {
            guard let sampleBuffer = state.output.copyNextSampleBuffer() else {
                break
            }
            guard CMSampleBufferIsValid(sampleBuffer),
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSeconds = ptsTime.isNumeric ? ptsTime.seconds : 0.0

            if let cgImage = makeCGImage(from: imageBuffer, preferredTransform: descriptor.preferredTransform) {
                return (cgImage, ptsSeconds)
            }
        }
        return nil
    }

    private func makeCGImage(
        from pixelBuffer: CVImageBuffer,
        preferredTransform: CGAffineTransform
    ) -> CGImage? {
        var ciImage = CIImage(cvImageBuffer: pixelBuffer)
        if !preferredTransform.isIdentity {
            ciImage = ciImage.transformed(by: preferredTransform)
            let extent = ciImage.extent
            if extent.origin != .zero {
                ciImage = ciImage.transformed(
                    by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
                )
            }
        }
        let bounds = ciImage.extent.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return ciContext.createCGImage(
            ciImage,
            from: bounds,
            format: .BGRA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    private func insertIntoFrameCacheLocked(image: CGImage, for key: FrameCacheKey) {
        if frameCache[key] != nil { return }
        if frameCacheOrder.count >= maxCachedVideoFrames {
            let evicted = frameCacheOrder.removeFirst()
            frameCache.removeValue(forKey: evicted)
        }
        frameCache[key] = image
        frameCacheOrder.append(key)
    }

    // MARK: - Descriptor Loading

    private func loadOrPrepareDescriptorAsync(for url: URL) async -> PreparedVideoDescriptor? {
        lock.lock()
        if let existing = descriptorsByURL[url] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let scoped = url.startAccessingSecurityScopedResource()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let videoTrack = tracks.first else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return nil
        }

        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let durationCM = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = durationCM.isNumeric ? max(0.0, durationCM.seconds) : 0.0

        let descriptor = PreparedVideoDescriptor(
            url: url,
            asset: asset,
            videoTrack: videoTrack,
            preferredTransform: transform,
            naturalSize: naturalSize,
            durationSeconds: durationSeconds,
            isSecurityScoped: scoped
        )

        lock.lock()
        if let raceExisting = descriptorsByURL[url] {
            lock.unlock()
            if scoped { url.stopAccessingSecurityScopedResource() }
            return raceExisting
        }
        descriptorsByURL[url] = descriptor
        lock.unlock()
        return descriptor
    }

    private func resolveDescriptorSynchronouslyIfNeeded(for url: URL) -> PreparedVideoDescriptor? {
        lock.lock()
        if let existing = descriptorsByURL[url] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        // Bridge modern async AVAsset track loading safely when invoked synchronously without prior `prepareAssets`
        nonisolated final class Box: @unchecked Sendable {
            var value: PreparedVideoDescriptor?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [weak self] in
            box.value = await self?.loadOrPrepareDescriptorAsync(for: url)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }
}
