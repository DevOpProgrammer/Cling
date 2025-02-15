import Defaults
import Foundation
import SwiftUI

extension Defaults.Keys {
    static let suppressTrashConfirm = Key<Bool>("suppressTrashConfirm", default: false)
    static let editorApp = Key<String>("editorApp", default: "/System/Applications/TextEdit.app")
    static let terminalApp = Key<String>("terminalApp", default: "/System/Applications/Utilities/Terminal.app")
    static let showWindowAtLaunch = Key<Bool>("showWindowAtLaunch", default: true)
}
