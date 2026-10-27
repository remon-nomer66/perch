import Testing

@testable import Perch

// What a write to a guarded panel field does when its turn in the chain comes: an
// intermediate drag value overtaken while it waited is dropped, a final always lands,
// and only a final's read-back lifts the field's guard.

@Test(
  "Each write's step, by whether it is final and whether its token is still current",
  arguments: [
    (isFinal: false, isCurrent: true, step: GuardedWrite.send),
    (isFinal: false, isCurrent: false, step: GuardedWrite.skip),
    (isFinal: true, isCurrent: true, step: GuardedWrite.sendAndConfirm),
    (isFinal: true, isCurrent: false, step: GuardedWrite.sendAndConfirm),
  ]
)
func guardedWriteStep(isFinal: Bool, isCurrent: Bool, step: GuardedWrite) {
  #expect(GuardedWrite.step(isFinal: isFinal, isCurrent: isCurrent) == step)
}

@Test(
  "Only a confirmed write lifts the guard; only a skipped one sends nothing",
  arguments: [
    (step: GuardedWrite.skip, sends: false, liftsGuard: false),
    (step: GuardedWrite.send, sends: true, liftsGuard: false),
    (step: GuardedWrite.sendAndConfirm, sends: true, liftsGuard: true),
  ]
)
func guardedWriteEffects(step: GuardedWrite, sends: Bool, liftsGuard: Bool) {
  #expect(step.sends == sends)
  #expect(step.liftsGuard == liftsGuard)
}
