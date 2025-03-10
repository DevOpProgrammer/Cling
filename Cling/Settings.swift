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

    func withKey(_ key: Character?) -> FolderFilter {
        FolderFilter(id: id, folders: folders, key: key)
    }
}

struct QuickFilter: Identifiable, Hashable, Codable, Defaults.Serializable {
    let id: String
    let query: String
    let key: Character?

    var keyEquivalent: KeyEquivalent? {
        key.map { KeyEquivalent($0) }
    }

    func withKey(_ key: Character?) -> QuickFilter {
        QuickFilter(id: id, query: query, key: key)
    }

}

let DEFAULT_FOLDER_FILTERS = [
    FolderFilter(id: "Applications", folders: ["/Applications".filePath!, "/System/Applications".filePath!], key: "a"),
    FolderFilter(id: "Home", folders: [HOME], key: "h"),
    FolderFilter(id: "Documents", folders: [HOME / "Documents", HOME / "Desktop", HOME / "Downloads"], key: "d"),
]

let DEFAULT_QUICK_FILTERS = [
    QuickFilter(id: "PDFs", query: ".pdf$", key: "p"),
    QuickFilter(id: "Folders only", query: "/$", key: "f"),
]

enum SearchScope: String, CaseIterable, Defaults.Serializable {
    case root
    case home
    case library

    var binding: Binding<Bool> {
        Binding(
            get: { Defaults[.searchScopes].contains(self) },
            set: { enabled in
                if enabled {
                    Defaults[.searchScopes].append(self)
                } else {
                    Defaults[.searchScopes].removeAll { $0 == self }
                }
            }
        )
    }
}

extension Defaults.Keys {
    static let suppressTrashConfirm = Key<Bool>("suppressTrashConfirm", default: false)
    static let editorApp = Key<String>("editorApp", default: "/System/Applications/TextEdit.app")
    static let terminalApp = Key<String>("terminalApp", default: "/System/Applications/Utilities/Terminal.app")
    static let showWindowAtLaunch = Key<Bool>("showWindowAtLaunch", default: true)
    static let folderFilters = Key<[FolderFilter]>("folderFilters", default: DEFAULT_FOLDER_FILTERS)
    static let maxResultsCount = Key<Int>("maxResultsCount", default: 30)

    static let enableGlobalHotkey = Key<Bool>("enableGlobalHotkey", default: true)
    static let showAppKey = Key<SauceKey>("showAppKey", default: SauceKey.slash)
    static let triggerKeys = Key<[TriggerKey]>("triggerKeys", default: [.rcmd])

    static let searchScopes = Key<[SearchScope]>("searchScopes", default: [.root, .home, .library])
    static let quickFilters = Key<[QuickFilter]>("quickFilters", default: DEFAULT_QUICK_FILTERS)
}
