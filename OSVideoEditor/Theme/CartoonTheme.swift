//
//  CartoonTheme.swift
//  OSVideoEditor
//
//  Design tokens, pastel/vibrant accents, and desktop wallpapers for ScreenPlay OS.
//

import CoreGraphics
import SwiftUI

/// Thread-safe sRGB color representation shared between SwiftUI `@MainActor` views and background CoreGraphics frame renderers.
nonisolated struct CartoonRGBA: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    func withAlpha(_ newAlpha: CGFloat) -> CartoonRGBA {
        CartoonRGBA(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

nonisolated enum CartoonRenderMetrics {
    static let windowCornerRadius: CGFloat = 18
    static let windowBorderWidth: CGFloat = 2.5
    static let controlBorderWidth: CGFloat = 2.0
    static let titleBarHeight: CGFloat = 46
    static let virtualMenuBarHeight: CGFloat = 36

    static let ink = CartoonRGBA(red: 0.13, green: 0.13, blue: 0.18)
    static let inkSubtle = CartoonRGBA(red: 0.32, green: 0.33, blue: 0.41)
    static let surfacePaper = CartoonRGBA(red: 0.992, green: 0.988, blue: 0.976)
    static let surfaceSecondary = CartoonRGBA(red: 0.960, green: 0.952, blue: 0.934)
    static let codeBackground = CartoonRGBA(red: 0.125, green: 0.133, blue: 0.188)

    static let trafficClose = CartoonRGBA(red: 1.00, green: 0.42, blue: 0.46)
    static let trafficMinimize = CartoonRGBA(red: 1.00, green: 0.78, blue: 0.26)
    static let trafficZoom = CartoonRGBA(red: 0.28, green: 0.85, blue: 0.56)
    static let trafficInactive = CartoonRGBA(red: 0.84, green: 0.83, blue: 0.81)
    static let white = CartoonRGBA(red: 1.0, green: 1.0, blue: 1.0)
}

enum CartoonTheme {
    // MARK: - Core Ink & Surfaces

    /// Warm charcoal comic ink used for outlines, typography, and hard offset shadows.
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.18)
    static let inkSubtle = Color(red: 0.32, green: 0.33, blue: 0.41)
    static let surfacePaper = Color(red: 0.992, green: 0.988, blue: 0.976)
    static let surfaceSecondary = Color(red: 0.960, green: 0.952, blue: 0.934)
    static let codeBackground = Color(red: 0.125, green: 0.133, blue: 0.188)

    // MARK: - Traffic Light Palette

    static let trafficClose = Color(red: 1.00, green: 0.42, blue: 0.46)
    static let trafficMinimize = Color(red: 1.00, green: 0.78, blue: 0.26)
    static let trafficZoom = Color(red: 0.28, green: 0.85, blue: 0.56)
    static let trafficInactive = Color(red: 0.84, green: 0.83, blue: 0.81)

    // MARK: - Window Metrics

    static let windowCornerRadius: CGFloat = 18
    static let windowBorderWidth: CGFloat = 2.5
    static let controlBorderWidth: CGFloat = 2.0
    static let titleBarHeight: CGFloat = 46
    static let virtualMenuBarHeight: CGFloat = 36
}

// MARK: - Window Accent Palette

nonisolated enum CartoonAccent: String, CaseIterable, Codable, Sendable, Identifiable {
    case sunnyMango
    case mintMatcha
    case skyPeriwinkle
    case coralBlush
    case lavenderPop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunnyMango: "Sunny Mango"
        case .mintMatcha: "Mint Matcha"
        case .skyPeriwinkle: "Sky Periwinkle"
        case .coralBlush: "Coral Blush"
        case .lavenderPop: "Lavender Pop"
        }
    }

    var titleBarRGBA: CartoonRGBA {
        switch self {
        case .sunnyMango: CartoonRGBA(red: 1.00, green: 0.88, blue: 0.55)
        case .mintMatcha: CartoonRGBA(red: 0.72, green: 0.95, blue: 0.84)
        case .skyPeriwinkle: CartoonRGBA(red: 0.74, green: 0.88, blue: 1.00)
        case .coralBlush: CartoonRGBA(red: 1.00, green: 0.78, blue: 0.83)
        case .lavenderPop: CartoonRGBA(red: 0.88, green: 0.80, blue: 1.00)
        }
    }

    var titleBarInactiveRGBA: CartoonRGBA {
        switch self {
        case .sunnyMango: CartoonRGBA(red: 0.96, green: 0.92, blue: 0.80)
        case .mintMatcha: CartoonRGBA(red: 0.86, green: 0.94, blue: 0.90)
        case .skyPeriwinkle: CartoonRGBA(red: 0.87, green: 0.92, blue: 0.97)
        case .coralBlush: CartoonRGBA(red: 0.96, green: 0.89, blue: 0.91)
        case .lavenderPop: CartoonRGBA(red: 0.92, green: 0.89, blue: 0.96)
        }
    }

    var vibrantPopRGBA: CartoonRGBA {
        switch self {
        case .sunnyMango: CartoonRGBA(red: 1.00, green: 0.68, blue: 0.14)
        case .mintMatcha: CartoonRGBA(red: 0.16, green: 0.78, blue: 0.60)
        case .skyPeriwinkle: CartoonRGBA(red: 0.27, green: 0.62, blue: 0.96)
        case .coralBlush: CartoonRGBA(red: 0.98, green: 0.42, blue: 0.55)
        case .lavenderPop: CartoonRGBA(red: 0.62, green: 0.40, blue: 0.94)
        }
    }

    var softTintRGBA: CartoonRGBA {
        switch self {
        case .sunnyMango: CartoonRGBA(red: 1.00, green: 0.96, blue: 0.86)
        case .mintMatcha: CartoonRGBA(red: 0.91, green: 0.99, blue: 0.95)
        case .skyPeriwinkle: CartoonRGBA(red: 0.92, green: 0.96, blue: 1.00)
        case .coralBlush: CartoonRGBA(red: 1.00, green: 0.93, blue: 0.95)
        case .lavenderPop: CartoonRGBA(red: 0.95, green: 0.92, blue: 1.00)
        }
    }
}

extension CartoonAccent {
    @MainActor
    var titleBarFill: Color {
        switch self {
        case .sunnyMango: Color(red: 1.00, green: 0.88, blue: 0.55)
        case .mintMatcha: Color(red: 0.72, green: 0.95, blue: 0.84)
        case .skyPeriwinkle: Color(red: 0.74, green: 0.88, blue: 1.00)
        case .coralBlush: Color(red: 1.00, green: 0.78, blue: 0.83)
        case .lavenderPop: Color(red: 0.88, green: 0.80, blue: 1.00)
        }
    }

    @MainActor
    var titleBarInactiveFill: Color {
        switch self {
        case .sunnyMango: Color(red: 0.96, green: 0.92, blue: 0.80)
        case .mintMatcha: Color(red: 0.86, green: 0.94, blue: 0.90)
        case .skyPeriwinkle: Color(red: 0.87, green: 0.92, blue: 0.97)
        case .coralBlush: Color(red: 0.96, green: 0.89, blue: 0.91)
        case .lavenderPop: Color(red: 0.92, green: 0.89, blue: 0.96)
        }
    }

    @MainActor
    var vibrantPop: Color {
        switch self {
        case .sunnyMango: Color(red: 1.00, green: 0.68, blue: 0.14)
        case .mintMatcha: Color(red: 0.16, green: 0.78, blue: 0.60)
        case .skyPeriwinkle: Color(red: 0.27, green: 0.62, blue: 0.96)
        case .coralBlush: Color(red: 0.98, green: 0.42, blue: 0.55)
        case .lavenderPop: Color(red: 0.62, green: 0.40, blue: 0.94)
        }
    }

    @MainActor
    var softTint: Color {
        switch self {
        case .sunnyMango: Color(red: 1.00, green: 0.96, blue: 0.86)
        case .mintMatcha: Color(red: 0.91, green: 0.99, blue: 0.95)
        case .skyPeriwinkle: Color(red: 0.92, green: 0.96, blue: 1.00)
        case .coralBlush: Color(red: 1.00, green: 0.93, blue: 0.95)
        case .lavenderPop: Color(red: 0.95, green: 0.92, blue: 1.00)
        }
    }
}

// MARK: - Virtual Desktop Wallpapers

nonisolated enum CartoonWallpaper: String, CaseIterable, Codable, Sendable, Identifiable {
    case pastelSunrise
    case mintStudio
    case periwinkleCloud
    case warmDraftingPaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pastelSunrise: "Sunrise Pop"
        case .mintStudio: "Mint Studio"
        case .periwinkleCloud: "Sky Cloud"
        case .warmDraftingPaper: "Cream Grid"
        }
    }

    var gradientRGBAColors: [CartoonRGBA] {
        switch self {
        case .pastelSunrise:
            [
                CartoonRGBA(red: 1.00, green: 0.91, blue: 0.82),
                CartoonRGBA(red: 0.99, green: 0.87, blue: 0.92),
                CartoonRGBA(red: 0.85, green: 0.91, blue: 1.00)
            ]
        case .mintStudio:
            [
                CartoonRGBA(red: 0.84, green: 0.97, blue: 0.90),
                CartoonRGBA(red: 0.93, green: 0.98, blue: 0.94),
                CartoonRGBA(red: 0.85, green: 0.93, blue: 0.99)
            ]
        case .periwinkleCloud:
            [
                CartoonRGBA(red: 0.82, green: 0.90, blue: 1.00),
                CartoonRGBA(red: 0.90, green: 0.87, blue: 1.00),
                CartoonRGBA(red: 0.98, green: 0.91, blue: 0.96)
            ]
        case .warmDraftingPaper:
            [
                CartoonRGBA(red: 0.97, green: 0.95, blue: 0.90),
                CartoonRGBA(red: 0.95, green: 0.93, blue: 0.87)
            ]
        }
    }
}

extension CartoonWallpaper {
    @MainActor
    var gradientColors: [Color] {
        switch self {
        case .pastelSunrise:
            [
                Color(red: 1.00, green: 0.91, blue: 0.82),
                Color(red: 0.99, green: 0.87, blue: 0.92),
                Color(red: 0.85, green: 0.91, blue: 1.00)
            ]
        case .mintStudio:
            [
                Color(red: 0.84, green: 0.97, blue: 0.90),
                Color(red: 0.93, green: 0.98, blue: 0.94),
                Color(red: 0.85, green: 0.93, blue: 0.99)
            ]
        case .periwinkleCloud:
            [
                Color(red: 0.82, green: 0.90, blue: 1.00),
                Color(red: 0.90, green: 0.87, blue: 1.00),
                Color(red: 0.98, green: 0.91, blue: 0.96)
            ]
        case .warmDraftingPaper:
            [
                Color(red: 0.97, green: 0.95, blue: 0.90),
                Color(red: 0.95, green: 0.93, blue: 0.87)
            ]
        }
    }
}
