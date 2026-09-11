import DesktopGroupsCore
import Testing

private let groupKey = GroupKey(spaceID: 42, displayID: "DISPLAY-A")
private let one = WindowKey(processID: 10, windowID: 101)
private let two = WindowKey(processID: 20, windowID: 202)
private let three = WindowKey(processID: 30, windowID: 303)

@Test func newGroupPutsFocusedWindowFirstThenUsesZOrder() {
    var store = GroupStore()
    let group = store.createOrRepair(
        key: groupKey,
        focused: two,
        eligibleFrontToBack: [one, two, three]
    )

    #expect(group.members.map(\.key) == [two, one, three])
    #expect(group.activeIndex == 0)
}

@Test func reconciliationCompactsAndAppendsWithoutReordering() {
    var store = GroupStore()
    _ = store.createOrRepair(
        key: groupKey,
        focused: one,
        eligibleFrontToBack: [one, two]
    )
    _ = store.activate(two, in: groupKey)

    let group = store.reconcile(
        key: groupKey,
        eligibleFrontToBack: [three, two]
    )

    #expect(group?.members.map(\.key) == [two, three])
    #expect(group?.activeIndex == 0)
    #expect(group?.members[1].lastFillResult == .deferred)
}

@Test func repairPreservesExistingOrderAndAddsMissingFocusedWindowLast() {
    var store = GroupStore()
    _ = store.createOrRepair(
        key: groupKey,
        focused: one,
        eligibleFrontToBack: [one, two]
    )

    let group = store.createOrRepair(
        key: groupKey,
        focused: three,
        eligibleFrontToBack: [three, two, one]
    )

    #expect(group.members.map(\.key) == [one, two, three])
    #expect(group.activeIndex == 2)
}

@Test func cyclicSelectionWrapsInBothDirections() {
    var store = GroupStore()
    _ = store.createOrRepair(
        key: groupKey,
        focused: one,
        eligibleFrontToBack: [one, two, three]
    )

    #expect(store.select(offset: -1, in: groupKey)?.key == three)
    #expect(store.select(offset: 1, in: groupKey)?.key == one)
}

@Test func directSelectionUsesZeroBasedInternalIndex() {
    var store = GroupStore()
    _ = store.createOrRepair(
        key: groupKey,
        focused: one,
        eligibleFrontToBack: [one, two, three]
    )

    #expect(store.select(index: 1, in: groupKey)?.key == two)
    #expect(store.groups[groupKey]?.activeIndex == 1)
    #expect(store.select(index: 9, in: groupKey) == nil)
}

@Test func fillResultSurvivesReconciliation() {
    var store = GroupStore()
    _ = store.createOrRepair(
        key: groupKey,
        focused: one,
        eligibleFrontToBack: [one, two]
    )
    store.recordFill(.succeeded, for: two, in: groupKey)

    let group = store.reconcile(key: groupKey, eligibleFrontToBack: [two, one, three])

    #expect(group?.members.first { $0.key == two }?.lastFillResult == .succeeded)
}
