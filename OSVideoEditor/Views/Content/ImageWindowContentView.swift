//
//  ImageWindowContentView.swift
//  OSVideoEditor
//
//  Cartoon image asset viewer supporting on-disk/embedded raster graphics and studio illustration presets.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageWindowContentView: View {
    let payload: ImageWindowPayload
    let accent: CartoonAccent
    let onMutate: ((inout ImageWindowPayload) -> Void) -> Void

    private var loadedNSImage: NSImage? {
        if let data = payload.imageData, let img = NSImage(data: data) {
            return img
        }
        if let url = payload.imageURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CartoonTheme.surfaceSecondary)

                    if let nsImage = loadedNSImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: payload.aspectFit ? .fit : .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        presetArtwork(in: proxy.size)
                    }

                    // Top controls pill overlay
                    VStack {
                        HStack(spacing: 6) {
                            Text(payload.dimensionsTag)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CartoonTheme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(Color.white.opacity(0.90)))
                                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.4))

                            Spacer()

                            Button {
                                onMutate { image in
                                    image.aspectFit.toggle()
                                }
                            } label: {
                                Text(payload.aspectFit ? "FIT" : "FILL")
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .foregroundStyle(CartoonTheme.ink)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(accent.titleBarFill))
                                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.4))
                            }
                            .buttonStyle(.plain)

                            Button(action: pickImageFile) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 9.5, weight: .bold))
                                    Text("Load")
                                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                }
                                .foregroundStyle(CartoonTheme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(Color.white.opacity(0.92)))
                                .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.4))
                            }
                            .buttonStyle(.plain)
                            .help("Load PNG/JPEG raster asset")
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

            HStack(spacing: 8) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)

                Text(payload.caption)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .lineLimit(1)

                Spacer()

                if payload.imageURL == nil && payload.imageData == nil {
                    Button {
                        onMutate { image in
                            let all = CartoonImagePreset.allCases
                            if let idx = all.firstIndex(of: image.preset) {
                                image.preset = all[(idx + 1) % all.count]
                            }
                        }
                    } label: {
                        Text(payload.preset.label)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(CartoonTheme.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accent.softTint))
                            .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func presetArtwork(in size: CGSize) -> some View {
        ZStack {
            LinearGradient(
                colors: [accent.softTint, Color.white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: presetSymbol)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .frame(width: 78, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(accent.titleBarFill)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CartoonTheme.ink, lineWidth: 2.2)
                    }

                Text(payload.assetName)
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
            }
            .scaleEffect(min(1.0, min(size.width / 260, size.height / 150)))
        }
    }

    private var presetSymbol: String {
        switch payload.preset {
        case .storyboardPoster: "sparkles.rectangle.stack.fill"
        case .appIconMockup: "app.badge.checkmark.fill"
        case .colorChartCard: "swatchpalette.fill"
        }
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let scoped = selectedURL.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: selectedURL)
        let imageRep = data.flatMap { NSBitmapImageRep(data: $0) }
        if scoped { selectedURL.stopAccessingSecurityScopedResource() }

        onMutate { image in
            image.assetName = selectedURL.lastPathComponent
            image.caption = selectedURL.lastPathComponent
            image.imageURL = selectedURL
            image.imageData = data
            if let rep = imageRep {
                image.dimensionsTag = "\(rep.pixelsWide) × \(rep.pixelsHigh)"
            }
        }
    }
}
