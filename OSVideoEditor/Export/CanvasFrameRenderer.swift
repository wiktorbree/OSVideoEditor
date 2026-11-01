//
//  CanvasFrameRenderer.swift
//  OSVideoEditor
//
//  Milestone 3 Headless Offscreen Compositing Engine.
//  Deterministically renders a complete ScreenPlay OS desktop frame at any timestamp `t`
//  into an IOSurface-backed `CVPixelBuffer` or `CGImage` at 1080p, 4K, or custom resolutions.
//

import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Darwin
import Foundation

nonisolated enum CanvasFrameRenderError: LocalizedError, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case pixelBufferAllocationFailed(CVReturn)
    case pixelBufferBaseAddressUnavailable
    case bitmapContextCreationFailed
    case cgImageCreationFailed

    var errorDescription: String? {
        switch self {
        case let .invalidDimensions(w, h):
            "Invalid render output dimensions (\(w)×\(h))."
        case let .pixelBufferAllocationFailed(status):
            "Failed to allocate CVPixelBuffer (CVReturn \(status))."
        case .pixelBufferBaseAddressUnavailable:
            "CVPixelBuffer base address was nil after locking."
        case .bitmapContextCreationFailed:
            "Failed to create sRGB CGBitmapContext for CVPixelBuffer."
        case .cgImageCreationFailed:
            "Failed to snapshot CGImage from rendered frame buffer."
        }
    }
}

nonisolated final class CanvasFrameRenderer: @unchecked Sendable {

    // MARK: - Cached Wallpaper Key

    private struct WallpaperCacheKey: Equatable {
        let wallpaper: CartoonWallpaper
        let width: Int
        let height: Int
        let scale: CGFloat
    }

    // MARK: - Dependencies & Thread-Safe Caches

    let frameProvider: VideoAssetFrameProvider
    private let colorSpace: CGColorSpace
    private let cacheLock = NSLock()
    private var cachedWallpaperKey: WallpaperCacheKey?
    private var cachedWallpaperImage: CGImage?

    // MARK: - Initialization

    init(frameProvider: VideoAssetFrameProvider = VideoAssetFrameProvider()) {
        self.frameProvider = frameProvider
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Pre-loads video track descriptors for all video windows in `session` prior to high-speed frame pumping.
    func prepare(for session: RecordedSession) async {
        await frameProvider.prepareAssets(for: session)
    }

    /// Releases cached wallpaper bitmaps and active `AVAssetReader` instances.
    func invalidateCaches() {
        cacheLock.lock()
        cachedWallpaperKey = nil
        cachedWallpaperImage = nil
        cacheLock.unlock()
        frameProvider.invalidateAll()
    }

    // MARK: - Primary Offscreen Rendering Entry Points

    /// Evaluates `session` deterministically at `time` via `KeyframeInterpolator` and renders into a `CVPixelBuffer`.
    func renderPixelBuffer(
        for session: RecordedSession,
        at time: Double,
        curve: InterpolationCurve = .easeInOut,
        outputSize: CGSize,
        includeMenuBar: Bool = true,
        pixelBufferPool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let scene = KeyframeInterpolator.evaluateScene(
            in: session,
            at: time,
            curve: curve
        )
        return try renderPixelBuffer(
            scene: scene,
            outputSize: outputSize,
            includeMenuBar: includeMenuBar,
            pixelBufferPool: pixelBufferPool
        )
    }

    /// Renders an evaluated `InterpolatedSceneState` into a newly allocated or pool-vended `32BGRA` `CVPixelBuffer`.
    func renderPixelBuffer(
        scene: InterpolatedSceneState,
        outputSize: CGSize,
        includeMenuBar: Bool = true,
        pixelBufferPool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let width = Int(outputSize.width.rounded())
        let height = Int(outputSize.height.rounded())
        guard width >= 16, height >= 16 else {
            throw CanvasFrameRenderError.invalidDimensions(width: width, height: height)
        }

        let pixelBuffer = try allocatePixelBuffer(
            width: width,
            height: height,
            pool: pixelBufferPool
        )
        try renderIntoPixelBuffer(
            pixelBuffer,
            scene: scene,
            includeMenuBar: includeMenuBar
        )
        return pixelBuffer
    }

    /// Renders `scene` directly into an existing `32BGRA` `CVPixelBuffer`.
    func renderIntoPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        scene: InterpolatedSceneState,
        includeMenuBar: Bool = true
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw CanvasFrameRenderError.invalidDimensions(width: width, height: height)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CanvasFrameRenderError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CanvasFrameRenderError.bitmapContextCreationFailed
        }

        renderScene(
            scene,
            in: context,
            pixelWidth: width,
            pixelHeight: height,
            includeMenuBar: includeMenuBar
        )
    }

    /// Convenience helper rendering a complete frame as a `CGImage` (ideal for Export Modal thumbnails and pixel verification tests).
    func renderCGImage(
        for session: RecordedSession,
        at time: Double,
        curve: InterpolationCurve = .easeInOut,
        outputSize: CGSize,
        includeMenuBar: Bool = true
    ) throws -> CGImage {
        let pixelBuffer = try renderPixelBuffer(
            for: session,
            at: time,
            curve: curve,
            outputSize: outputSize,
            includeMenuBar: includeMenuBar,
            pixelBufferPool: nil
        )

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CanvasFrameRenderError.pixelBufferBaseAddressUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let cgImage = context.makeImage() else {
            throw CanvasFrameRenderError.cgImageCreationFailed
        }

        return cgImage
    }

    // MARK: - Pixel Buffer Allocation

    private func allocatePixelBuffer(
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?

        if let pool {
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
            if poolStatus == kCVReturnSuccess, let vended = bufferOut {
                if CVPixelBufferGetWidth(vended) == width && CVPixelBufferGetHeight(vended) == height {
                    attachColorSpaceMetadata(to: vended)
                    return vended
                }
            }
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &bufferOut
        )

        guard status == kCVReturnSuccess, let allocated = bufferOut else {
            throw CanvasFrameRenderError.pixelBufferAllocationFailed(status)
        }
        attachColorSpaceMetadata(to: allocated)
        return allocated
    }

    private func attachColorSpaceMetadata(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCGColorSpaceKey,
            colorSpace,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    // MARK: - Complete Scene Compositor (Top-Leading Coordinate System)

    private func renderScene(
        _ scene: InterpolatedSceneState,
        in context: CGContext,
        pixelWidth: Int,
        pixelHeight: Int,
        includeMenuBar: Bool
    ) {
        let outW = CGFloat(pixelWidth)
        let outH = CGFloat(pixelHeight)
        let fullBounds = CGRect(x: 0, y: 0, width: outW, height: outH)

        context.saveGState()
        defer { context.restoreGState() }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        // Flip CTM so `(0, 0)` is top-leading and `+y` grows downward, matching ScreenPlay OS `WindowFrame`
        context.translateBy(x: 0, y: outH)
        context.scaleBy(x: 1.0, y: -1.0)

        let refW = max(320.0, scene.canvasSize.width)
        let refH = max(240.0, scene.canvasSize.height)
        let scale = min(outW / refW, outH / refH)
        let stageOffset = CGPoint(
            x: (outW - refW * scale) * 0.5,
            y: (outH - refH * scale) * 0.5
        )

        // 1. Full-Bleed Cartoon Wallpaper (Gradient + Glow Blobs + Comic Dot-Grid)
        let wallpaper = scene.wallpaper ?? .pastelSunrise
        drawCachedWallpaper(
            wallpaper,
            in: fullBounds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale,
            context: context
        )

        // 2. Windows Rendered in Exact Ascending Z-Index Order
        let orderedVisibleWindows = scene.windows
            .enumerated()
            .filter { $0.element.presentationState != .minimized }
            .sorted { lhs, rhs in
                if lhs.element.zIndex != rhs.element.zIndex {
                    return lhs.element.zIndex < rhs.element.zIndex
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        for window in orderedVisibleWindows {
            let isFocused = (scene.activeWindowID == window.windowID) || window.isFocused
            let scaledWindowRect = CGRect(
                x: stageOffset.x + window.frame.origin.x * scale,
                y: stageOffset.y + window.frame.origin.y * scale,
                width: max(80.0 * scale, window.frame.size.width * scale),
                height: max(80.0 * scale, window.frame.size.height * scale)
            )
            drawDesktopWindow(
                window,
                in: scaledWindowRect,
                isFocused: isFocused,
                sceneTime: scene.time,
                scale: scale,
                context: context
            )
        }

        // 3. Optional Virtual Cartoon macOS Top Menu Bar Chrome
        if includeMenuBar {
            drawVirtualDesktopMenuBar(
                scene: scene,
                visibleWindows: orderedVisibleWindows,
                outputWidth: outW,
                scale: scale,
                context: context
            )
        }
    }

    // MARK: - Layer 1: Cached Full-Bleed Cartoon Wallpaper

    private func drawCachedWallpaper(
        _ wallpaper: CartoonWallpaper,
        in bounds: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: CGFloat,
        context: CGContext
    ) {
        let key = WallpaperCacheKey(
            wallpaper: wallpaper,
            width: pixelWidth,
            height: pixelHeight,
            scale: (scale * 100.0).rounded() / 100.0
        )

        cacheLock.lock()
        if cachedWallpaperKey == key, let existing = cachedWallpaperImage {
            cacheLock.unlock()
            Self.drawCGImage(existing, in: bounds, context: context)
            return
        }
        cacheLock.unlock()

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let offscreen = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            drawWallpaperDirect(wallpaper, in: bounds, scale: scale, context: context)
            return
        }

        offscreen.translateBy(x: 0, y: CGFloat(pixelHeight))
        offscreen.scaleBy(x: 1.0, y: -1.0)
        drawWallpaperDirect(wallpaper, in: bounds, scale: scale, context: offscreen)

        if let baked = offscreen.makeImage() {
            cacheLock.lock()
            cachedWallpaperKey = key
            cachedWallpaperImage = baked
            cacheLock.unlock()
            Self.drawCGImage(baked, in: bounds, context: context)
        } else {
            drawWallpaperDirect(wallpaper, in: bounds, scale: scale, context: context)
        }
    }

    private func drawWallpaperDirect(
        _ wallpaper: CartoonWallpaper,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        // Multi-stop diagonal linear gradient
        let stops = wallpaper.gradientRGBAColors
        let cgColors = stops.map(\.cgColor) as CFArray
        let locations: [CGFloat] = stops.count == 3 ? [0.0, 0.5, 1.0] : [0.0, 1.0]

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.minX, y: bounds.minY),
                end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Ambient soft pastel radial glow blobs
        let glowColors = [
            CartoonRenderMetrics.white.withAlpha(0.32).cgColor,
            CartoonRenderMetrics.white.withAlpha(0.0).cgColor
        ] as CFArray
        if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            let centerA = CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.32)
            context.drawRadialGradient(
                glowGrad,
                startCenter: centerA,
                startRadius: 0,
                endCenter: centerA,
                endRadius: 230.0 * scale,
                options: []
            )

            let centerB = CGPoint(x: bounds.width * 0.78, y: bounds.height * 0.72)
            context.drawRadialGradient(
                glowGrad,
                startCenter: centerB,
                startRadius: 0,
                endCenter: centerB,
                endRadius: 195.0 * scale,
                options: []
            )
        }

        // Crisp comic dot-grid pattern
        let spacing = max(12.0, 26.0 * scale)
        let dotRadius = max(0.8, 1.35 * scale)
        context.setFillColor(CartoonRenderMetrics.ink.withAlpha(0.11).cgColor)

        var y = spacing * 0.75
        while y < bounds.height {
            var x = spacing * 0.75
            while x < bounds.width {
                let dotRect = CGRect(
                    x: x - dotRadius,
                    y: y - dotRadius,
                    width: dotRadius * 2.0,
                    height: dotRadius * 2.0
                )
                context.fillEllipse(in: dotRect)
                x += spacing
            }
            y += spacing
        }
    }

    // MARK: - Layer 2: Cartoon Window Chrome & Shadows

    private func drawDesktopWindow(
        _ window: EvaluatedWindowState,
        in rect: CGRect,
        isFocused: Bool,
        sceneTime: Double,
        scale: CGFloat,
        context: CGContext
    ) {
        let cornerRadius = CartoonRenderMetrics.windowCornerRadius * scale
        let borderWidth = CartoonRenderMetrics.windowBorderWidth * scale
        let titleBarHeight = min(rect.height * 0.45, CartoonRenderMetrics.titleBarHeight * scale)
        let dividerHeight = max(1.0, 2.2 * scale)

        let windowPath = Self.roundedRectPath(rect, radius: cornerRadius)

        // 1. Soft Ambient Shadow + Crisp Comic Offset Shadow
        // Note: `setShadow` offset is evaluated in unflipped device space (+y up), so negative height casts downward.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -(isFocused ? 10.0 : 4.0) * scale),
            blur: (isFocused ? 20.0 : 8.0) * scale,
            color: CartoonRenderMetrics.ink.withAlpha(isFocused ? 0.14 : 0.07).cgColor
        )
        context.setFillColor(CartoonRenderMetrics.surfacePaper.cgColor)
        context.addPath(windowPath)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -(isFocused ? 5.0 : 3.0) * scale),
            blur: (isFocused ? 1.5 : 0.8) * scale,
            color: CartoonRenderMetrics.ink.withAlpha(isFocused ? 0.23 : 0.13).cgColor
        )
        context.setFillColor(CartoonRenderMetrics.surfacePaper.cgColor)
        context.addPath(windowPath)
        context.fillPath()
        context.restoreGState()

        // 2. Clipped Window Interior (Title Bar + Divider + Polymorphic Body Content)
        context.saveGState()
        context.addPath(windowPath)
        context.clip()

        // Base surface fill
        context.setFillColor(CartoonRenderMetrics.surfacePaper.cgColor)
        context.fill(rect)

        // Title Bar
        let titleBarRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: titleBarHeight
        )
        drawWindowTitleBar(
            window: window,
            in: titleBarRect,
            isFocused: isFocused,
            scale: scale,
            context: context
        )

        // Ink Divider Below Title Bar
        let dividerRect = CGRect(
            x: rect.minX,
            y: titleBarRect.maxY,
            width: rect.width,
            height: dividerHeight
        )
        context.setFillColor(CartoonRenderMetrics.ink.cgColor)
        context.fill(dividerRect)

        // Window Content Bounds
        let contentRect = CGRect(
            x: rect.minX,
            y: dividerRect.maxY,
            width: rect.width,
            height: max(0, rect.maxY - dividerRect.maxY)
        )
        if contentRect.height > 4 && contentRect.width > 4 {
            context.saveGState()
            context.clip(to: contentRect)
            drawWindowContent(
                window.initialContent,
                windowAccent: window.accent,
                windowSpawnTime: window.spawnTime,
                sceneTime: sceneTime,
                in: contentRect,
                scale: scale,
                context: context
            )
            context.restoreGState()
        }

        // Top Cel-Shaded Inner White Sheen
        let sheenInsetRect = rect.insetBy(dx: borderWidth * 0.9, dy: borderWidth * 0.9)
        if sheenInsetRect.width > 8 && sheenInsetRect.height > 8 {
            let sheenPath = Self.roundedRectPath(sheenInsetRect, radius: max(2, cornerRadius - borderWidth * 0.8))
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleBarHeight * 0.65))
            context.addPath(sheenPath)
            context.setStrokeColor(CartoonRenderMetrics.white.withAlpha(0.55).cgColor)
            context.setLineWidth(2.2 * scale)
            context.strokePath()
            context.restoreGState()
        }

        context.restoreGState() // End interior clip

        // 3. Bold Outer Cartoon Ink Outline (inset by half stroke width so it matches SwiftUI `.strokeBorder`)
        let borderRect = rect.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5)
        let borderPath = Self.roundedRectPath(borderRect, radius: max(2, cornerRadius - borderWidth * 0.5))
        context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
        context.setLineWidth(borderWidth)
        context.addPath(borderPath)
        context.strokePath()
    }

    private func drawWindowTitleBar(
        window: EvaluatedWindowState,
        in rect: CGRect,
        isFocused: Bool,
        scale: CGFloat,
        context: CGContext
    ) {
        let fillRGBA = isFocused ? window.accent.titleBarRGBA : window.accent.titleBarInactiveRGBA
        context.setFillColor(fillRGBA.cgColor)
        context.fill(rect)

        // Subtle top inner highlight strip
        context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.45).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2.0 * scale))

        // Squishy Traffic Light Buttons Cluster
        let buttonDiameter = 16.0 * scale
        let buttonSpacing = 8.0 * scale
        let clusterStartX = rect.minX + 18.0 * scale
        let buttonY = rect.midY - buttonDiameter * 0.5

        let trafficColors: [CartoonRGBA] = isFocused
            ? [CartoonRenderMetrics.trafficClose, CartoonRenderMetrics.trafficMinimize, CartoonRenderMetrics.trafficZoom]
            : [CartoonRenderMetrics.trafficInactive, CartoonRenderMetrics.trafficInactive, CartoonRenderMetrics.trafficInactive]

        for (idx, tint) in trafficColors.enumerated() {
            let bx = clusterStartX + CGFloat(idx) * (buttonDiameter + buttonSpacing)
            let buttonRect = CGRect(x: bx, y: buttonY, width: buttonDiameter, height: buttonDiameter)
            drawSquishyTrafficLight(
                in: buttonRect,
                fill: tint,
                isActive: isFocused,
                scale: scale,
                context: context
            )
        }

        let trafficClusterMaxX = clusterStartX + 3.0 * buttonDiameter + 2.0 * buttonSpacing + 12.0 * scale

        // Trailing Accent Swatch & Content Badge Capsule
        let badgeLabel = window.initialContent.badgeLabel
        let badgeFont = Self.roundedFont(size: 10.0 * scale, weight: .heavy)
        let badgeTextSize = Self.measureSingleLine(badgeLabel, font: badgeFont)
        let badgePadX = 8.0 * scale
        let badgeHeight = 20.0 * scale
        let badgeWidth = badgeTextSize.width + badgePadX * 2.0
        let badgeRect = CGRect(
            x: rect.maxX - 14.0 * scale - badgeWidth,
            y: rect.midY - badgeHeight * 0.5,
            width: badgeWidth,
            height: badgeHeight
        )

        if badgeRect.minX > trafficClusterMaxX + 40.0 * scale {
            Self.fillAndStrokeCapsule(
                badgeRect,
                fill: CartoonRenderMetrics.white.withAlpha(0.80),
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.6 * scale,
                context: context
            )
            Self.drawSingleLine(
                badgeLabel,
                font: badgeFont,
                color: CartoonRenderMetrics.ink,
                centeredIn: badgeRect,
                context: context
            )

            // Vibrant Accent Pop Swatch Circle
            let swatchSize = 13.0 * scale
            let swatchRect = CGRect(
                x: badgeRect.minX - 6.0 * scale - swatchSize,
                y: rect.midY - swatchSize * 0.5,
                width: swatchSize,
                height: swatchSize
            )
            context.setFillColor(window.accent.vibrantPopRGBA.cgColor)
            context.fillEllipse(in: swatchRect)
            context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
            context.setLineWidth(1.6 * scale)
            context.strokeEllipse(in: swatchRect.insetBy(dx: 0.8 * scale, dy: 0.8 * scale))
        }

        // Centered Window Icon Pill + Title Text
        let availableTitleMinX = trafficClusterMaxX
        let availableTitleMaxX = max(availableTitleMinX, badgeRect.minX - 28.0 * scale)
        let availableTitleWidth = availableTitleMaxX - availableTitleMinX
        guard availableTitleWidth > 36.0 * scale else { return }

        let titleFont = Self.roundedFont(size: 13.5 * scale, weight: .bold)
        let iconBoxSize = 22.0 * scale
        let gap = 7.0 * scale
        let maxTextWidth = max(20.0 * scale, availableTitleWidth - iconBoxSize - gap)
        let fittedTitle = Self.truncateMiddle(window.title, font: titleFont, maxWidth: maxTextWidth)
        let measuredTitle = Self.measureSingleLine(fittedTitle, font: titleFont)

        let groupWidth = iconBoxSize + gap + measuredTitle.width
        let groupStartX = availableTitleMinX + max(0, (availableTitleWidth - groupWidth) * 0.5)

        // Icon Badge Box
        let iconRect = CGRect(
            x: groupStartX,
            y: rect.midY - iconBoxSize * 0.5,
            width: iconBoxSize,
            height: iconBoxSize
        )
        Self.fillAndStrokeRoundedRect(
            iconRect,
            radius: 7.0 * scale,
            fill: CartoonRenderMetrics.white.withAlpha(0.84),
            stroke: CartoonRenderMetrics.ink,
            lineWidth: 1.6 * scale,
            context: context
        )
        let iconGlyph = Self.glyphIndicator(for: window.initialContent.kind)
        Self.drawSingleLine(
            iconGlyph,
            font: Self.monospacedFont(size: 10.0 * scale, weight: .black),
            color: CartoonRenderMetrics.ink,
            centeredIn: iconRect,
            context: context
        )

        // Window Title Text
        let textRect = CGRect(
            x: iconRect.maxX + gap,
            y: rect.minY,
            width: measuredTitle.width + 4.0 * scale,
            height: rect.height
        )
        Self.drawSingleLine(
            fittedTitle,
            font: titleFont,
            color: CartoonRenderMetrics.ink.withAlpha(isFocused ? 1.0 : 0.72),
            leftAlignedIn: textRect,
            context: context
        )
    }

    private func drawSquishyTrafficLight(
        in rect: CGRect,
        fill: CartoonRGBA,
        isActive: Bool,
        scale: CGFloat,
        context: CGContext
    ) {
        let strokeW = CartoonRenderMetrics.controlBorderWidth * scale
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)

        // Rotated cartoon specular highlight ellipse
        context.saveGState()
        context.translateBy(x: rect.midX - 2.4 * scale, y: rect.midY - 3.0 * scale)
        context.rotate(by: -28.0 * .pi / 180.0)
        let specRect = CGRect(
            x: -2.75 * scale,
            y: -1.5 * scale,
            width: 5.5 * scale,
            height: 3.0 * scale
        )
        context.setFillColor(CartoonRenderMetrics.white.withAlpha(isActive ? 0.68 : 0.36).cgColor)
        context.fillEllipse(in: specRect)
        context.restoreGState()

        context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
        context.setLineWidth(strokeW)
        context.strokeEllipse(in: rect.insetBy(dx: strokeW * 0.5, dy: strokeW * 0.5))
    }

    // MARK: - Layer 3: Polymorphic Offscreen Window Contents

    private func drawWindowContent(
        _ content: WindowContent,
        windowAccent: CartoonAccent,
        windowSpawnTime: Double,
        sceneTime: Double,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        switch content {
        case let .video(payload):
            drawVideoWindowContent(
                payload: payload,
                accent: windowAccent,
                windowSpawnTime: windowSpawnTime,
                sceneTime: sceneTime,
                in: bounds,
                scale: scale,
                context: context
            )
        case let .codeSnippet(payload):
            drawCodeSnippetContent(
                payload: payload,
                accent: windowAccent,
                in: bounds,
                scale: scale,
                context: context
            )
        case let .browser(payload):
            drawBrowserWindowContent(
                payload: payload,
                accent: windowAccent,
                in: bounds,
                scale: scale,
                context: context
            )
        case let .image(payload):
            drawImageWindowContent(
                payload: payload,
                accent: windowAccent,
                in: bounds,
                scale: scale,
                context: context
            )
        }
    }

    // MARK: 3A. Synchronized Video Window Content (AVAsset Frame + Procedural Cartoon Stage)

    private func drawVideoWindowContent(
        payload: VideoWindowPayload,
        accent: CartoonAccent,
        windowSpawnTime: Double,
        sceneTime: Double,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let pad = 12.0 * scale
        let transportHeight = 28.0 * scale
        let gap = 10.0 * scale

        let inner = bounds.insetBy(dx: pad, dy: pad)
        guard inner.width > 20, inner.height > 20 else { return }

        let hasSpaceForTransport = inner.height > (transportHeight + gap + 48.0 * scale)
        let stageHeight = hasSpaceForTransport ? (inner.height - transportHeight - gap) : inner.height
        let stageRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: stageHeight)
        let stageRadius = 12.0 * scale
        let stagePath = Self.roundedRectPath(stageRect, radius: stageRadius)

        let syncMediaTime = VideoTimelineSync.mediaTimestamp(
            for: payload,
            windowSpawnTime: windowSpawnTime,
            timelineTime: sceneTime
        )

        // Clipped Video Viewport
        context.saveGState()
        context.addPath(stagePath)
        context.clip()

        var renderedRealAssetFrame = false
        if let assetURL = payload.assetURL,
           let videoCGImage = frameProvider.copyVideoFrame(from: assetURL, at: syncMediaTime) {
            // Fill dark studio mat behind aspect-fitted/filled frame
            context.setFillColor(CartoonRGBA(red: 0.08, green: 0.09, blue: 0.12).cgColor)
            context.fill(stageRect)
            let drawRect = Self.aspectFillRect(
                imageSize: CGSize(width: videoCGImage.width, height: videoCGImage.height),
                in: stageRect
            )
            Self.drawCGImage(videoCGImage, in: drawRect, context: context)
            renderedRealAssetFrame = true
        }

        if !renderedRealAssetFrame {
            drawProceduralCartoonVideoStage(
                payload: payload,
                syncTime: syncMediaTime,
                in: stageRect,
                scale: scale,
                context: context
            )
        }

        // Top HUD Badges inside Video Viewport
        let hudPad = 10.0 * scale
        let statusHeight = 20.0 * scale
        let statusText = payload.assetURL != nil ? "SYNC" : (payload.isPlaying ? "PLAYING" : "STAGE")
        let statusFont = Self.roundedFont(size: 9.5 * scale, weight: .heavy)
        let statusTextSize = Self.measureSingleLine(statusText, font: statusFont)
        let statusWidth = statusTextSize.width + 26.0 * scale
        let statusRect = CGRect(
            x: stageRect.minX + hudPad,
            y: stageRect.minY + hudPad,
            width: statusWidth,
            height: statusHeight
        )
        if statusRect.maxX < stageRect.maxX - hudPad {
            context.setFillColor(CartoonRenderMetrics.ink.withAlpha(0.84).cgColor)
            context.addPath(Self.roundedRectPath(statusRect, radius: statusHeight * 0.5))
            context.fillPath()

            let dotD = 7.0 * scale
            let dotRect = CGRect(
                x: statusRect.minX + 8.0 * scale,
                y: statusRect.midY - dotD * 0.5,
                width: dotD,
                height: dotD
            )
            context.setFillColor(CartoonRenderMetrics.trafficClose.cgColor)
            context.fillEllipse(in: dotRect)

            let labelBox = CGRect(
                x: dotRect.maxX + 5.0 * scale,
                y: statusRect.minY,
                width: statusTextSize.width + 4.0 * scale,
                height: statusRect.height
            )
            Self.drawSingleLine(
                statusText,
                font: statusFont,
                color: CartoonRenderMetrics.white,
                leftAlignedIn: labelBox,
                context: context
            )
        }

        let specString = "\(payload.resolutionTag) • \(payload.fps)fps"
        let specFont = Self.monospacedFont(size: 9.5 * scale, weight: .bold)
        let specSize = Self.measureSingleLine(specString, font: specFont)
        let specWidth = specSize.width + 16.0 * scale
        let specRect = CGRect(
            x: stageRect.maxX - hudPad - specWidth,
            y: stageRect.minY + hudPad,
            width: specWidth,
            height: statusHeight
        )
        if specRect.minX > statusRect.maxX + 8.0 * scale {
            Self.fillAndStrokeCapsule(
                specRect,
                fill: CartoonRenderMetrics.white.withAlpha(0.90),
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.5 * scale,
                context: context
            )
            Self.drawSingleLine(
                specString,
                font: specFont,
                color: CartoonRenderMetrics.ink,
                centeredIn: specRect,
                context: context
            )
        }

        context.restoreGState()

        // Stage Ink Border
        let stageBorderW = 2.0 * scale
        context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
        context.setLineWidth(stageBorderW)
        context.addPath(Self.roundedRectPath(stageRect.insetBy(dx: stageBorderW * 0.5, dy: stageBorderW * 0.5), radius: stageRadius))
        context.strokePath()

        // Cartoon Transport & Scrub Bar
        guard hasSpaceForTransport else { return }
        let transportRect = CGRect(
            x: inner.minX,
            y: stageRect.maxY + gap,
            width: inner.width,
            height: transportHeight
        )

        let playBtnRect = CGRect(
            x: transportRect.minX,
            y: transportRect.minY,
            width: 30.0 * scale,
            height: transportHeight
        )
        Self.fillAndStrokeRoundedRect(
            playBtnRect,
            radius: 9.0 * scale,
            fill: accent.titleBarRGBA,
            stroke: CartoonRenderMetrics.ink,
            lineWidth: 1.8 * scale,
            context: context
        )
        // Play triangle glyph
        let triSize = 8.0 * scale
        context.saveGState()
        context.setFillColor(CartoonRenderMetrics.ink.cgColor)
        context.move(to: CGPoint(x: playBtnRect.midX - triSize * 0.38, y: playBtnRect.midY - triSize * 0.52))
        context.addLine(to: CGPoint(x: playBtnRect.midX + triSize * 0.55, y: playBtnRect.midY))
        context.addLine(to: CGPoint(x: playBtnRect.midX - triSize * 0.38, y: playBtnRect.midY + triSize * 0.52))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        let duration = max(0.1, payload.durationSeconds)
        let progress = min(max(syncMediaTime / duration, 0.0), 1.0)
        let timeLabel = "\(Self.formatMMSS(syncMediaTime)) / \(Self.formatMMSS(duration))"
        let timeFont = Self.monospacedFont(size: 10.5 * scale, weight: .bold)
        let timeWidth = Self.measureSingleLine(timeLabel, font: timeFont).width

        let timeRect = CGRect(
            x: transportRect.maxX - timeWidth,
            y: transportRect.minY,
            width: timeWidth + 2.0 * scale,
            height: transportRect.height
        )
        if timeRect.minX > playBtnRect.maxX + 36.0 * scale {
            Self.drawSingleLine(
                timeLabel,
                font: timeFont,
                color: CartoonRenderMetrics.inkSubtle,
                leftAlignedIn: timeRect,
                context: context
            )

            let barMinX = playBtnRect.maxX + 10.0 * scale
            let barMaxX = timeRect.minX - 10.0 * scale
            let barWidth = max(16.0 * scale, barMaxX - barMinX)
            let barHeight = 12.0 * scale
            let trackBarRect = CGRect(
                x: barMinX,
                y: transportRect.midY - barHeight * 0.5,
                width: barWidth,
                height: barHeight
            )
            Self.fillAndStrokeCapsule(
                trackBarRect,
                fill: CartoonRenderMetrics.surfaceSecondary,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.8 * scale,
                context: context
            )

            let filledW = min(barWidth, max(barHeight, barWidth * CGFloat(progress)))
            let filledRect = CGRect(
                x: barMinX,
                y: trackBarRect.minY,
                width: filledW,
                height: barHeight
            )
            Self.fillAndStrokeCapsule(
                filledRect,
                fill: accent.vibrantPopRGBA,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.8 * scale,
                context: context
            )
        }
    }

    private func drawProceduralCartoonVideoStage(
        payload: VideoWindowPayload,
        syncTime: Double,
        in stageRect: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let stageColors: [CartoonRGBA] = switch payload.scene {
        case .rocketLaunch:
            [CartoonRGBA(red: 0.18, green: 0.21, blue: 0.36), CartoonRGBA(red: 0.33, green: 0.28, blue: 0.56)]
        case .synthStudio:
            [CartoonRGBA(red: 0.15, green: 0.34, blue: 0.36), CartoonRGBA(red: 0.22, green: 0.52, blue: 0.49)]
        case .mascotWave:
            [CartoonRGBA(red: 0.99, green: 0.78, blue: 0.58), CartoonRGBA(red: 0.96, green: 0.56, blue: 0.65)]
        }

        if let grad = CGGradient(
            colorsSpace: colorSpace,
            colors: stageColors.map(\.cgColor) as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                grad,
                start: CGPoint(x: stageRect.minX, y: stageRect.minY),
                end: CGPoint(x: stageRect.maxX, y: stageRect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // Decorative floating clouds / orbs
        let orbA = 90.0 * scale
        context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.16).cgColor)
        context.fillEllipse(
            in: CGRect(
                x: stageRect.midX - stageRect.width * 0.26 - orbA * 0.5,
                y: stageRect.midY + 18.0 * scale - orbA * 0.5,
                width: orbA,
                height: orbA
            )
        )

        let orbB = 64.0 * scale
        context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.12).cgColor)
        context.fillEllipse(
            in: CGRect(
                x: stageRect.midX + stageRect.width * 0.28 - orbB * 0.5,
                y: stageRect.midY - 14.0 * scale - orbB * 0.5,
                width: orbB,
                height: orbB
            )
        )

        // Bouncing Center Cartoon Prop Card
        let bounceOffset = CGFloat(Darwin.sin(syncTime * 3.2) * 7.0) * scale
        let compact = max(0.72, min(1.0, min(stageRect.width / (340.0 * scale), stageRect.height / (180.0 * scale))))
        let cardW = 84.0 * scale * compact
        let cardH = 68.0 * scale * compact
        let cardRect = CGRect(
            x: stageRect.midX - cardW * 0.5,
            y: stageRect.midY - cardH * 0.62 + bounceOffset,
            width: cardW,
            height: cardH
        )

        // Card offset shadow
        let shadowRect = cardRect.offsetBy(dx: 0, dy: 4.0 * scale)
        context.setFillColor(CartoonRenderMetrics.ink.withAlpha(0.35).cgColor)
        context.addPath(Self.roundedRectPath(shadowRect, radius: 20.0 * scale * compact))
        context.fillPath()

        Self.fillAndStrokeRoundedRect(
            cardRect,
            radius: 20.0 * scale * compact,
            fill: CartoonRGBA(red: 1.0, green: 0.92, blue: 0.68),
            stroke: CartoonRenderMetrics.ink,
            lineWidth: 2.5 * scale * compact,
            context: context
        )

        let sceneGlyph = switch payload.scene {
        case .rocketLaunch: "★"
        case .synthStudio: "♫"
        case .mascotWave: "☺"
        }
        Self.drawSingleLine(
            sceneGlyph,
            font: Self.roundedFont(size: 26.0 * scale * compact, weight: .black),
            color: CartoonRenderMetrics.ink,
            centeredIn: cardRect,
            context: context
        )

        // Clip Title Pill
        let titleFont = Self.roundedFont(size: 11.5 * scale * compact, weight: .bold)
        let fittedClip = Self.truncateMiddle(payload.clipTitle, font: titleFont, maxWidth: stageRect.width - 28.0 * scale)
        let titleSize = Self.measureSingleLine(fittedClip, font: titleFont)
        let pillH = 22.0 * scale * compact
        let pillW = titleSize.width + 20.0 * scale * compact
        let pillRect = CGRect(
            x: stageRect.midX - pillW * 0.5,
            y: cardRect.maxY + 10.0 * scale * compact - bounceOffset,
            width: pillW,
            height: pillH
        )
        if pillRect.maxY <= stageRect.maxY - 4.0 * scale {
            context.setFillColor(CartoonRenderMetrics.ink.withAlpha(0.68).cgColor)
            context.addPath(Self.roundedRectPath(pillRect, radius: pillH * 0.5))
            context.fillPath()
            Self.drawSingleLine(
                fittedClip,
                font: titleFont,
                color: CartoonRenderMetrics.white,
                centeredIn: pillRect,
                context: context
            )
        }
    }

    // MARK: 3B. Syntax-Highlighted Code Snippet Content

    private func drawCodeSnippetContent(
        payload: CodeSnippetPayload,
        accent: CartoonAccent,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        context.setFillColor(CartoonRenderMetrics.codeBackground.cgColor)
        context.fill(bounds)

        // Top Code Tab Bar
        let tabBarHeight = 36.0 * scale
        let tabBarRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: tabBarHeight)
        context.setFillColor(CartoonRGBA(red: 0, green: 0, blue: 0, alpha: 0.24).cgColor)
        context.fill(tabBarRect)

        let fileFont = Self.monospacedFont(size: 11.5 * scale, weight: .bold)
        let fileSize = Self.measureSingleLine(payload.fileName, font: fileFont)
        let fileTabRect = CGRect(
            x: tabBarRect.minX + 12.0 * scale,
            y: tabBarRect.midY - 12.5 * scale,
            width: min(bounds.width * 0.62, fileSize.width + 22.0 * scale),
            height: 25.0 * scale
        )
        context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.10).cgColor)
        context.addPath(Self.roundedRectPath(fileTabRect, radius: 8.0 * scale))
        context.fillPath()
        Self.drawSingleLine(
            payload.fileName,
            font: fileFont,
            color: CartoonRenderMetrics.white,
            centeredIn: fileTabRect,
            context: context
        )

        let langFont = Self.roundedFont(size: 10.0 * scale, weight: .heavy)
        let langSize = Self.measureSingleLine(payload.language, font: langFont)
        let langRect = CGRect(
            x: fileTabRect.maxX + 8.0 * scale,
            y: tabBarRect.midY - 10.0 * scale,
            width: langSize.width + 14.0 * scale,
            height: 20.0 * scale
        )
        if langRect.maxX < tabBarRect.maxX - 10.0 * scale {
            context.setFillColor(accent.titleBarRGBA.cgColor)
            context.addPath(Self.roundedRectPath(langRect, radius: 10.0 * scale))
            context.fillPath()
            Self.drawSingleLine(
                payload.language,
                font: langFont,
                color: CartoonRenderMetrics.ink,
                centeredIn: langRect,
                context: context
            )
        }

        // Syntax-Highlighted Source Lines
        let codeArea = CGRect(
            x: bounds.minX + 10.0 * scale,
            y: tabBarRect.maxY + 8.0 * scale,
            width: max(0, bounds.width - 20.0 * scale),
            height: max(0, bounds.maxY - tabBarRect.maxY - 14.0 * scale)
        )
        guard codeArea.width > 20, codeArea.height > 12 else { return }

        let lines = payload.sourceCode.components(separatedBy: .newlines)
        let lineFont = Self.monospacedFont(size: 12.0 * scale, weight: .medium)
        let numFont = Self.monospacedFont(size: 11.5 * scale, weight: .semibold)
        let rowHeight = 20.0 * scale

        for (index, lineText) in lines.enumerated() {
            let rowY = codeArea.minY + CGFloat(index) * rowHeight
            if rowY > codeArea.maxY { break }

            let lineNumber = index + 1
            let isHighlighted = payload.highlightedLines.contains(lineNumber)
            let rowRect = CGRect(x: codeArea.minX, y: rowY, width: codeArea.width, height: rowHeight - 1.5 * scale)

            if isHighlighted {
                context.setFillColor(accent.vibrantPopRGBA.withAlpha(0.22).cgColor)
                context.addPath(Self.roundedRectPath(rowRect, radius: 6.0 * scale))
                context.fillPath()

                let barRect = CGRect(
                    x: rowRect.minX,
                    y: rowRect.minY + 2.0 * scale,
                    width: 3.0 * scale,
                    height: max(2.0, rowRect.height - 4.0 * scale)
                )
                context.setFillColor(accent.titleBarRGBA.cgColor)
                context.addPath(Self.roundedRectPath(barRect, radius: 1.5 * scale))
                context.fillPath()
            }

            // Gutter line number
            let numStr = String(format: "%2d", lineNumber)
            let numColor = isHighlighted ? accent.titleBarRGBA : CartoonRenderMetrics.white.withAlpha(0.32)
            let numRect = CGRect(x: rowRect.minX + 8.0 * scale, y: rowRect.minY, width: 22.0 * scale, height: rowRect.height)
            Self.drawSingleLine(
                numStr,
                font: numFont,
                color: numColor,
                leftAlignedIn: numRect,
                context: context
            )

            // Syntax-colored code line
            let codeStartX = numRect.maxX + 10.0 * scale
            let attributed = Self.syntaxHighlightedLine(lineText, font: lineFont)
            Self.drawAttributedSingleLine(
                attributed,
                in: CGRect(
                    x: codeStartX,
                    y: rowRect.minY,
                    width: max(0, rowRect.maxX - codeStartX - 4.0 * scale),
                    height: rowRect.height
                ),
                font: lineFont,
                context: context
            )
        }
    }

    // MARK: 3C. Cartoon Browser / Web Snapshot Content

    private func drawBrowserWindowContent(
        payload: BrowserWindowPayload,
        accent: CartoonAccent,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        context.setFillColor(CartoonRenderMetrics.surfacePaper.cgColor)
        context.fill(bounds)

        // Navigation / URL Address Bar
        let navHeight = 42.0 * scale
        let navRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: navHeight)
        context.setFillColor(CartoonRenderMetrics.surfaceSecondary.cgColor)
        context.fill(navRect)

        // Back / Forward Circle Pills
        let circleD = 24.0 * scale
        let backRect = CGRect(x: navRect.minX + 12.0 * scale, y: navRect.midY - circleD * 0.5, width: circleD, height: circleD)
        let fwdRect = CGRect(x: backRect.maxX + 4.0 * scale, y: backRect.minY, width: circleD, height: circleD)
        for navCircle in [backRect, fwdRect] {
            context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.85).cgColor)
            context.fillEllipse(in: navCircle)
            context.setStrokeColor(CartoonRenderMetrics.ink.withAlpha(0.65).cgColor)
            context.setLineWidth(1.5 * scale)
            context.strokeEllipse(in: navCircle.insetBy(dx: 0.75 * scale, dy: 0.75 * scale))
        }
        Self.drawSingleLine("‹", font: Self.roundedFont(size: 13.0 * scale, weight: .black), color: CartoonRenderMetrics.inkSubtle, centeredIn: backRect, context: context)
        Self.drawSingleLine("›", font: Self.roundedFont(size: 13.0 * scale, weight: .black), color: CartoonRenderMetrics.inkSubtle, centeredIn: fwdRect, context: context)

        // Reload Circle Pill
        let reloadD = 26.0 * scale
        let reloadRect = CGRect(x: navRect.maxX - 12.0 * scale - reloadD, y: navRect.midY - reloadD * 0.5, width: reloadD, height: reloadD)
        if reloadRect.minX > fwdRect.maxX + 40.0 * scale {
            context.setFillColor(CartoonRenderMetrics.white.cgColor)
            context.fillEllipse(in: reloadRect)
            context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
            context.setLineWidth(1.7 * scale)
            context.strokeEllipse(in: reloadRect.insetBy(dx: 0.85 * scale, dy: 0.85 * scale))
            Self.drawSingleLine("↻", font: Self.roundedFont(size: 12.0 * scale, weight: .black), color: CartoonRenderMetrics.ink, centeredIn: reloadRect, context: context)

            // URL Capsule
            let urlBarHeight = 27.0 * scale
            let urlRect = CGRect(
                x: fwdRect.maxX + 8.0 * scale,
                y: navRect.midY - urlBarHeight * 0.5,
                width: reloadRect.minX - fwdRect.maxX - 16.0 * scale,
                height: urlBarHeight
            )
            Self.fillAndStrokeCapsule(
                urlRect,
                fill: CartoonRenderMetrics.white,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.7 * scale,
                context: context
            )

            // HTTPS Green Dot + URL String + LIVE Pill
            let httpsDot = CGRect(x: urlRect.minX + 10.0 * scale, y: urlRect.midY - 3.5 * scale, width: 7.0 * scale, height: 7.0 * scale)
            context.setFillColor(CartoonRenderMetrics.trafficZoom.cgColor)
            context.fillEllipse(in: httpsDot)

            let liveW = 36.0 * scale
            let liveH = 17.0 * scale
            let liveRect = CGRect(x: urlRect.maxX - 7.0 * scale - liveW, y: urlRect.midY - liveH * 0.5, width: liveW, height: liveH)
            if liveRect.minX > httpsDot.maxX + 24.0 * scale {
                context.setFillColor(accent.titleBarRGBA.cgColor)
                context.addPath(Self.roundedRectPath(liveRect, radius: liveH * 0.5))
                context.fillPath()
                Self.drawSingleLine("LIVE", font: Self.roundedFont(size: 8.8 * scale, weight: .heavy), color: CartoonRenderMetrics.ink, centeredIn: liveRect, context: context)
            }

            let urlFont = Self.roundedFont(size: 11.5 * scale, weight: .semibold)
            let urlMaxW = max(10, liveRect.minX - httpsDot.maxX - 14.0 * scale)
            let fittedURL = Self.truncateMiddle(payload.urlString, font: urlFont, maxWidth: urlMaxW)
            Self.drawSingleLine(
                fittedURL,
                font: urlFont,
                color: CartoonRenderMetrics.ink,
                leftAlignedIn: CGRect(x: httpsDot.maxX + 6.0 * scale, y: urlRect.minY, width: urlMaxW, height: urlRect.height),
                context: context
            )
        }

        // Hairline divider
        let divY = navRect.maxY
        context.setFillColor(CartoonRenderMetrics.ink.withAlpha(0.18).cgColor)
        context.fill(CGRect(x: bounds.minX, y: divY, width: bounds.width, height: 1.5 * scale))

        let domViewport = CGRect(
            x: bounds.minX,
            y: divY + 1.5 * scale,
            width: bounds.width,
            height: max(0, bounds.maxY - divY - 1.5 * scale)
        )
        guard domViewport.width > 20, domViewport.height > 20 else { return }

        // If a raster DOM snapshot is provided, composite it directly
        if let snapImage = frameProvider.rasterImage(fromData: payload.snapshotImageData) {
            let drawRect = Self.aspectFillRect(
                imageSize: CGSize(width: snapImage.width, height: snapImage.height),
                in: domViewport
            )
            context.saveGState()
            context.clip(to: domViewport)
            Self.drawCGImage(snapImage, in: drawRect, context: context)
            context.restoreGState()
            return
        }

        // Vector Cartoon DOM Layout
        let pad = 14.0 * scale
        let contentArea = domViewport.insetBy(dx: pad, dy: pad)
        guard contentArea.width > 30, contentArea.height > 30 else { return }

        // Hero Banner Card
        let heroHeight = min(contentArea.height * 0.56, 128.0 * scale)
        let heroRect = CGRect(x: contentArea.minX, y: contentArea.minY, width: contentArea.width, height: heroHeight)
        Self.fillAndStrokeRoundedRect(
            heroRect,
            radius: 14.0 * scale,
            fill: accent.softTintRGBA,
            stroke: CartoonRenderMetrics.ink,
            lineWidth: 2.0 * scale,
            context: context
        )

        let heroInner = heroRect.insetBy(dx: 14.0 * scale, dy: 12.0 * scale)
        let studioTagFont = Self.roundedFont(size: 9.0 * scale, weight: .heavy)
        let studioTag = "SCREENPLAY STUDIO"
        let studioSize = Self.measureSingleLine(studioTag, font: studioTagFont)
        let studioPill = CGRect(x: heroInner.minX, y: heroInner.minY, width: studioSize.width + 16.0 * scale, height: 19.0 * scale)
        if studioPill.maxX < heroInner.maxX {
            Self.fillAndStrokeCapsule(
                studioPill,
                fill: CartoonRenderMetrics.white.withAlpha(0.88),
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.4 * scale,
                context: context
            )
            Self.drawSingleLine(studioTag, font: studioTagFont, color: CartoonRenderMetrics.ink, centeredIn: studioPill, context: context)
        }

        let headlineFont = Self.roundedFont(size: 16.0 * scale, weight: .heavy)
        let headlineRect = CGRect(
            x: heroInner.minX,
            y: studioPill.maxY + 7.0 * scale,
            width: heroInner.width,
            height: max(0, heroInner.maxY - studioPill.maxY - 7.0 * scale)
        )
        if headlineRect.height > 14.0 * scale {
            let usedH = Self.drawWrappedText(
                payload.heroHeadline,
                font: headlineFont,
                color: CartoonRenderMetrics.ink,
                in: headlineRect,
                lineSpacing: 2.0 * scale,
                context: context
            )

            let subRect = CGRect(
                x: heroInner.minX,
                y: headlineRect.minY + usedH + 4.0 * scale,
                width: heroInner.width,
                height: max(0, heroInner.maxY - (headlineRect.minY + usedH + 4.0 * scale))
            )
            if subRect.height > 12.0 * scale {
                _ = Self.drawWrappedText(
                    payload.heroSubtitle,
                    font: Self.roundedFont(size: 11.5 * scale, weight: .medium),
                    color: CartoonRenderMetrics.inkSubtle,
                    in: subRect,
                    lineSpacing: 1.5 * scale,
                    context: context
                )
            }
        }

        // Tab Row
        let tabsY = heroRect.maxY + 11.0 * scale
        let tabH = 24.0 * scale
        guard tabsY + tabH <= contentArea.maxY else { return }

        var cursorX = contentArea.minX
        let tabFont = Self.roundedFont(size: 10.8 * scale, weight: .bold)
        for tab in BrowserShowcaseTab.allCases {
            let labelSize = Self.measureSingleLine(tab.label, font: tabFont)
            let pillW = labelSize.width + 20.0 * scale
            let pillRect = CGRect(x: cursorX, y: tabsY, width: pillW, height: tabH)
            if pillRect.maxX > contentArea.maxX { break }

            let isSelected = (payload.selectedTab == tab)
            Self.fillAndStrokeCapsule(
                pillRect,
                fill: isSelected ? accent.titleBarRGBA : CartoonRenderMetrics.surfaceSecondary,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.6 * scale,
                context: context
            )
            Self.drawSingleLine(tab.label, font: tabFont, color: CartoonRenderMetrics.ink, centeredIn: pillRect, context: context)
            cursorX = pillRect.maxX + 8.0 * scale
        }

        // Feature Cards Row
        let cardsY = tabsY + tabH + 10.0 * scale
        let cardsHeight = contentArea.maxY - cardsY
        guard cardsHeight >= 46.0 * scale else { return }

        let cardGap = 10.0 * scale
        let cardWidth = (contentArea.width - cardGap) * 0.5
        let cardH = min(cardsHeight, 62.0 * scale)

        let cards: [(String, String)] = switch payload.selectedTab {
        case .product:
            [("120Hz Drag", "Zero-lag choreography"), ("Auto Capture", "Timestamped motion stream")]
        case .features:
            [("Dynamic Z-Stack", "Instant foreground pop"), ("Pinned Resize", "Zero-drift corner math")]
        case .releaseNotes:
            [("Milestone 3 Export", "4K60 MP4 & ProRes 422"), ("Stereo Audio Mix", "Multi-track AAC engine")]
        }

        for (i, item) in cards.prefix(2).enumerated() {
            let cx = contentArea.minX + CGFloat(i) * (cardWidth + cardGap)
            let cardRect = CGRect(x: cx, y: cardsY, width: cardWidth, height: cardH)
            Self.fillAndStrokeRoundedRect(
                cardRect,
                radius: 11.0 * scale,
                fill: CartoonRenderMetrics.white,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.8 * scale,
                context: context
            )

            let badgeBox = CGRect(x: cardRect.minX + 10.0 * scale, y: cardRect.minY + 10.0 * scale, width: 26.0 * scale, height: 26.0 * scale)
            Self.fillAndStrokeRoundedRect(
                badgeBox,
                radius: 8.0 * scale,
                fill: accent.titleBarRGBA,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.5 * scale,
                context: context
            )
            Self.drawSingleLine("✦", font: Self.roundedFont(size: 12.0 * scale, weight: .black), color: CartoonRenderMetrics.ink, centeredIn: badgeBox, context: context)

            let textX = badgeBox.maxX + 8.0 * scale
            let textW = max(10, cardRect.maxX - textX - 8.0 * scale)
            Self.drawSingleLine(
                item.0,
                font: Self.roundedFont(size: 11.5 * scale, weight: .bold),
                color: CartoonRenderMetrics.ink,
                leftAlignedIn: CGRect(x: textX, y: cardRect.minY + 9.0 * scale, width: textW, height: 16.0 * scale),
                context: context
            )
            Self.drawSingleLine(
                item.1,
                font: Self.roundedFont(size: 10.2 * scale, weight: .medium),
                color: CartoonRenderMetrics.inkSubtle,
                leftAlignedIn: CGRect(x: textX, y: cardRect.minY + 26.0 * scale, width: textW, height: 15.0 * scale),
                context: context
            )
        }
    }

    // MARK: 3D. Raster Image Asset Content

    private func drawImageWindowContent(
        payload: ImageWindowPayload,
        accent: CartoonAccent,
        in bounds: CGRect,
        scale: CGFloat,
        context: CGContext
    ) {
        let pad = 12.0 * scale
        let footerH = 22.0 * scale
        let gap = 8.0 * scale

        let inner = bounds.insetBy(dx: pad, dy: pad)
        guard inner.width > 20, inner.height > 20 else { return }

        let showFooter = inner.height > (footerH + gap + 48.0 * scale)
        let stageH = showFooter ? (inner.height - footerH - gap) : inner.height
        let stageRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: stageH)
        let stageRadius = 12.0 * scale
        let stagePath = Self.roundedRectPath(stageRect, radius: stageRadius)

        context.saveGState()
        context.addPath(stagePath)
        context.clip()

        context.setFillColor(CartoonRenderMetrics.surfaceSecondary.cgColor)
        context.fill(stageRect)

        let decodedRaster = frameProvider.rasterImage(fromData: payload.imageData)
            ?? frameProvider.rasterImage(fromURL: payload.imageURL)

        if let cgImage = decodedRaster {
            let imgSize = CGSize(width: cgImage.width, height: cgImage.height)
            let destRect = payload.aspectFit
                ? Self.aspectFitRect(imageSize: imgSize, in: stageRect)
                : Self.aspectFillRect(imageSize: imgSize, in: stageRect)
            Self.drawCGImage(cgImage, in: destRect, context: context)
        } else {
            // Studio Illustration Preset Card
            if let grad = CGGradient(
                colorsSpace: colorSpace,
                colors: [accent.softTintRGBA.cgColor, CartoonRenderMetrics.white.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                context.drawLinearGradient(
                    grad,
                    start: CGPoint(x: stageRect.minX, y: stageRect.minY),
                    end: CGPoint(x: stageRect.maxX, y: stageRect.maxY),
                    options: []
                )
            }

            let boxW = 78.0 * scale
            let boxH = 64.0 * scale
            let boxRect = CGRect(
                x: stageRect.midX - boxW * 0.5,
                y: stageRect.midY - boxH * 0.62,
                width: boxW,
                height: boxH
            )
            Self.fillAndStrokeRoundedRect(
                boxRect,
                radius: 18.0 * scale,
                fill: accent.titleBarRGBA,
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 2.2 * scale,
                context: context
            )
            Self.drawSingleLine(
                "▣",
                font: Self.roundedFont(size: 28.0 * scale, weight: .black),
                color: CartoonRenderMetrics.ink,
                centeredIn: boxRect,
                context: context
            )
            Self.drawSingleLine(
                payload.assetName,
                font: Self.roundedFont(size: 11.5 * scale, weight: .heavy),
                color: CartoonRenderMetrics.ink,
                centeredIn: CGRect(x: stageRect.minX + 8.0 * scale, y: boxRect.maxY + 6.0 * scale, width: stageRect.width - 16.0 * scale, height: 18.0 * scale),
                context: context
            )
        }

        // Dimensions Tag Pill
        let dimFont = Self.monospacedFont(size: 9.5 * scale, weight: .bold)
        let dimSize = Self.measureSingleLine(payload.dimensionsTag, font: dimFont)
        let dimRect = CGRect(
            x: stageRect.minX + 10.0 * scale,
            y: stageRect.minY + 10.0 * scale,
            width: dimSize.width + 16.0 * scale,
            height: 20.0 * scale
        )
        if dimRect.maxX < stageRect.maxX - 10.0 * scale {
            Self.fillAndStrokeCapsule(
                dimRect,
                fill: CartoonRenderMetrics.white.withAlpha(0.90),
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.4 * scale,
                context: context
            )
            Self.drawSingleLine(payload.dimensionsTag, font: dimFont, color: CartoonRenderMetrics.ink, centeredIn: dimRect, context: context)
        }

        context.restoreGState()

        let borderW = 2.0 * scale
        context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
        context.setLineWidth(borderW)
        context.addPath(Self.roundedRectPath(stageRect.insetBy(dx: borderW * 0.5, dy: borderW * 0.5), radius: stageRadius))
        context.strokePath()

        if showFooter {
            let footerRect = CGRect(x: inner.minX, y: stageRect.maxY + gap, width: inner.width, height: footerH)
            Self.drawSingleLine(
                payload.caption,
                font: Self.roundedFont(size: 11.0 * scale, weight: .bold),
                color: CartoonRenderMetrics.inkSubtle,
                leftAlignedIn: footerRect,
                context: context
            )
        }
    }

    // MARK: - Layer 4: Virtual Desktop Top Menu Bar

    private func drawVirtualDesktopMenuBar(
        scene: InterpolatedSceneState,
        visibleWindows: [EvaluatedWindowState],
        outputWidth: CGFloat,
        scale: CGFloat,
        context: CGContext
    ) {
        let barHeight = CartoonRenderMetrics.virtualMenuBarHeight * scale
        let barRect = CGRect(x: 0, y: 0, width: outputWidth, height: barHeight)

        context.setFillColor(CartoonRenderMetrics.white.withAlpha(0.82).cgColor)
        context.fill(barRect)

        // Bottom Ink Divider
        let borderH = 2.0 * scale
        context.setFillColor(CartoonRenderMetrics.ink.cgColor)
        context.fill(CGRect(x: 0, y: barHeight - borderH, width: outputWidth, height: borderH))

        // Brand Pill ("ScreenPlay OS")
        let brandText = "ScreenPlay OS"
        let brandFont = Self.roundedFont(size: 12.5 * scale, weight: .heavy)
        let brandSize = Self.measureSingleLine(brandText, font: brandFont)
        let brandH = 24.0 * scale
        let brandRect = CGRect(
            x: 14.0 * scale,
            y: (barHeight - borderH - brandH) * 0.5,
            width: brandSize.width + 24.0 * scale,
            height: brandH
        )
        Self.fillAndStrokeCapsule(
            brandRect,
            fill: CartoonAccent.sunnyMango.titleBarRGBA,
            stroke: CartoonRenderMetrics.ink,
            lineWidth: 1.8 * scale,
            context: context
        )
        Self.drawSingleLine(
            brandText,
            font: brandFont,
            color: CartoonRenderMetrics.ink,
            centeredIn: brandRect,
            context: context
        )

        // Active Window Indicator Pill
        if let activeID = scene.activeWindowID,
           let activeWin = visibleWindows.first(where: { $0.windowID == activeID }) {
            let activeLabel = "\(activeWin.title)  z:\(Int(activeWin.zIndex))"
            let activeFont = Self.roundedFont(size: 11.5 * scale, weight: .bold)
            let activeSize = Self.measureSingleLine(activeLabel, font: activeFont)
            let pillW = activeSize.width + 32.0 * scale
            let pillRect = CGRect(
                x: brandRect.maxX + 10.0 * scale,
                y: brandRect.minY,
                width: pillW,
                height: brandH
            )
            if pillRect.maxX < outputWidth - 180.0 * scale {
                Self.fillAndStrokeCapsule(
                    pillRect,
                    fill: CartoonRenderMetrics.white.withAlpha(0.82),
                    stroke: CartoonRenderMetrics.ink.withAlpha(0.32),
                    lineWidth: 1.3 * scale,
                    context: context
                )

                let dotD = 8.0 * scale
                let dotRect = CGRect(x: pillRect.minX + 10.0 * scale, y: pillRect.midY - dotD * 0.5, width: dotD, height: dotD)
                context.setFillColor(activeWin.accent.vibrantPopRGBA.cgColor)
                context.fillEllipse(in: dotRect)
                context.setStrokeColor(CartoonRenderMetrics.ink.cgColor)
                context.setLineWidth(1.2 * scale)
                context.strokeEllipse(in: dotRect)

                Self.drawSingleLine(
                    activeLabel,
                    font: activeFont,
                    color: CartoonRenderMetrics.ink,
                    leftAlignedIn: CGRect(x: dotRect.maxX + 6.0 * scale, y: pillRect.minY, width: activeSize.width + 6.0 * scale, height: pillRect.height),
                    context: context
                )
            }
        }

        // Right Wallpaper Title Pill
        let wallpaperTitle = (scene.wallpaper ?? .pastelSunrise).title
        let wpFont = Self.roundedFont(size: 10.5 * scale, weight: .bold)
        let wpSize = Self.measureSingleLine(wallpaperTitle, font: wpFont)
        let wpW = wpSize.width + 20.0 * scale
        let wpRect = CGRect(
            x: outputWidth - 14.0 * scale - wpW,
            y: brandRect.minY,
            width: wpW,
            height: brandH
        )
        if wpRect.minX > brandRect.maxX + 16.0 * scale {
            Self.fillAndStrokeCapsule(
                wpRect,
                fill: CartoonRenderMetrics.white.withAlpha(0.90),
                stroke: CartoonRenderMetrics.ink,
                lineWidth: 1.5 * scale,
                context: context
            )
            Self.drawSingleLine(wallpaperTitle, font: wpFont, color: CartoonRenderMetrics.ink, centeredIn: wpRect, context: context)
        }
    }

    // MARK: - CoreGraphics & CoreText Vector Drawing Primitives

    private static func drawCGImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let clampedR = max(0, min(radius, min(rect.width, rect.height) * 0.5))
        return CGPath(roundedRect: rect, cornerWidth: clampedR, cornerHeight: clampedR, transform: nil)
    }

    private static func fillAndStrokeRoundedRect(
        _ rect: CGRect,
        radius: CGFloat,
        fill: CartoonRGBA,
        stroke: CartoonRGBA,
        lineWidth: CGFloat,
        context: CGContext
    ) {
        let fillPath = roundedRectPath(rect, radius: radius)
        context.setFillColor(fill.cgColor)
        context.addPath(fillPath)
        context.fillPath()

        let inset = rect.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
        guard inset.width > 0, inset.height > 0 else { return }
        let strokePath = roundedRectPath(inset, radius: max(0, radius - lineWidth * 0.5))
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(strokePath)
        context.strokePath()
    }

    private static func fillAndStrokeCapsule(
        _ rect: CGRect,
        fill: CartoonRGBA,
        stroke: CartoonRGBA,
        lineWidth: CGFloat,
        context: CGContext
    ) {
        fillAndStrokeRoundedRect(
            rect,
            radius: min(rect.width, rect.height) * 0.5,
            fill: fill,
            stroke: stroke,
            lineWidth: lineWidth,
            context: context
        )
    }

    private static func aspectFitRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let factor = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * factor
        let h = imageSize.height * factor
        return CGRect(
            x: container.midX - w * 0.5,
            y: container.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    private static func aspectFillRect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let factor = max(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * factor
        let h = imageSize.height * factor
        return CGRect(
            x: container.midX - w * 0.5,
            y: container.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        let base = NSFont.systemFont(ofSize: max(6.0, size), weight: weight)
        if let roundedDesc = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: roundedDesc, size: max(6.0, size)) {
            return rounded as CTFont
        }
        return base as CTFont
    }

    private static func monospacedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: max(6.0, size), weight: weight) as CTFont
    }

    private static func measureSingleLine(_ text: String, font: CTFont) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        let attrString = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: ceil(width), height: ceil(ascent + descent))
    }

    private static func truncateMiddle(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard !text.isEmpty, maxWidth > 0 else { return "" }
        if measureSingleLine(text, font: font).width <= maxWidth {
            return text
        }
        let chars = Array(text)
        guard chars.count > 4 else { return text }

        var keepEachSide = max(1, chars.count / 2 - 1)
        while keepEachSide > 1 {
            let candidate = String(chars.prefix(keepEachSide)) + "…" + String(chars.suffix(keepEachSide))
            if measureSingleLine(candidate, font: font).width <= maxWidth {
                return candidate
            }
            keepEachSide -= 1
        }
        return String(chars.prefix(1)) + "…"
    }

    private static func drawSingleLine(
        _ text: String,
        font: CTFont,
        color: CartoonRGBA,
        centeredIn rect: CGRect,
        context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let x = rect.midX - width * 0.5
        let baselineY = rect.midY + (ascent - descent) * 0.5

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawSingleLine(
        _ text: String,
        font: CTFont,
        color: CartoonRGBA,
        leftAlignedIn rect: CGRect,
        context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let baselineY = rect.midY + (ascent - descent) * 0.5

        context.saveGState()
        context.clip(to: rect)
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        context.textPosition = CGPoint(x: rect.minX, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawAttributedSingleLine(
        _ attrString: CFAttributedString,
        in rect: CGRect,
        font: CTFont,
        context: CGContext
    ) {
        guard CFAttributedStringGetLength(attrString) > 0, rect.width > 1, rect.height > 1 else { return }
        let line = CTLineCreateWithAttributedString(attrString)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baselineY = rect.midY + (ascent - descent) * 0.5

        context.saveGState()
        context.clip(to: rect)
        context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        context.textPosition = CGPoint(x: rect.minX, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawWrappedText(
        _ text: String,
        font: CTFont,
        color: CartoonRGBA,
        in rect: CGRect,
        lineSpacing: CGFloat,
        context: CGContext
    ) -> CGFloat {
        guard !text.isEmpty, rect.width > 4, rect.height > 4 else { return 0 }

        var spacing = lineSpacing
        let paragraphSetting = withUnsafeBytes(of: &spacing) { rawPtr -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment,
                valueSize: MemoryLayout<CGFloat>.size,
                value: rawPtr.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
            kCTParagraphStyleAttributeName: paragraphSetting
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)

        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: rect.width, height: rect.height),
            nil
        )

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1.0, y: -1.0)
        context.textMatrix = .identity

        let localPath = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), localPath, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()

        return min(rect.height, ceil(suggested.height))
    }

    private static func syntaxHighlightedLine(_ line: String, font: CTFont) -> CFAttributedString {
        let mutable = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(mutable, CFRange(location: 0, length: 0), line as CFString)
        let fullRange = CFRange(location: 0, length: CFAttributedStringGetLength(mutable))
        guard fullRange.length > 0 else { return mutable }

        let baseColor = CartoonRGBA(red: 0.94, green: 0.95, blue: 0.98)
        CFAttributedStringSetAttribute(mutable, fullRange, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(mutable, fullRange, kCTForegroundColorAttributeName, baseColor.cgColor)

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") {
            let commentColor = CartoonRGBA(red: 0.52, green: 0.60, blue: 0.70)
            CFAttributedStringSetAttribute(mutable, fullRange, kCTForegroundColorAttributeName, commentColor.cgColor)
            return mutable
        }

        if trimmed.hasPrefix("@") {
            let attrColor = CartoonRGBA(red: 1.00, green: 0.78, blue: 0.38)
            CFAttributedStringSetAttribute(mutable, fullRange, kCTForegroundColorAttributeName, attrColor.cgColor)
            return mutable
        }

        let nsLine = line as NSString
        let keywords = ["import", "final", "class", "struct", "enum", "func", "var", "let", "return", "guard", "else", "if"]
        let keywordColor = CartoonRGBA(red: 0.62, green: 0.86, blue: 1.00).cgColor
        for kw in keywords {
            var searchRange = NSRange(location: 0, length: nsLine.length)
            while searchRange.location < nsLine.length {
                let found = nsLine.range(of: kw, options: [], range: searchRange)
                if found.location == NSNotFound { break }

                let beforeOK = found.location == 0 || !Self.isIdentifierUTF16(nsLine.character(at: found.location - 1))
                let afterIdx = found.location + found.length
                let afterOK = afterIdx >= nsLine.length || !Self.isIdentifierUTF16(nsLine.character(at: afterIdx))

                if beforeOK && afterOK {
                    CFAttributedStringSetAttribute(
                        mutable,
                        CFRange(location: found.location, length: found.length),
                        kCTForegroundColorAttributeName,
                        keywordColor
                    )
                }
                searchRange = NSRange(location: afterIdx, length: max(0, nsLine.length - afterIdx))
            }
        }

        let apiHighlights = ["withAnimation", "focusPoint", "DesktopWindow", "CGFloat", "CGPoint", "TimeInterval", "SwiftUI"]
        let mintColor = CartoonRGBA(red: 0.68, green: 0.96, blue: 0.78).cgColor
        for token in apiHighlights {
            let found = nsLine.range(of: token)
            if found.location != NSNotFound {
                CFAttributedStringSetAttribute(
                    mutable,
                    CFRange(location: found.location, length: found.length),
                    kCTForegroundColorAttributeName,
                    mintColor
                )
            }
        }

        return mutable
    }

    private static func isIdentifierUTF16(_ codeUnit: unichar) -> Bool {
        (codeUnit >= 48 && codeUnit <= 57)
            || (codeUnit >= 65 && codeUnit <= 90)
            || (codeUnit >= 97 && codeUnit <= 122)
            || codeUnit == 95
    }

    private static func glyphIndicator(for kind: WindowContent.Kind) -> String {
        switch kind {
        case .video: "▶"
        case .codeSnippet: "{}"
        case .browser: "◎"
        case .image: "▣"
        }
    }

    private static func formatMMSS(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
