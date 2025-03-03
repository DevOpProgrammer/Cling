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

let notificationCallback: CFNotificationCallback = { notificationCenter, observer, notificationName, object, userInfo in
    guard let object: UnsafeRawPointer else {
        return
    }
    let query: MDQuery = unsafeBitCast(object, to: MDQuery.self)
    var paths: [FilePath] = []

    MDQueryStop(query)
    for i in 0 ..< MDQueryGetResultCount(query) {
        guard let rawPtr = MDQueryGetResultAtIndex(query, i) else {
            continue
        }
        let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()
        guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else {
            continue
        }
        paths.append(FilePath(path))
    }

    mainActor {
        FUZZY.recents = paths
    }
}

// borrowed from Raycast
let queryString =
    #"((kMDItemSupportFileType != "MDSystemFile")) && ((kMDItemLastUsedDate = "*") && ((kMDItemContentTypeTree = public.content) || (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive)))"#

private let mdQueryObserver: UnsafeMutablePointer<AnyObject?> = .allocate(capacity: 1)

func queryRecents() -> MDQuery? {
    guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, [kMDItemPath] as CFArray, SORT_ATTRS) else {
        log.error("Failed to create query")
        return nil
    }
    MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
    MDQuerySetMaxCount(query, 30)
    MDQuerySetSortComparator(query, sortComparator, nil)
    MDQuerySetDispatchQueue(query, .global())

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        mdQueryObserver,
        notificationCallback,
        kMDQueryDidFinishNotification,
        nil,
        .deliverImmediately
    )

    MDQueryExecute(query, 0)
    return query
}
