import Foundation
import Lowtech
import SwiftUI

let SHARING_MANAGER = SharingManager()

struct ShareButton: View {
    var urls: [URL]

    var body: some View {
        Button(
            action: { sharing = true },
            label: { Image(systemName: "square.and.arrow.up") }
        )
        .background(SharingsPicker(isPresented: $sharing, sharingItems: urls as [Any]))
    }

    @State private var sharing = false
}
