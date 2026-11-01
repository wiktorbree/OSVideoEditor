//
//  DesktopWindowContainerView.swift
//  OSVideoEditor
//
//  Interactive container binding a `DesktopWindow` to `CartoonWindowFrame`,
//  stationary-space drag gestures, 4-corner glitch-free resize handles, and z-index focus.
//

import SwiftUI

struct DesktopWindowContainerView: View {
    let window: DesktopWindow
    let canvasState: CanvasState

    @State private var dragAnchorFrame: WindowFrame?
    @State private var resizeAnchorFrame: WindowFrame?
    @State private var activeResizeCorner: ResizeCorner?
    @State private var isWindowHovered = false

    private var isFocused: Bool {
        canvasState.activeWindowID == window.id
    }

    private var isInteracting: Bool {
        dragAnchorFrame != nil || activeResizeCorner != nil
    }

    var body: some View {
        CartoonWindowFrame(
            title: window.title,
            systemImage: window.content.systemImage,
            badgeText: window.content.badgeLabel,
            accent: window.accent,
            isFocused: isFocused,
            isMaximized: window.isMaximized,
            isInteracting: isInteracting,
            titleBarDragGesture: windowMoveGesture,
            onFocus: {
                canvasState.bringToFront(window.id)
            },
            onClose: {
                canvasState.closeWindow(window.id)
            },
            onMinimize: {
                canvasState.toggleMinimize(window.id)
            },
            onToggleMaximize: {
                canvasState.toggleMaximize(window.id)
            },
            onCycleAccent: {
                canvasState.bringToFront(window.id)
                let allAccents = CartoonAccent.allCases
                if let currentIndex = allAccents.firstIndex(of: window.accent) {
                    withAnimation(.spring(duration: 0.25)) {
                        window.accent = allAccents[(currentIndex + 1) % allAccents.count]
                    }
                }
            }
        ) {
            windowBodyContent
                .simultaneousGesture(
                    TapGesture().onEnded {
                        canvasState.bringToFront(window.id)
                    }
                )
        }
        .overlay {
            cornerResizeHandlesOverlay
        }
        .overlay(alignment: .bottom) {
            if activeResizeCorner != nil {
                liveResizeDimensionPill
                    .padding(.bottom, 10)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            isWindowHovered = hovering
        }
    }

    // MARK: - Polymorphic Window Content

    @ViewBuilder
    private var windowBodyContent: some View {
        switch window.content {
        case let .video(videoPayload):
            VideoWindowContentView(
                payload: videoPayload,
                accent: window.accent
            ) { mutateVideo in
                canvasState.bringToFront(window.id)
                canvasState.updateContent(for: window.id) { content in
                    if case var .video(current) = content {
                        mutateVideo(&current)
                        content = .video(current)
                    }
                }
            }

        case let .codeSnippet(codePayload):
            CodeSnippetWindowContentView(
                payload: codePayload,
                accent: window.accent
            ) { mutateCode in
                canvasState.bringToFront(window.id)
                canvasState.updateContent(for: window.id) { content in
                    if case var .codeSnippet(current) = content {
                        mutateCode(&current)
                        content = .codeSnippet(current)
                    }
                }
            }

        case let .browser(browserPayload):
            BrowserWindowContentView(
                payload: browserPayload,
                accent: window.accent
            ) { mutateBrowser in
                canvasState.bringToFront(window.id)
                canvasState.updateContent(for: window.id) { content in
                    if case var .browser(current) = content {
                        mutateBrowser(&current)
                        content = .browser(current)
                    }
                }
            }

        case let .image(imagePayload):
            ImageWindowContentView(
                payload: imagePayload,
                accent: window.accent
            ) { mutateImage in
                canvasState.bringToFront(window.id)
                canvasState.updateContent(for: window.id) { content in
                    if case var .image(current) = content {
                        mutateImage(&current)
                        content = .image(current)
                    }
                }
            }
        }
    }

    // MARK: - Low-Latency Stationary-Space Window Drag Gesture

    private var windowMoveGesture: some Gesture {
        DragGesture(
            minimumDistance: 1.5,
            coordinateSpace: .named(DesktopCanvasCoordinateSpace.name)
        )
        .onChanged { value in
            if dragAnchorFrame == nil {
                let initialFrame = window.frame
                dragAnchorFrame = initialFrame
                canvasState.bringToFront(window.id)
                canvasState.recordMove(
                    windowID: window.id,
                    startFrame: initialFrame,
                    translation: .zero,
                    phase: .began
                )
            }

            guard let startFrame = dragAnchorFrame else { return }
            canvasState.recordMove(
                windowID: window.id,
                startFrame: startFrame,
                translation: value.translation,
                phase: .changed
            )
        }
        .onEnded { value in
            guard let startFrame = dragAnchorFrame else { return }
            canvasState.recordMove(
                windowID: window.id,
                startFrame: startFrame,
                translation: value.translation,
                phase: .ended
            )
            dragAnchorFrame = nil
        }
    }

    // MARK: - 4-Corner Interactive Resize Handles

    private var cornerResizeHandlesOverlay: some View {
        ZStack {
            cornerHandle(for: .topLeading, alignment: .topLeading)
            cornerHandle(for: .topTrailing, alignment: .topTrailing)
            cornerHandle(for: .bottomLeading, alignment: .bottomLeading)
            cornerHandle(for: .bottomTrailing, alignment: .bottomTrailing)
        }
    }

    private func cornerHandle(for corner: ResizeCorner, alignment: Alignment) -> some View {
        CornerResizeHandleView(
            corner: corner,
            accent: window.accent,
            isParentHoveredOrFocused: isWindowHovered || isFocused,
            isActivelyResizing: activeResizeCorner == corner
        )
        .gesture(cornerResizeGesture(for: corner))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func cornerResizeGesture(for corner: ResizeCorner) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(DesktopCanvasCoordinateSpace.name)
        )
        .onChanged { value in
            if resizeAnchorFrame == nil {
                let initialFrame = window.frame
                resizeAnchorFrame = initialFrame
                activeResizeCorner = corner
                canvasState.bringToFront(window.id)
                canvasState.recordResize(
                    windowID: window.id,
                    corner: corner,
                    startFrame: initialFrame,
                    translation: .zero,
                    phase: .began
                )
            }

            guard let startFrame = resizeAnchorFrame else { return }
            canvasState.recordResize(
                windowID: window.id,
                corner: corner,
                startFrame: startFrame,
                translation: value.translation,
                phase: .changed
            )
        }
        .onEnded { value in
            guard let startFrame = resizeAnchorFrame else { return }
            canvasState.recordResize(
                windowID: window.id,
                corner: corner,
                startFrame: startFrame,
                translation: value.translation,
                phase: .ended
            )
            resizeAnchorFrame = nil
            activeResizeCorner = nil
        }
    }

    private var liveResizeDimensionPill: some View {
        Text("\(Int(window.frame.size.width)) × \(Int(window.frame.size.height))")
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(CartoonTheme.ink.opacity(0.90))
            )
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Cartoon Corner Resize Handle View

private struct CornerResizeHandleView: View {
    let corner: ResizeCorner
    let accent: CartoonAccent
    let isParentHoveredOrFocused: Bool
    let isActivelyResizing: Bool

    @State private var isCornerHovered = false

    private var showGripIndicator: Bool {
        isActivelyResizing || isCornerHovered || (corner == .bottomTrailing && isParentHoveredOrFocused)
    }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())

            CornerBracketArcShape(corner: corner)
                .stroke(
                    (isActivelyResizing || isCornerHovered) ? accent.vibrantPop : CartoonTheme.ink.opacity(0.45),
                    style: StrokeStyle(
                        lineWidth: (isActivelyResizing || isCornerHovered) ? 3.5 : 2.4,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: 14, height: 14)
                .padding(4)
                .opacity(showGripIndicator ? 1.0 : 0.0)
                .scaleEffect((isActivelyResizing || isCornerHovered) ? 1.12 : 1.0)
                .animation(.spring(duration: 0.16, bounce: 0.3), value: showGripIndicator)
                .animation(.spring(duration: 0.16, bounce: 0.3), value: isCornerHovered)
        }
        .offset(x: cornerOutset.width, y: cornerOutset.height)
        .pointerStyle(.frameResize(position: frameResizePosition))
        .onHover { hovering in
            isCornerHovered = hovering
        }
    }

    private var cornerOutset: CGSize {
        let delta: CGFloat = 3
        return switch corner {
        case .topLeading: CGSize(width: -delta, height: -delta)
        case .topTrailing: CGSize(width: delta, height: -delta)
        case .bottomLeading: CGSize(width: -delta, height: delta)
        case .bottomTrailing: CGSize(width: delta, height: delta)
        }
    }

    private var frameResizePosition: FrameResizePosition {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/// Draws a rounded corner bracket hugging the window's curved corner.
private struct CornerBracketArcShape: Shape {
    let corner: ResizeCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 6

        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + r, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        case .topTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + r),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + r, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        return path
    }
}
