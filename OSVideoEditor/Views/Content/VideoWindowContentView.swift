//
//  VideoWindowContentView.swift
//  OSVideoEditor
//
//  Interactive cartoon video player stage inside a ScreenPlay OS window.
//

import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct VideoWindowContentView: View {
    let payload: VideoWindowPayload
    let accent: CartoonAccent
    let onMutate: ((inout VideoWindowPayload) -> Void) -> Void

    @State private var pulsePhase = false

    private let playbackTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            // Cartoon Video Stage Viewport
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(stageGradient)

                    cartoonStageArtwork(in: proxy.size)

                    // Top HUD badges inside video frame
                    VStack {
                        HStack {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(CartoonTheme.trafficClose)
                                    .frame(width: 7, height: 7)
                                    .scaleEffect(payload.isPlaying && pulsePhase ? 1.25 : 0.9)
                                Text(payload.isPlaying ? "PLAYING" : "PAUSED")
                                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(CartoonTheme.ink.opacity(0.84)))

                            Spacer()

                            Button {
                                onMutate { video in
                                    video.isMuted.toggle()
                                }
                            } label: {
                                Image(systemName: payload.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 9.5, weight: .black))
                                    .foregroundStyle(CartoonTheme.ink)
                                    .frame(width: 24, height: 22)
                                    .background(Capsule().fill(payload.isMuted ? CartoonTheme.trafficClose.opacity(0.85) : Color.white.opacity(0.88)))
                                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(payload.isMuted ? "Unmute clip audio in export mix" : "Mute clip audio in export mix")

                            Button(action: pickVideoAssetFile) {
                                HStack(spacing: 3.5) {
                                    Image(systemName: payload.assetURL != nil ? "checkmark.circle.fill" : "folder.fill")
                                        .font(.system(size: 9.5, weight: .bold))
                                    Text(payload.assetURL != nil ? "Asset" : "Load")
                                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                }
                                .foregroundStyle(CartoonTheme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(payload.assetURL != nil ? CartoonAccent.mintMatcha.titleBarFill : Color.white.opacity(0.88)))
                                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help("Attach local MP4 / MOV video file for synchronized export")

                            Button {
                                onMutate { video in
                                    let all = CartoonVideoScene.allCases
                                    if let idx = all.firstIndex(of: video.scene) {
                                        video.scene = all[(idx + 1) % all.count]
                                    }
                                }
                            } label: {
                                Text("\(payload.resolutionTag) • \(payload.fps)fps")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(CartoonTheme.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.88)))
                                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help("Switch cartoon scene preset")
                        }
                        Spacer()
                    }
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CartoonTheme.ink, lineWidth: 2)
                }
            }

            // Cartoon Transport & Scrub Bar
            HStack(spacing: 10) {
                Button {
                    onMutate { video in
                        video.isPlaying.toggle()
                        if video.isPlaying && video.currentSeconds >= video.durationSeconds {
                            video.currentSeconds = 0
                        }
                    }
                } label: {
                    Image(systemName: payload.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)
                        .frame(width: 30, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(accent.titleBarFill)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
                        }
                }
                .buttonStyle(.plain)

                // Interactive Scrubbable Progress Bar
                GeometryReader { barGeo in
                    let barWidth = max(1, barGeo.size.width)
                    let filledWidth = max(12, barWidth * payload.progress)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(CartoonTheme.surfaceSecondary)
                            .frame(height: 12)
                            .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))

                        Capsule()
                            .fill(accent.vibrantPop)
                            .frame(width: min(barWidth, filledWidth), height: 12)
                            .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.8))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let ratio = min(max(drag.location.x / barWidth, 0), 1)
                                onMutate { video in
                                    video.currentSeconds = ratio * video.durationSeconds
                                }
                            }
                    )
                }
                .frame(height: 24)

                Text("\(formatTime(payload.currentSeconds)) / \(formatTime(payload.durationSeconds))")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .fixedSize()
            }
        }
        .padding(12)
        .onReceive(playbackTicker) { _ in
            guard payload.isPlaying else { return }
            pulsePhase.toggle()
            onMutate { video in
                let next = video.currentSeconds + 0.1
                if next >= video.durationSeconds {
                    video.currentSeconds = 0
                } else {
                    video.currentSeconds = next
                }
            }
        }
    }

    private var stageGradient: LinearGradient {
        switch payload.scene {
        case .rocketLaunch:
            LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.21, blue: 0.36),
                    Color(red: 0.33, green: 0.28, blue: 0.56)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .synthStudio:
            LinearGradient(
                colors: [
                    Color(red: 0.15, green: 0.34, blue: 0.36),
                    Color(red: 0.22, green: 0.52, blue: 0.49)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .mascotWave:
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.78, blue: 0.58),
                    Color(red: 0.96, green: 0.56, blue: 0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func cartoonStageArtwork(in size: CGSize) -> some View {
        let bounceOffset = CGFloat(sin(payload.currentSeconds * 3.2) * 7.0)
        let compactScale = min(1.0, min(size.width / 340, size.height / 180))

        ZStack {
            // Decorative floating clouds / stars
            Circle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 90, height: 90)
                .offset(x: -size.width * 0.26, y: 18)

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 64, height: 64)
                .offset(x: size.width * 0.28, y: -14)

            // Center Cartoon Badge Character / Prop
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.92, blue: 0.68))
                        .frame(width: 84, height: 68)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(CartoonTheme.ink, lineWidth: 2.5)
                        }
                        .shadow(color: CartoonTheme.ink.opacity(0.35), radius: 0, x: 0, y: 4)

                    Image(systemName: sceneSymbol)
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)
                }
                .offset(y: bounceOffset)

                Text(payload.clipTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(CartoonTheme.ink.opacity(0.65)))
            }
            .scaleEffect(max(0.72, compactScale))
        }
    }

    private var sceneSymbol: String {
        switch payload.scene {
        case .rocketLaunch: "sparkles.tv.fill"
        case .synthStudio: "waveform.badge.magnifyingglass"
        case .mascotWave: "face.smiling.inverse"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func pickVideoAssetFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        Task {
            let scoped = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { selectedURL.stopAccessingSecurityScopedResource() }
            }
            let asset = AVURLAsset(url: selectedURL)
            let loadedDuration = (try? await asset.load(.duration).seconds) ?? 10.0
            let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
            let naturalSize = (try? await videoTrack?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let nominalFPS = (try? await videoTrack?.load(.nominalFrameRate)) ?? 60.0

            onMutate { video in
                video.assetURL = selectedURL
                video.clipTitle = selectedURL.lastPathComponent
                video.durationSeconds = max(0.2, loadedDuration.isFinite ? loadedDuration : 10.0)
                video.currentSeconds = 0.0
                video.mediaStartOffset = 0.0
                video.fps = max(1, Int(nominalFPS.rounded()))
                video.resolutionTag = "\(Int(abs(naturalSize.width)))×\(Int(abs(naturalSize.height)))"
            }
        }
    }
}
