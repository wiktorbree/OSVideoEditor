//
//  BrowserWindowContentView.swift
//  OSVideoEditor
//
//  Stylized cartoon web browser window content with interactive URL pill, tabs, and responsive layout.
//

import SwiftUI

struct BrowserWindowContentView: View {
    let payload: BrowserWindowPayload
    let accent: CartoonAccent
    let onMutate: ((inout BrowserWindowPayload) -> Void) -> Void

    @State private var reloadRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            browserNavigationBar
            Rectangle()
                .fill(CartoonTheme.ink.opacity(0.18))
                .frame(height: 1.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    heroBanner
                    tabPickerRow
                    featureCardsSection
                }
                .padding(14)
            }
        }
        .background(CartoonTheme.surfacePaper)
    }

    // MARK: - Cartoon Address Bar

    private var browserNavigationBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                navIconPill(symbol: "chevron.left")
                navIconPill(symbol: "chevron.right")
            }

            // Rounded URL Address Pill
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CartoonTheme.trafficZoom)

                Text(payload.urlString)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.titleBarFill))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.white)
            )
            .overlay {
                Capsule()
                    .strokeBorder(CartoonTheme.ink, lineWidth: 1.7)
            }

            Button {
                withAnimation(.spring(duration: 0.45, bounce: 0.25)) {
                    reloadRotation += 360
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
                    .rotationEffect(.degrees(reloadRotation))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().strokeBorder(CartoonTheme.ink, lineWidth: 1.7))
            }
            .buttonStyle(.plain)
            .help("Reload showcase page")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CartoonTheme.surfaceSecondary)
    }

    private func navIconPill(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(CartoonTheme.inkSubtle)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.white.opacity(0.8)))
            .overlay(Circle().strokeBorder(CartoonTheme.ink.opacity(0.65), lineWidth: 1.5))
    }

    // MARK: - Responsive Cartoon Web Content

    private var heroBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SCREENPLAY STUDIO")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(CartoonTheme.ink, lineWidth: 1.5))

                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(CartoonTheme.ink)
            }

            Text(payload.heroHeadline)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(CartoonTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(payload.heroSubtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CartoonTheme.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.softTint)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 2)
        }
    }

    private var tabPickerRow: some View {
        HStack(spacing: 8) {
            ForEach(BrowserShowcaseTab.allCases) { tab in
                let isSelected = (payload.selectedTab == tab)
                Button {
                    onMutate { web in
                        web.selectedTab = tab
                    }
                } label: {
                    Text(tab.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? accent.titleBarFill : CartoonTheme.surfaceSecondary)
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var featureCardsSection: some View {
        switch payload.selectedTab {
        case .product:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    featureCard(icon: "cursorarrow.motionlines", title: "120Hz Drag", detail: "Zero-lag window choreography")
                    featureCard(icon: "waveform.path.ecg", title: "Auto Capture", detail: "Timestamped motion stream")
                }
                VStack(spacing: 8) {
                    featureCard(icon: "cursorarrow.motionlines", title: "120Hz Drag", detail: "Zero-lag window choreography")
                    featureCard(icon: "waveform.path.ecg", title: "Auto Capture", detail: "Timestamped motion stream")
                }
            }
        case .features:
            VStack(spacing: 8) {
                featureCard(icon: "square.stack.3d.up.fill", title: "Dynamic Z-Stacking", detail: "Click any window to smoothly pop it to the foreground.")
                featureCard(icon: "arrow.up.left.and.arrow.down.right", title: "Pinned Corner Resize", detail: "Opposite edges stay locked even when hitting minimum bounds.")
            }
        case .releaseNotes:
            featureCard(
                icon: "flag.checkered.2.crossed",
                title: "Milestone 1 Prototype Ready",
                detail: "Interactive cartoon canvas, squishy traffic lights, and live state-capture telemetry."
            )
        }
    }

    private func featureCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(CartoonTheme.ink)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.titleBarFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CartoonTheme.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(CartoonTheme.ink, lineWidth: 1.8)
        }
    }
}
