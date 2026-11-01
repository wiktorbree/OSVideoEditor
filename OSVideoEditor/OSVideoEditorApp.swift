//
//  OSVideoEditorApp.swift
//  OSVideoEditor
//
//  ScreenPlay OS — Cartoon-styled virtual desktop video editor prototype.
//

import SwiftUI

@main
struct OSVideoEditorApp: App {
    var body: some Scene {
        WindowGroup("ScreenPlay OS") {
            ContentView()
        }
        .defaultSize(width: 1360, height: 880)
        .windowResizability(.contentMinSize)
    }
}
