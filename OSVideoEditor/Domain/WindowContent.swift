//
//  WindowContent.swift
//  OSVideoEditor
//
//  Domain content models for ScreenPlay OS windows (Video, Code Snippet, Browser, and Image Asset).
//

import CoreGraphics
import Foundation

nonisolated enum WindowContent: Equatable, Codable, Sendable {
    case video(VideoWindowPayload)
    case codeSnippet(CodeSnippetPayload)
    case browser(BrowserWindowPayload)
    case image(ImageWindowPayload)

    enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
        case video
        case codeSnippet
        case browser
        case image

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .video: "Video Stage"
            case .codeSnippet: "Code Snippet"
            case .browser: "Cartoon Browser"
            case .image: "Image Asset"
            }
        }

        var shortBadge: String {
            switch self {
            case .video: "VIDEO"
            case .codeSnippet: "CODE"
            case .browser: "WEB"
            case .image: "IMAGE"
            }
        }

        var systemImage: String {
            switch self {
            case .video: "film.stack.fill"
            case .codeSnippet: "curlybraces.square.fill"
            case .browser: "globe"
            case .image: "photo.on.rectangle.angled.fill"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .video: .video
        case .codeSnippet: .codeSnippet
        case .browser: .browser
        case .image: .image
        }
    }

    var systemImage: String { kind.systemImage }
    var badgeLabel: String { kind.shortBadge }

    var recommendedMinimumSize: CGSize {
        switch self {
        case .video:
            CGSize(width: 340, height: 250)
        case .codeSnippet:
            CGSize(width: 350, height: 230)
        case .browser:
            CGSize(width: 380, height: 270)
        case .image:
            CGSize(width: 300, height: 230)
        }
    }
}

// MARK: - Video Payload

nonisolated enum CartoonVideoScene: String, CaseIterable, Codable, Sendable {
    case rocketLaunch
    case synthStudio
    case mascotWave
}

nonisolated struct VideoWindowPayload: Equatable, Codable, Sendable {
    var clipTitle: String
    var resolutionTag: String
    var fps: Int
    var durationSeconds: Double
    var currentSeconds: Double
    var isPlaying: Bool
    var scene: CartoonVideoScene
    /// Optional local video file URL for real AVFoundation frame decoding & stereo audio mixing.
    var assetURL: URL?
    /// Media in-point trim offset (seconds) inside `assetURL` aligned to this window's timeline start.
    var mediaStartOffset: Double
    /// Linear audio mix gain (`0.0 ... 1.5`) used by `AudioMixEngine`.
    var volume: Float
    /// Mutes this video window's audio contribution during playback and export.
    var isMuted: Bool

    init(
        clipTitle: String,
        resolutionTag: String,
        fps: Int,
        durationSeconds: Double,
        currentSeconds: Double,
        isPlaying: Bool,
        scene: CartoonVideoScene,
        assetURL: URL? = nil,
        mediaStartOffset: Double = 0.0,
        volume: Float = 1.0,
        isMuted: Bool = false
    ) {
        self.clipTitle = clipTitle
        self.resolutionTag = resolutionTag
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.currentSeconds = currentSeconds
        self.isPlaying = isPlaying
        self.scene = scene
        self.assetURL = assetURL
        self.mediaStartOffset = max(0, mediaStartOffset)
        self.volume = min(max(volume, 0.0), 1.5)
        self.isMuted = isMuted
    }

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(currentSeconds / durationSeconds, 0), 1)
    }
}

// MARK: - Code Snippet Payload

nonisolated struct CodeSnippetPayload: Equatable, Codable, Sendable {
    var fileName: String
    var language: String
    var sourceCode: String
    var highlightedLines: [Int]
}

// MARK: - Browser Payload

nonisolated enum BrowserShowcaseTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case product
    case features
    case releaseNotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .product: "Overview"
        case .features: "Features"
        case .releaseNotes: "v1.0 Notes"
        }
    }
}

nonisolated struct BrowserWindowPayload: Equatable, Codable, Sendable {
    var urlString: String
    var pageTitle: String
    var heroHeadline: String
    var heroSubtitle: String
    var selectedTab: BrowserShowcaseTab
    /// Optional PNG/TIFF raster snapshot of a live DOM / WKWebView viewport for offscreen compositing.
    var snapshotImageData: Data?

    init(
        urlString: String,
        pageTitle: String,
        heroHeadline: String,
        heroSubtitle: String,
        selectedTab: BrowserShowcaseTab,
        snapshotImageData: Data? = nil
    ) {
        self.urlString = urlString
        self.pageTitle = pageTitle
        self.heroHeadline = heroHeadline
        self.heroSubtitle = heroSubtitle
        self.selectedTab = selectedTab
        self.snapshotImageData = snapshotImageData
    }
}

// MARK: - Image Asset Payload

nonisolated enum CartoonImagePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case storyboardPoster
    case appIconMockup
    case colorChartCard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .storyboardPoster: "Storyboard"
        case .appIconMockup: "App Icon"
        case .colorChartCard: "Color Chart"
        }
    }
}

nonisolated struct ImageWindowPayload: Equatable, Codable, Sendable {
    var assetName: String
    var caption: String
    var dimensionsTag: String
    var aspectFit: Bool
    var preset: CartoonImagePreset
    var imageURL: URL?
    var imageData: Data?

    init(
        assetName: String,
        caption: String,
        dimensionsTag: String = "2048 × 1536 PNG",
        aspectFit: Bool = true,
        preset: CartoonImagePreset = .storyboardPoster,
        imageURL: URL? = nil,
        imageData: Data? = nil
    ) {
        self.assetName = assetName
        self.caption = caption
        self.dimensionsTag = dimensionsTag
        self.aspectFit = aspectFit
        self.preset = preset
        self.imageURL = imageURL
        self.imageData = imageData
    }
}

// MARK: - Demo Content Presets

extension WindowContent {
    nonisolated static let demoVideo = WindowContent.video(
        VideoWindowPayload(
            clipTitle: "Product_Launch_Cut_01.mov",
            resolutionTag: "4K UHD",
            fps: 60,
            durationSeconds: 48.0,
            currentSeconds: 16.5,
            isPlaying: false,
            scene: .rocketLaunch
        )
    )

    nonisolated static let demoCodeSnippet = WindowContent.codeSnippet(
        CodeSnippetPayload(
            fileName: "SpringTimeline.swift",
            language: "Swift 6",
            sourceCode: """
            import SwiftUI

            @Observable
            final class SpringCameraRig {
                var zoom: CGFloat = 1.25
                var focusPoint: CGPoint = .zero

                func track(window: DesktopWindow, at time: TimeInterval) {
                    withAnimation(.spring(duration: 0.38, bounce: 0.24)) {
                        focusPoint = window.frame.center
                    }
                }
            }
            """,
            highlightedLines: [9, 10, 11]
        )
    )

    nonisolated static let demoBrowser = WindowContent.browser(
        BrowserWindowPayload(
            urlString: "https://screenplay.os/studio",
            pageTitle: "ScreenPlay OS — Playful Desktop Storytelling",
            heroHeadline: "Turn Desktop Demos into Cartoon Cinema",
            heroSubtitle: "Arrange snappy windows, choreograph camera zooms, and record every motion curve automatically.",
            selectedTab: .product
        )
    )

    nonisolated static let demoImage = WindowContent.image(
        ImageWindowPayload(
            assetName: "KeyArt_Hero_Board.png",
            caption: "Milestone 3 Compositor Key Art • sRGB",
            dimensionsTag: "2400 × 1600 PNG",
            aspectFit: true,
            preset: .storyboardPoster
        )
    )
}
