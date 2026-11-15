import Foundation
import XCTest
@testable import Bookshelf

final class CollectionSearchTreeTests: XCTestCase {
  func testDescendantMatchKeepsOnlyItsAncestorsAndExpandsFullPath() {
    let root = CollectionOrderingItem(name: "阅读计划")
    let parent = CollectionOrderingItem(name: "文学", parentID: root.id)
    let hit = CollectionOrderingItem(name: "小说", parentID: parent.id)
    let sibling = CollectionOrderingItem(name: "散文", parentID: parent.id)
    let unrelated = CollectionOrderingItem(name: "参考资料")
    let tree = CollectionSearchTree(items: [unrelated, sibling, hit, root, parent], query: "小说")
    XCTAssertEqual(tree.matchedIDs, [hit.id])
    XCTAssertEqual(Set(tree.items.map(\.id)), [root.id, parent.id, hit.id])
    XCTAssertEqual(tree.initialExpansion(restoring: []), [root.id, parent.id])
    XCTAssertEqual(tree.visibleItems(expanded: tree.ancestorIDs).map(\.id), [root.id, parent.id, hit.id])
    XCTAssertEqual(tree.path(hit.id), "阅读计划 / 文学 / 小说")
  }

  func testMatchingParentDoesNotIncludeUnmatchedChildren() {
    let parent = CollectionOrderingItem(name: "文学")
    let child = CollectionOrderingItem(name: "小说", parentID: parent.id)
    let tree = CollectionSearchTree(items: [parent, child], query: "文学")
    XCTAssertEqual(tree.items.map(\.id), [parent.id])
    XCTAssertEqual(tree.matchedIDs, [parent.id])
    XCTAssertTrue(tree.ancestorIDs.isEmpty)
  }

  func testMatchesInDifferentBranchesKeepStoredSiblingOrderAndSharedAncestors() {
    let root = CollectionOrderingItem(name: "计划", sortOrder: 4)
    let first = CollectionOrderingItem(name: "英文小说", parentID: root.id, sortOrder: 1)
    let second = CollectionOrderingItem(name: "中文小说", parentID: root.id, sortOrder: 8)
    let otherRoot = CollectionOrderingItem(name: "参考", sortOrder: 0)
    let otherHit = CollectionOrderingItem(name: "小说研究", parentID: otherRoot.id)
    let smart = CollectionOrderingItem(name: "小说智能文件夹", sortOrder: 2, isSmart: true)
    let tree = CollectionSearchTree(items: [second, root, first, otherHit, smart, otherRoot], query: "小说")
    XCTAssertEqual(tree.ancestorIDs, [root.id, otherRoot.id])
    XCTAssertEqual(tree.visibleItems(expanded: tree.ancestorIDs).map(\.id),
      [otherRoot.id, otherHit.id, smart.id, root.id, first.id, second.id])
  }

  func testExplicitPathDisambiguatesSameNamedChildren() {
    let first = CollectionOrderingItem(name: "阅读计划")
    let second = CollectionOrderingItem(name: "Archive")
    let hit = CollectionOrderingItem(name: "文学", parentID: first.id)
    let other = CollectionOrderingItem(name: "文学", parentID: second.id)
    let source = [first, second, hit, other]
    let tree = CollectionSearchTree(items: source, query: "  阅读计划/文学  ")
    XCTAssertEqual(tree.matchedIDs, [hit.id])
    XCTAssertEqual(Set(tree.items.map(\.id)), [first.id, hit.id])
    XCTAssertEqual(CollectionSearchTree(items: source, query: "archive").matchedIDs, [second.id])
  }

  func testClearingRestoresOriginalExpansionWithoutLeakingSearchOrManualExpansion() {
    let originalRoot = CollectionOrderingItem(name: "原本展开")
    let originalChild = CollectionOrderingItem(name: "原有子单", parentID: originalRoot.id)
    let closedRoot = CollectionOrderingItem(name: "原本折叠")
    let hit = CollectionOrderingItem(name: "小说", parentID: closedRoot.id)
    let source = [originalRoot, originalChild, closedRoot, hit]
    let original: Set<UUID> = [originalRoot.id]
    let searching = CollectionSearchTree(items: source, query: "小说")
    var temporary = searching.initialExpansion(restoring: original)
    XCTAssertEqual(temporary, [closedRoot.id])
    temporary.removeAll() // Collapsing a search result must not change the saved state.
    let cleared = CollectionSearchTree(items: source, query: "  \n")
    XCTAssertFalse(cleared.isFiltering)
    temporary = cleared.initialExpansion(restoring: original)
    XCTAssertEqual(temporary, original)
    XCTAssertTrue(cleared.visibleItems(expanded: temporary).contains { $0.id == originalChild.id })
    XCTAssertFalse(cleared.visibleItems(expanded: temporary).contains { $0.id == hit.id })
    let anotherSearch = CollectionSearchTree(items: source, query: "原有子单")
    XCTAssertEqual(anotherSearch.initialExpansion(restoring: original), [originalRoot.id])
  }

  func testKeyboardOrderExcludesCollapsedAndUnmatchedBranches() {
    let root = CollectionOrderingItem(name: "计划")
    let hit = CollectionOrderingItem(name: "小说", parentID: root.id)
    let hidden = CollectionOrderingItem(name: "历史", parentID: root.id)
    let tree = CollectionSearchTree(items: [root, hit, hidden], query: "小说")
    XCTAssertEqual(tree.visibleItems(expanded: []).map(\.id), [root.id])
    XCTAssertEqual(tree.visibleItems(expanded: [root.id]).map(\.id), [root.id, hit.id])
    let empty = CollectionSearchTree(items: [root, hit, hidden], query: "不存在")
    XCTAssertTrue(empty.items.isEmpty)
    XCTAssertTrue(empty.initialExpansion(restoring: [root.id]).isEmpty)
  }

  func testInvalidCycleCannotLoopWhileBuildingPaths() {
    let firstID = UUID(), secondID = UUID()
    let first = CollectionOrderingItem(id: firstID, name: "A", parentID: secondID)
    let second = CollectionOrderingItem(id: secondID, name: "B", parentID: firstID)
    let tree = CollectionSearchTree(items: [first, second], query: "A")
    XCTAssertEqual(tree.path(firstID), "B / A")
    XCTAssertEqual(tree.ancestorIDs, [secondID])
    XCTAssertTrue(tree.visibleItems(expanded: tree.ancestorIDs).isEmpty)
  }
}
