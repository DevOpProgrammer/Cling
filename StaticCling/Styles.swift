//
//  Styles.swift
//  StaticCling
//
//  Created by Alin Panaitiu on 06.02.2025.
//

import Foundation
import Lowtech
import SwiftUI

struct TextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration
            .label
            .foregroundColor(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 8.0)
            .background(roundRect(2, stroke: borderColor ?? color, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover(perform: { hover in
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    hovering = hover
                }
            })
            .opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.6)
    }

    var color = Color.primary.opacity(0.8)
    var borderColor: Color?

    @State private var hovering = false
}

struct BorderlessTextButton: ButtonStyle {
    @Environment(\.isEnabled) public var isEnabled

    public func makeBody(configuration: Configuration) -> some View {
        configuration
            .label
            .foregroundColor(color)
            .padding(.vertical, 2.0)
            .padding(.horizontal, 4.0)
            .contentShape(Rectangle())
            .onHover(perform: { hover in
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    hovering = hover
                }
            })
            .opacity(isEnabled ? (hovering ? 1 : 0.8) : 0.6)
    }

    var color = Color.primary.opacity(0.8)

    @State private var hovering = false
}

extension View {
    /// Adds a double click handler this view (macOS only)
    ///
    /// Example
    /// ```
    /// Text("Hello")
    ///     .onDoubleClick { print("Double click detected") }
    /// ```
    /// - Parameters:
    ///   - handler: Block invoked when a double click is detected
    func onDoubleClick(handler: @escaping () -> Void) -> some View {
        modifier(DoubleClickHandler(handler: handler))
    }
}

struct DoubleClickHandler: ViewModifier {
    let handler: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            DoubleClickListeningViewRepresentable(handler: handler)
        }
    }
}

struct DoubleClickListeningViewRepresentable: NSViewRepresentable {
    let handler: () -> Void

    func makeNSView(context: Context) -> DoubleClickListeningView {
        DoubleClickListeningView(handler: handler)
    }
    func updateNSView(_ nsView: DoubleClickListeningView, context: Context) {}
}

class DoubleClickListeningView: NSView {
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    let handler: () -> Void

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            handler()
        }
    }
}
