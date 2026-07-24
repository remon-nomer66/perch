import Testing

@testable import Perch

private func rule(_ trigger: SoundRule.Trigger) -> SoundRule { SoundRule(trigger: trigger) }

@Test("Reordering steps over rules of another kind to swap within its own list")
func reordersWithinFilteredList() {
  let a = rule(.site("a.com"))
  let interleaved = rule(.artist("X"))
  let b = rule(.site("b.com"))
  let rules = [a, interleaved, b]
  let sites = [a, b]  // what the site/app tab shows, the artist rule filtered out

  // Moving b up swaps it with a in the full array, stepping over the artist rule.
  let moved = RuleOrdering.moving(rules, id: b.id, by: -1, within: sites)
  #expect(moved.map(\.id) == [b.id, interleaved.id, a.id])
}

@Test("Reordering past the edge of the shown list is a no-op")
func reorderNoOpAtEdge() {
  let a = rule(.artist("A"))
  let b = rule(.artist("B"))
  let rules = [a, b]
  #expect(RuleOrdering.moving(rules, id: a.id, by: -1, within: rules).map(\.id) == [a.id, b.id])
  #expect(RuleOrdering.moving(rules, id: b.id, by: 1, within: rules).map(\.id) == [a.id, b.id])
}
