import Foundation
import Testing
@testable import Diffusely

struct LibrarySelectionTests {
    @Test func ordinaryClickReplacesSelection() {
        #expect(LibrarySelection.selecting(3, in: [1, 2, 3], current: [1, 2], anchor: 1,
                                           extending: false, toggling: false) == [3])
    }

    @Test func commandClickTogglesOnlyTheClickedItem() {
        #expect(LibrarySelection.selecting(2, in: [1, 2, 3], current: [1, 2], anchor: 1,
                                           extending: false, toggling: true) == [1])
        #expect(LibrarySelection.selecting(3, in: [1, 2, 3], current: [1], anchor: 1,
                                           extending: false, toggling: true) == [1, 3])
    }

    @Test func rangeUsesVisibleOrderInBothDirections() {
        #expect(LibrarySelection.selecting(3, in: [5, 1, 3, 7], current: [], anchor: 5,
                                           extending: true, toggling: false) == [5, 1, 3])
        #expect(LibrarySelection.selecting(5, in: [5, 1, 3, 7], current: [], anchor: 3,
                                           extending: true, toggling: false) == [5, 1, 3])
    }

    @Test func staleOrCollapsedAnchorFallsBackToClickedItem() {
        #expect(LibrarySelection.selecting(3, in: [1, 3], current: [1], anchor: 2,
                                           extending: true, toggling: false) == [3])
    }

    @Test func commandShiftExtendsExistingSelection() {
        #expect(LibrarySelection.selecting(3, in: [1, 2, 3, 4], current: [4], anchor: 1,
                                           extending: true, toggling: true) == [1, 2, 3, 4])
    }

    @Test func itemOutsideVisibleScopeCannotBeSelected() {
        #expect(LibrarySelection.selecting(9, in: [1, 2], current: [1], anchor: 1,
                                           extending: true, toggling: false) == [1])
    }
}

struct LibraryPresentationTests {
    @Test func deletionDescribesTheActualStorage() {
        let folder = LibraryRoot.custom(URL(fileURLWithPath: "/Volumes/Photos/Archive"))
        #expect(folder.deletionMessage(plural: false).contains("Archive"))
        #expect(!folder.deletionMessage(plural: false).contains("iCloud"))
        #expect(LibraryRoot.iCloud.deletionMessage(plural: true).contains("synced devices"))
        #expect(!LibraryRoot.iCloud.deletionMessage(plural: false, localOnly: true).contains("iCloud"))
    }

    @Test func searchMatchesEveryWordWithoutCaseSensitivity() {
        #expect("Alice Portrait FLUX 123".matchesSearch("flux alice"))
        #expect(!"Alice Portrait FLUX 123".matchesSearch("flux bob"))
        #expect("Alice".matchesSearch("  "))
    }
}
