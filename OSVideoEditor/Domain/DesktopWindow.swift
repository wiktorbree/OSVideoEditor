//
//  DesktopWindow.swift
//  OSVideoEditor
//
//  Observable domain model representing an individual virtual window on the ScreenPlay OS desktop.
//

import CoreGraphics
import Foundation
import Observation

@Observable
final class DesktopWindow: Identifiable {
    let id: UUID
    var title: String
    var frame: WindowFrame
    var content: WindowContent
    var zIndex: Double
    var accent: CartoonAccent
    var isMinimized: Bool
    var isMaximized: Bool
    var restoreFrame: WindowFrame?
    var minimumSize: CGSize

    init(
        id: UUID = UUID(),
        title: String,
        frame: WindowFrame,
        content: WindowContent,
        zIndex: Double,
        accent: CartoonAccent,
        isMinimized: Bool = false,
        isMaximized: Bool = false,
        minimumSize: CGSize? = nil
    ) {
        self.id = id
        self.title = title
        self.frame = frame
        self.content = content
        self.zIndex = zIndex
        self.accent = accent
        self.isMinimized = isMinimized
        self.isMaximized = isMaximized
        self.restoreFrame = nil
        self.minimumSize = minimumSize ?? content.recommendedMinimumSize
    }

    var presentationState: WindowPresentationState {
        if isMinimized { return .minimized }
        if isMaximized { return .maximized }
        return .normal
    }

    var snapshot: WindowKeyframeSnapshot {
        WindowKeyframeSnapshot(
            windowID: id,
            title: title,
            contentKind: content.kind,
            frame: frame,
            zIndex: zIndex,
            presentationState: presentationState,
            accent: accent
        )
    }
}
