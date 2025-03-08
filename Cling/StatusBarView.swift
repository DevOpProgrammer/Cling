//
//  StatusBarView.swift
//  Cling
//
//  Created by Alin Panaitiu on 08.02.2025.
//

import Defaults
import SwiftUI

struct StatusBarView: View {
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey

    var body: some View {
        HStack {
            Text("Syntax:")
            Text(
                "**`'wild`** (exact-match *wild*) **`^music`** (starts with *music*) **`.mp3$ | .aac$`** (ends with *.mp3* OR *.aac*) **!rmx** (not containing *rmx*)"
            )

            Spacer()

            Text("**`\(triggerKeys.shortReadableStr) + \(showAppKey.character)`** to show/hide").padding(.trailing, 2)

            Button(action: {
                fuzzy.refresh(fullReindex: NSEvent.modifierFlags.contains(.option))
            }) {
                Image(systemName: "arrow.clockwise").bold()
            }
            .help("Refresh (Option-click for full reindex)")
            .buttonStyle(TextButton(borderColor: .clear))

            SettingsLink {
                Image(systemName: "gearshape").bold()
            }
            .buttonStyle(TextButton(borderColor: .clear))
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(1)
    }

    @State private var fuzzy: FuzzyClient = FUZZY

}
