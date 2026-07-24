import Foundation
import Testing

@testable import SpatialAudioKit

@Test func aConstantInputConvergesToThatValue() {
  var average = ExponentialAverage(initial: 0)
  for _ in 0..<500 {
    average.update(10, alpha: 0.1)
  }
  #expect(abs(average.value - 10) < 1e-3)
}

@Test func alphaOfOneJumpsImmediately() {
  var average = ExponentialAverage(initial: 0)
  average.update(7, alpha: 1)
  #expect(average.value == 7)
}

@Test func alphaOfZeroFreezes() {
  var average = ExponentialAverage(initial: 3)
  average.update(99, alpha: 0)
  #expect(average.value == 3)
}

@Test func alphaGrowsWithTheTimeStep() {
  // 経過時間が大きいほど、より速く追従する（係数が大きい）。
  let slow = ExponentialAverage.alpha(dt: 0.01, timeConstant: 3)
  let fast = ExponentialAverage.alpha(dt: 1.0, timeConstant: 3)
  #expect(slow < fast)
  #expect(slow > 0 && fast < 1)
}

@Test func aTimeStepEqualToTheConstantDecaysToAboutOneOverE() {
  // dt == timeConstant で、残差は約 1/e（≈0.368）になる。
  let alpha = ExponentialAverage.alpha(dt: 2, timeConstant: 2)
  #expect(abs((1 - alpha) - (1 / M_E)) < 1e-9)
}
