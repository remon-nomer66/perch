import Foundation
import Testing
import os

@testable import Perch

// 同期の往復（coreaudiod への問い合わせ）を MainActor の外で、時間を区切って行う口。
// 約束: 外で走る / 時間内に戻らなければ「答えなし」/ 戻らない呼び出しの後ろに次を
// 積まない（ブロックしたスレッドを増やさない）/ 戻ってくれば次はまた走る。

/// 呼ばれた回数と、どのスレッドで走ったかを記録する。
private final class Calls: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: (count: 0, onMain: false))
  var count: Int { state.withLock { $0.count } }
  var ranOnMain: Bool { state.withLock { $0.onMain } }
  func record() {
    let onMain = Thread.isMainThread
    state.withLock {
      $0.count += 1
      $0.onMain = $0.onMain || onMain
    }
  }
}

@MainActor
@Test("すぐ戻る呼び出しは、その答えを返す。MainActor から呼んでも、走るのは外")
func quickCallAnswersOffTheMainThread() async {
  let gate = BlockingCallGate<Int>(label: "test.quick", timeout: .seconds(2))
  let calls = Calls()
  let answer = await gate.run {
    calls.record()
    return 42
  }
  #expect(answer == 42)
  #expect(calls.count == 1)
  #expect(!calls.ranOnMain)
}

@MainActor
@Test("時間内に戻らなければ「答えなし」。戻らないあいだの次の呼び出しは走らせずに「答えなし」")
func slowCallTimesOutWithoutPilingUp() async {
  let gate = BlockingCallGate<Int>(label: "test.slow", timeout: .milliseconds(20))
  let calls = Calls()
  let started = ContinuousClock.now
  let first = await gate.run {
    calls.record()
    Thread.sleep(forTimeInterval: 0.4)
    return 1
  }
  #expect(first == nil)
  #expect(ContinuousClock.now - started < .milliseconds(300))

  let second = await gate.run {
    calls.record()
    return 2
  }
  #expect(second == nil)
  #expect(calls.count == 1)
}

@MainActor
@Test("遅れていた呼び出しが戻れば、次はまた走る")
func gateReopensOnceTheSlowCallReturns() async {
  let gate = BlockingCallGate<Int>(label: "test.reopen", timeout: .milliseconds(20))
  _ = await gate.run {
    Thread.sleep(forTimeInterval: 0.1)
    return 1
  }
  try? await Task.sleep(for: .milliseconds(250))
  let answer = await gate.run { 3 }
  #expect(answer == 3)
}
