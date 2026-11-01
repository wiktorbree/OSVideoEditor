//
//  CodeSnippetWindowContentView.swift
//  OSVideoEditor
//
//  Stylized cartoon code editor card with syntax tinting, line numbers, and interactive line focus.
//

import AppKit
import SwiftUI

struct CodeSnippetWindowContentView: View {
    let payload: CodeSnippetPayload
    let accent: CartoonAccent
    let onMutate: ((inout CodeSnippetPayload) -> Void) -> Void

    @State private var didCopyRecently = false

    private var codeLines: [String] {
        payload.sourceCode.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Code Tab Strip
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "swift")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.26))
                    Text(payload.fileName)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )

                Text(payload.language)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(CartoonTheme.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.titleBarFill))

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload.sourceCode, forType: .string)
                    withAnimation(.spring(duration: 0.25)) {
                        didCopyRecently = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.easeOut(duration: 0.2)) {
                            didCopyRecently = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopyRecently ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                        Text(didCopyRecently ? "Copied" : "Copy")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(didCopyRecently ? CartoonTheme.trafficZoom.opacity(0.35) : Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.22))

            // Code Listing Area
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(codeLines.enumerated()), id: \.offset) { index, line in
                        let lineNumber = index + 1
                        let isHighlighted = payload.highlightedLines.contains(lineNumber)

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(String(format: "%2d", lineNumber))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(
                                    isHighlighted
                                        ? accent.titleBarFill
                                        : Color.white.opacity(0.32)
                                )
                                .frame(width: 22, alignment: .trailing)

                            syntaxStyledText(for: line)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isHighlighted ? accent.vibrantPop.opacity(0.22) : Color.clear)
                        )
                        .overlay(alignment: .leading) {
                            if isHighlighted {
                                Capsule()
                                    .fill(accent.titleBarFill)
                                    .frame(width: 3)
                                    .padding(.vertical, 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onMutate { snippet in
                                if let existing = snippet.highlightedLines.firstIndex(of: lineNumber) {
                                    snippet.highlightedLines.remove(at: existing)
                                } else {
                                    snippet.highlightedLines.append(lineNumber)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(CartoonTheme.codeBackground)
    }

    private func syntaxStyledText(for line: String) -> Text {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") {
            return Text(line).foregroundColor(Color(red: 0.52, green: 0.60, blue: 0.70))
        }
        if trimmed.hasPrefix("@") {
            return Text(line).foregroundColor(Color(red: 1.00, green: 0.78, blue: 0.38))
        }
        if trimmed.hasPrefix("import ") || trimmed.hasPrefix("final class ") || trimmed.hasPrefix("func ") {
            return Text(line).foregroundColor(Color(red: 0.62, green: 0.86, blue: 1.00))
        }
        if trimmed.contains("withAnimation") || trimmed.contains("focusPoint") {
            return Text(line).foregroundColor(Color(red: 0.68, green: 0.96, blue: 0.78))
        }
        return Text(line).foregroundColor(Color(red: 0.94, green: 0.95, blue: 0.98))
    }
}
