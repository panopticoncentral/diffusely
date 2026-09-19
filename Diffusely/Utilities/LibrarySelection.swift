import Foundation

/// Selection math is independent of view layout and only operates on visible IDs.
enum LibrarySelection {
    static func selecting(_ id: Int, in orderedIDs: [Int], current: Set<Int>, anchor: Int?,
                          extending: Bool, toggling: Bool) -> Set<Int> {
        guard orderedIDs.contains(id) else { return current }
        if extending, let anchor, let start = orderedIDs.firstIndex(of: anchor),
           let end = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(start, end)...max(start, end)])
            return toggling ? current.union(range) : range
        }
        if toggling {
            var result = current
            if !result.insert(id).inserted { result.remove(id) }
            return result
        }
        return [id]
    }
}
