import Dispatch
import Foundation
import Testing
import os

@testable import Perch

// 同期の往復（coreaudiod への問い合わせ）を MainActor の外で、時間を区切って行う口。
// 約束: 外で走る / 時間内に戻らなければ「答えなし」/ 戻らない呼び出しの後ろに次を
// 積まない（ブロックしたスレッドを増やさない）/ 戻ってくれば次はまた走る。
// 壁時計の上限は見ない。戻らない呼び出しはテストが解放するまで戻らないラッチで表し、
// 起きた順序と回数だけを確かめる（負荷がかかっても結果が変わらないように）。

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

/// 条件が満ちるまで譲る。回数で区切り、壁時計の長さは問わない。
@MainActor
private func eventually(_ condition: () -> Bool) async {
  for _ in 0..<2_000 where !condition() {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
@Test("すぐ戻る呼び出しは、その答えを返す。MainActor から呼んでも、走るのは外")
func quickCallAnswersOffTheMainThread() async {
  let gate = BlockingCallGate<Int>(label: "test.quick", timeout: .seconds(60))
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
@Test("戻らない呼び出しは「答えなし」。その間の次の呼び出しは走らせずに「答えなし」。戻れば次はまた走る")
func hungCallAnswersNothingAndDoesNotPileUp() async {
  let gate = BlockingCallGate<Int>(label: "test.hung", timeout: .milliseconds(50))
  let release = DispatchSemaphore(value: 0)
  let first = Calls()
  let firstReturned = Calls()

  let firstAnswer = await gate.run {
    first.record()
    release.wait()  // テストが解放するまで戻らない
    firstReturned.record()
    return 1
  }
  #expect(firstAnswer == nil)

  let second = Calls()
  let secondAnswer = await gate.run {
    second.record()
    return 2
  }
  #expect(secondAnswer == nil)
  #expect(second.count == 0)

  // 1回目は確かに走り始めていて、まだ戻っていない。
  await eventually { first.count == 1 }
  #expect(first.count == 1)
  #expect(firstReturned.count == 0)

  release.signal()
  await eventually { firstReturned.count == 1 }
  var reopened: Int?
  for _ in 0..<2_000 where reopened == nil {
    reopened = await gate.run { 3 }
    if reopened == nil { try? await Task.sleep(for: .milliseconds(5)) }
  }
  #expect(reopened == 3)
  #expect(second.count == 0)
}
