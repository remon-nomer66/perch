import Foundation
import Testing

@testable import PlayerBridge

/// The queue's contract, exercised with plain closures: no Apple Event, no player,
/// no permission involved.

@Test("perform answers with the work's value")
func performReturnsTheWorkValue() async {
  let queue = AppleEventQueue(label: "PlayerBridgeTests.value")
  let gate = AppleEventQueue.Gate()
  let value = await queue.perform(gate: gate, fallback: -1) { 42 }
  #expect(value == 42)
}

@Test("perform falls back when the deadline passes, then frees the gate")
func performFallsBackOnTimeout() async {
  let queue = AppleEventQueue(label: "PlayerBridgeTests.timeout")
  let gate = AppleEventQueue.Gate()
  let release = DispatchSemaphore(value: 0)

  // The work outlives the deadline: the caller gets the fallback, not the answer.
  let value = await queue.perform(gate: gate, timeout: .milliseconds(50), fallback: -1) {
    release.wait()
    return 1
  }
  #expect(value == -1)

  // Once the stuck work finishes it frees the gate; a later round gets a real
  // answer again. Polled with a bound because the tail of the stuck item runs on
  // the queue's own time.
  release.signal()
  var later = -2
  for _ in 0..<100 where later != 3 {
    later = await queue.perform(gate: gate, fallback: -2) { 3 }
    if later != 3 { try? await Task.sleep(for: .milliseconds(10)) }
  }
  #expect(later == 3)
}

@Test("A round finding the gate claimed skips with the fallback")
func gateSkipsWhileAnEarlierRoundRuns() async {
  let queue = AppleEventQueue(label: "PlayerBridgeTests.gate")
  let gate = AppleEventQueue.Gate()
  let blocker = DispatchSemaphore(value: 0)
  // Signals — async-side — that the first round is really on the queue, its claim
  // in place. A semaphore cannot be awaited from an async context.
  let (started, startedIn) = AsyncStream<Void>.makeStream()

  let first = Task {
    await queue.perform(gate: gate, timeout: .milliseconds(50), fallback: -1) {
      startedIn.yield()
      blocker.wait()
      return 1
    }
  }
  var iterator = started.makeAsyncIterator()
  await iterator.next()

  let second = await queue.perform(gate: gate, fallback: -2) { 2 }
  #expect(second == -2)

  blocker.signal()
  _ = await first.value
}

@Test("Distinct gates do not skip for each other")
func distinctGatesAreIndependent() async {
  let queue = AppleEventQueue(label: "PlayerBridgeTests.gates")
  let readGate = AppleEventQueue.Gate()
  let playingGate = AppleEventQueue.Gate()
  let blocker = DispatchSemaphore(value: 0)
  let (started, startedIn) = AsyncStream<Void>.makeStream()

  let stuck = Task {
    await queue.perform(gate: readGate, timeout: .milliseconds(50), fallback: -1) {
      startedIn.yield()
      blocker.wait()
      return 1
    }
  }
  var iterator = started.makeAsyncIterator()
  await iterator.next()

  // The other gate is free; its round queues behind the stuck item and still
  // answers once that item finishes.
  blocker.signal()
  let other = await queue.perform(gate: playingGate, fallback: -2) { 2 }
  #expect(other == 2)
  _ = await stuck.value
}
