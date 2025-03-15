import Defaults
import Foundation
import Lowtech
import System

let SORT_ATTRS = [
    kMDItemLastUsedDate,
    kMDItemFSContentChangeDate,
    kMDItemFSCreationDate,
] as CFArray

extension CFComparisonResult {
    func reversed() -> CFComparisonResult {
        switch self {
        case .compareLessThan:
            return .compareGreaterThan
        case .compareGreaterThan:
            return .compareLessThan
        case .compareEqualTo:
            return .compareEqualTo
        @unknown default:
            return .compareEqualTo
        }
    }
}

let sortComparator: MDQuerySortComparatorFunction = { values1, values2, context in
    guard let value1 = values1?.pointee?.takeUnretainedValue() else {
        return .compareGreaterThan
    }
    guard let value2 = values2?.pointee?.takeUnretainedValue() else {
        return .compareLessThan
    }

    let date1 = value1 as! CFDate
    let date2 = value2 as! CFDate

    return CFDateCompare(date1, date2, nil).reversed()
}

extension MDQuery {
    @MainActor
    func getPaths() -> [FilePath] {
        var paths: [FilePath] = []
        for i in 0 ..< MDQueryGetResultCount(self) {
            guard let rawPtr = MDQueryGetResultAtIndex(self, i) else {
                continue
            }
            let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else {
                continue
            }
            let filePath = FilePath(path)
            if FUZZY.removedFiles.contains(filePath.string) {
                continue
            }
            if filePath.starts(with: HOME), filePath.string.isIgnored(in: fsignoreString) {
                continue
            }
            paths.append(filePath)
        }
        return paths
    }
}

@MainActor var recentsSetTask: DispatchWorkItem? {
    didSet {
        oldValue?.cancel()
    }
}

let queryFinishCallback: CFNotificationCallback = { notificationCenter, observer, notificationName, object, userInfo in
    guard let object: UnsafeRawPointer else {
        return
    }

    let query: MDQuery = unsafeBitCast(object, to: MDQuery.self)

    mainActor {
        let paths = query.getPaths()
        FUZZY.recents = paths
        FUZZY.sortedRecents = FUZZY.sortedResults(results: paths)
    }
}

let queryUpdateCallback: CFNotificationCallback = { notificationCenter, observer, notificationName, object, userInfo in
    guard let object: UnsafeRawPointer else {
        return
    }

    let userInfo = userInfo as? [CFString: Any]
    let added = userInfo?[kMDQueryUpdateAddedItems] as? [MDItem]
    let removed = userInfo?[kMDQueryUpdateRemovedItems] as? [MDItem]
    guard added?.isEmpty == false || removed?.isEmpty == false else {
        return
    }

    let query: MDQuery = unsafeBitCast(object, to: MDQuery.self)

    mainActor {
        let paths = query.getPaths()
        FUZZY.recents = paths
        FUZZY.sortedRecents = FUZZY.sortedResults(results: paths)
    }

    // let changed = userInfo?[kMDQueryUpdateChangedItems] as? [MDItem]

    // for item in added ?? [] {
    //     print("Added: \(item.description)")
    // }
    // for item in removed ?? [] {
    //     print("Removed: \(item.description)")
    // }
    // for item in changed ?? [] {
    //     print("Changed: \(item.description)")
    // }
}

extension MDItem {
    var description: String {
        guard let path = MDItemCopyAttribute(self, kMDItemPath) as? String else {
            return "<MDItem Unknown>"
        }
        guard let date = MDItemCopyAttribute(self, kMDItemLastUsedDate) as? Date ?? MDItemCopyAttribute(self, kMDItemFSContentChangeDate) as? Date ?? MDItemCopyAttribute(self, kMDItemFSCreationDate) as? Date,
              let size = MDItemCopyAttribute(self, kMDItemFSSize) as? Int
        else {
            return "<MDItem \(path)>"
        }
        return "<MDItem \(path) | \(date.formatted(dateFormat)) | \(size.humanSize)>"
    }
}

// borrowed from Raycast
let queryString =
    #"((kMDItemSupportFileType != "MDSystemFile")) && ((kMDItemLastUsedDate = "*") && ((kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive)))"#

private let mdQueryObserver: UnsafeMutablePointer<AnyObject?> = .allocate(capacity: 1)

func stopRecentsQuery(_ query: MDQuery) {
    MDQueryStop(query)
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        CFNotificationName(kMDQueryDidFinishNotification),
        unsafeBitCast(query, to: UnsafeRawPointer.self)
    )
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        CFNotificationName(kMDQueryDidUpdateNotification),
        unsafeBitCast(query, to: UnsafeRawPointer.self)
    )
}

func queryRecents() -> MDQuery? {
    guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, [kMDItemPath] as CFArray, SORT_ATTRS) else {
        log.error("Failed to create query")
        return nil
    }
    MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
    MDQuerySetMaxCount(query, Defaults[.maxResultsCount])
    MDQuerySetSortComparator(query, sortComparator, nil)
    MDQuerySetDispatchQueue(query, .global())

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        queryFinishCallback,
        kMDQueryDidFinishNotification,
        unsafeBitCast(query, to: UnsafeRawPointer.self),
        .deliverImmediately
    )
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        queryUpdateCallback,
        kMDQueryDidUpdateNotification,
        unsafeBitCast(query, to: UnsafeRawPointer.self),
        .deliverImmediately
    )

    MDQueryExecute(query, kMDQueryWantsUpdates.rawValue.u)
    return query
}
