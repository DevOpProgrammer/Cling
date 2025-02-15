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
