//
//  CartoonWindowFrame.swift
//  OSVideoEditor
//
//  "Tasteful Cartoon" macOS window chrome featuring bold rounded outlines,
//  chunky pastel/vibrant title bar, squishy traffic light buttons, and subtle layered shadows.
//

import SwiftUI

struct CartoonWindowFrame<TitleDragGesture: Gesture, Content: View>: View {
    let title: String
    let systemImage: String
    let badgeText: String
    let accent: CartoonAccent
    let isFocused: Bool
    let isMaximized: Bool
    let isInteracting: Bool
    let titleBarDragGesture: TitleDragGesture
    let onFocus: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onToggleMaximize: () -> Void
    let onCycleAccent: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isTrafficClusterHovered = false

    private var windowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CartoonTheme.windowCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle()
                .fill(CartoonTheme.ink)
                .frame(height: 2.2)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CartoonTheme.surfacePaper)
        }
        .clipShape(windowShape)
        .overlay {
            // Cel-shaded top inner sheen + bold rounded cartoon outline
            windowShape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 4.5
                )
                .padding(1.5)
                .allowsHitTesting(false)
        }
        .overlay {
            windowShape
                .strokeBorder(CartoonTheme.ink, lineWidth: CartoonTheme.windowBorderWidth)
                .allowsHitTesting(false)
        }
        // Subtle comic offset shadow + soft ambient elevation shadow
        .shadow(
            color: CartoonTheme.ink.opacity(isFocused ? (isInteracting ? 0.30 : 0.22) : 0.12),
            radius: isFocused ? 1.5 : 0.8,
            x: 0,
            y: isFocused ? (isInteracting ? 7 : 5) : 3
        )
        .shadow(
            color: CartoonTheme.ink.opacity(isFocused ? 0.13 : 0.06),
            radius: isFocused ? (isInteracting ? 22 : 16) : 7,
            x: 0,
            y: isFocused ? 10 : 4
        )
        .scaleEffect(isInteracting ? 1.006 : 1.0)
        .animation(.spring(duration: 0.22, bounce: 0.25), value: isFocused)
        .animation(.spring(duration: 0.18, bounce: 0.20), value: isInteracting)
    }

    // MARK: - Chunky Cartoon Title Bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            // Playful squishy traffic light cluster (isolated from drag region for 100% crisp clicks)
            HStack(spacing: 8) {
                SquishyTrafficLightButton(
                    fill: CartoonTheme.trafficClose,
                    symbol: "xmark",
                    showActiveTint: isFocused || isTrafficClusterHovered,
                    showSymbol: isTrafficClusterHovered,
                    accessibilityLabel: "Close Window",
                    action: onClose
                )

                SquishyTrafficLightButton(
                    fill: CartoonTheme.trafficMinimize,
                    symbol: "minus",
                    showActiveTint: isFocused || isTrafficClusterHovered,
                    showSymbol: isTrafficClusterHovered,
                    accessibilityLabel: "Minimize Window",
                    action: onMinimize
                )

                SquishyTrafficLightButton(
                    fill: CartoonTheme.trafficZoom,
                    symbol: isMaximized
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    showActiveTint: isFocused || isTrafficClusterHovered,
                    showSymbol: isTrafficClusterHovered,
                    accessibilityLabel: isMaximized ? "Restore Window" : "Zoom Window",
                    action: onToggleMaximize
                )
            }
            .padding(.vertical, 6)
            .onHover { hovering in
                withAnimation(.spring(duration: 0.18, bounce: 0.3)) {
                    isTrafficClusterHovered = hovering
                }
            }

            // Draggable Title Region
            HStack(spacing: 8) {
                Spacer(minLength: 4)

                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.82))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
                        }

                    Text(title)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(CartoonTheme.ink.opacity(isFocused ? 1.0 : 0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(titleBarDragGesture)
            .onTapGesture(count: 2) {
                onToggleMaximize()
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    onFocus()
                }
            )

            // Trailing Cartoon Accent Swatch & Content Badge
            HStack(spacing: 6) {
                Button(action: onCycleAccent) {
                    Circle()
                        .fill(accent.vibrantPop)
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle()
                                .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
                        }
                }
                .buttonStyle(.plain)
                .help("Cycle window pastel theme")

                Text(badgeText)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.78))
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(CartoonTheme.ink, lineWidth: 1.6)
                    }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: CartoonTheme.titleBarHeight)
        .background(
            ZStack(alignment: .top) {
                (isFocused ? accent.titleBarFill : accent.titleBarInactiveFill)
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(height: 2)
            }
        )
    }
}

// MARK: - Playful Squishy Traffic Light Button

struct SquishyTrafficLightButton: View {
    let fill: Color
    let symbol: String
    let showActiveTint: Bool
    let showSymbol: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isButtonHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(showActiveTint ? fill : CartoonTheme.trafficInactive)

                // Cartoon specular highlight dot
                Ellipse()
                    .fill(Color.white.opacity(showActiveTint ? 0.65 : 0.35))
                    .frame(width: 5.5, height: 3.0)
                    .rotationEffect(.degrees(-28))
                    .offset(x: -2.6, y: -3.2)

                if showSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(CartoonTheme.ink)
                        .transition(.scale.combined(with: .opacity))
                }

                Circle()
                    .strokeBorder(CartoonTheme.ink, lineWidth: CartoonTheme.controlBorderWidth)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(SquishyCartoonButtonStyle(isHovered: isButtonHovered))
        .onHover { hovering in
            withAnimation(.spring(duration: 0.2, bounce: 0.45)) {
                isButtonHovered = hovering
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SquishyCartoonButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Squash-and-stretch cartoon physics when pressed, bouncy pop when hovered
            .scaleEffect(
                x: configuration.isPressed ? 1.20 : (isHovered ? 1.13 : 1.0),
                y: configuration.isPressed ? 0.80 : (isHovered ? 1.13 : 1.0)
            )
            .offset(y: configuration.isPressed ? 1.0 : 0)
            .animation(.spring(duration: 0.22, bounce: 0.5), value: configuration.isPressed)
            .animation(.spring(duration: 0.20, bounce: 0.4), value: isHovered)
    }
}
