//
//  DesktopCanvasView.swift
//  OSVideoEditor
//
//  High-performance virtual desktop canvas powered by a custom SwiftUI `Layout`
//  for exact top-leading window placement, native hit-testing, and dynamic z-index stacking.
//

import SwiftUI

enum DesktopCanvasCoordinateSpace {
    static let name = "ScreenPlayDesktopCanvasSpace"
}

// MARK: - Custom Layout Value Key for Direct Window Placement

nonisolated private struct WindowCanvasRectKey: LayoutValueKey {
    static let defaultValue: CGRect = .zero
}

extension View {
    func desktopCanvasFrame(_ frame: WindowFrame) -> some View {
        layoutValue(key: WindowCanvasRectKey.self, value: frame.rect)
    }
}

/// Places each desktop window directly at its `(origin.x, origin.y)` with exact `(width, height)`
/// without full-screen `.position` wrappers or `.offset` tracking-area drift.
nonisolated struct DesktopCanvasLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1280, height: 760))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            let rect = subview[WindowCanvasRectKey.self]
            let targetPoint = CGPoint(
                x: bounds.minX + rect.minX,
                y: bounds.minY + rect.minY
            )
            subview.place(
                at: targetPoint,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: rect.width, height: rect.height)
            )
        }
    }
}

// MARK: - Interactive Desktop Canvas View

struct DesktopCanvasView: View {
    @Bindable var canvasState: CanvasState

    var body: some View {
        ZStack(alignment: .topLeading) {
            CartoonDesktopWallpaperView(wallpaper: canvasState.wallpaper)

            // Virtual Desktop Window Layer
            DesktopCanvasLayout {
                ForEach(canvasState.visibleWindows) { window in
                    DesktopWindowContainerView(
                        window: window,
                        canvasState: canvasState
                    )
                    .desktopCanvasFrame(window.frame)
                    .zIndex(window.zIndex)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.90).combined(with: .opacity),
                            removal: .scale(scale: 0.88).combined(with: .opacity)
                        )
                    )
                }
            }
            .coordinateSpace(.named(DesktopCanvasCoordinateSpace.name))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            if newSize.width > 0 && newSize.height > 0 {
                canvasState.canvasBounds = newSize
            }
        }
    }
}

// MARK: - Stylized Cartoon Desktop Wallpaper

struct CartoonDesktopWallpaperView: View {
    let wallpaper: CartoonWallpaper

    var body: some View {
        ZStack {
            LinearGradient(
                colors: wallpaper.gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle ambient pastel blobs for cartoon depth
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.32))
                        .frame(width: 360, height: 360)
                        .blur(radius: 36)
                        .offset(x: -geo.size.width * 0.25, y: -geo.size.height * 0.18)

                    Circle()
                        .fill(Color.white.opacity(0.26))
                        .frame(width: 300, height: 300)
                        .blur(radius: 32)
                        .offset(x: geo.size.width * 0.28, y: geo.size.height * 0.22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Crisp comic dot-grid pattern drawn via single GPU Canvas pass
            Canvas { context, size in
                let spacing: CGFloat = 26
                let dotRadius: CGFloat = 1.35
                let dotColor = CartoonTheme.ink.opacity(0.11)

                var y: CGFloat = spacing * 0.75
                while y < size.height {
                    var x: CGFloat = spacing * 0.75
                    while x < size.width {
                        let dotRect = CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        )
                        context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                        x += spacing
                    }
                    y += spacing
                }
            }
        }
        .allowsHitTesting(false)
    }
}
