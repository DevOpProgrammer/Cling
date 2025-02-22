import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

extension FilePath: Defaults.Serializable {
    public init?(from defaultsValue: String) {
        self.init(defaultsValue)
    }

    public var defaultsValue: String {
        string
    }
}

extension Character: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard string.count == 1 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "String too long")
        }
        self = string.first!
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(self))
    }
}

struct FolderFilter: Identifiable, Hashable, Codable, Defaults.Serializable {
    let id: String
    let folders: [FilePath]
    let key: Character?

    var keyEquivalent: KeyEquivalent? {
        key.map { KeyEquivalent($0) }
    }
}

let DEFAULT_FOLDER_FILTERS = [
    FolderFilter(id: "Applications", folders: ["/Applications".filePath!, "/System/Applications".filePath!], key: "a"),
    FolderFilter(id: "Home", folders: [HOME], key: "h"),
    FolderFilter(id: "Documents", folders: [HOME / "Documents", HOME / "Desktop", HOME / "Downloads"], key: "d"),
]

extension Defaults.Keys {
    static let suppressTrashConfirm = Key<Bool>("suppressTrashConfirm", default: false)
    static let editorApp = Key<String>("editorApp", default: "/System/Applications/TextEdit.app")
    static let terminalApp = Key<String>("terminalApp", default: "/System/Applications/Utilities/Terminal.app")
    static let showWindowAtLaunch = Key<Bool>("showWindowAtLaunch", default: true)
    static let folderFilters = Key<[FolderFilter]>("folderFilters", default: DEFAULT_FOLDER_FILTERS)
}
