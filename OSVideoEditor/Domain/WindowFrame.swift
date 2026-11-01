//
//  WindowFrame.swift
//  OSVideoEditor
//
//  Pure value-type window geometry and zero-drift corner resize mathematics.
//

import CoreGraphics
import Foundation

/// Interactive corner anchors supported by ScreenPlay OS desktop windows.
nonisolated enum ResizeCorner: String, CaseIterable, Codable, Sendable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .topLeading: "TL"
        case .topTrailing: "TR"
        case .bottomLeading: "BL"
        case .bottomTrailing: "BR"
        }
    }
}

/// Geometry model representing a window's position and dimensions in canvas coordinates.
nonisolated struct WindowFrame: Equatable, Codable, Sendable {
    var origin: CGPoint
    var size: CGSize

    static let defaultMinimumSize = CGSize(width: 280, height: 200)

    init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    // MARK: - Computed Geometry

    var rect: CGRect {
        CGRect(origin: origin, size: size)
    }

    var minX: CGFloat { origin.x }
    var minY: CGFloat { origin.y }
    var maxX: CGFloat { origin.x + size.width }
    var maxY: CGFloat { origin.y + size.height }
    var midX: CGFloat { origin.x + size.width * 0.5 }
    var midY: CGFloat { origin.y + size.height * 0.5 }
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    // MARK: - Pure Transformations

    /// Computes a translated frame from an initial gesture anchor frame, keeping the title bar accessible inside `canvasSize`.
    func applyingTranslation(
        _ translation: CGSize,
        constrainedTo canvasSize: CGSize? = nil,
        topSafeInset: CGFloat = 36
    ) -> WindowFrame {
        var nextX = origin.x + translation.width
        var nextY = origin.y + translation.height

        if let bounds = canvasSize, bounds.width > 0, bounds.height > 0 {
            let minVisibleWidth: CGFloat = min(96, size.width * 0.5)
            let bottomTitleBarMargin: CGFloat = 56
            nextX = min(max(nextX, -size.width + minVisibleWidth), bounds.width - minVisibleWidth)
            nextY = min(max(nextY, topSafeInset), max(topSafeInset, bounds.height - bottomTitleBarMargin))
        }

        return WindowFrame(
            origin: CGPoint(x: nextX.pixelAligned, y: nextY.pixelAligned),
            size: size
        )
    }

    /// Computes a resized frame from an initial gesture anchor frame while strictly pinning the opposite edges
    /// so clamping to `minimumSize` never causes position drift.
    func applyingResize(
        corner: ResizeCorner,
        translation: CGSize,
        minimumSize: CGSize = WindowFrame.defaultMinimumSize,
        constrainedTo canvasSize: CGSize? = nil,
        topSafeInset: CGFloat = 36
    ) -> WindowFrame {
        let minW = max(180, minimumSize.width)
        let minH = max(140, minimumSize.height)
        let topLimit: CGFloat = (canvasSize != nil) ? topSafeInset : -.greatestFiniteMagnitude

        var nextX = origin.x
        var nextY = origin.y
        var nextW = size.width
        var nextH = size.height

        switch corner {
        case .topLeading:
            let pinnedRight = maxX
            let pinnedBottom = maxY

            nextW = max(minW, size.width - translation.width)
            nextX = pinnedRight - nextW

            let unclampedTop = min(pinnedBottom - minH, origin.y + translation.height)
            let effectiveTopLimit = min(topLimit, pinnedBottom - minH)
            nextY = max(effectiveTopLimit, unclampedTop)
            nextH = pinnedBottom - nextY

        case .topTrailing:
            let pinnedBottom = maxY

            nextW = max(minW, size.width + translation.width)

            let unclampedTop = min(pinnedBottom - minH, origin.y + translation.height)
            let effectiveTopLimit = min(topLimit, pinnedBottom - minH)
            nextY = max(effectiveTopLimit, unclampedTop)
            nextH = pinnedBottom - nextY

        case .bottomLeading:
            let pinnedRight = maxX

            nextW = max(minW, size.width - translation.width)
            nextX = pinnedRight - nextW
            nextH = max(minH, size.height + translation.height)

        case .bottomTrailing:
            nextW = max(minW, size.width + translation.width)
            nextH = max(minH, size.height + translation.height)
        }

        return WindowFrame(
            origin: CGPoint(x: nextX.pixelAligned, y: nextY.pixelAligned),
            size: CGSize(width: nextW.pixelAligned, height: nextH.pixelAligned)
        )
    }
}

private extension CGFloat {
    nonisolated var pixelAligned: CGFloat {
        (self * 2.0).rounded() / 2.0
    }
}
