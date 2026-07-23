import Foundation
import Testing

@testable import SpatialAudioKit

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
  abs(a - b) < tolerance
}

@Test func forwardIsAllZero() {
  let f = ListenerOrientation.forward
  #expect(f.yaw == 0)
  #expect(f.pitch == 0)
  #expect(f.roll == 0)
}

@Test func anAngleAlreadyInRangeIsKept() {
  let o = ListenerOrientation(yaw: 0.5, pitch: -0.3, roll: 0.1)
  #expect(isClose(o.yaw, 0.5))
  #expect(isClose(o.pitch, -0.3))
  #expect(isClose(o.roll, 0.1))
}

@Test func aFullTurnWrapsBackToZero() {
  // 2π 回っても向きは同じ。範囲外の累積値を畳み込む。
  let o = ListenerOrientation(yaw: 2 * .pi, pitch: -2 * .pi, roll: 4 * .pi)
  #expect(isClose(o.yaw, 0))
  #expect(isClose(o.pitch, 0))
  #expect(isClose(o.roll, 0))
}

@Test func aValuePastPiWrapsIntoRange() {
  // π を少し超えた値は [-π, π] に入る。音の向きが不連続に飛ばないため。
  let o = ListenerOrientation(yaw: 2 * .pi + 0.5, pitch: -(2 * .pi + 0.5), roll: 0)
  #expect(isClose(o.yaw, 0.5))
  #expect(isClose(o.pitch, -0.5))
  #expect(o.yaw <= .pi && o.yaw >= -.pi)
}

@Test func radiansConvertToDegreesAtTheBoundary() {
  // 境界でだけ度へ変換する。AVAudio3DAngularOrientation は度で受け取るため。
  let o = ListenerOrientation(yaw: .pi, pitch: .pi / 2, roll: -.pi / 4)
  let d = o.degrees
  #expect(isClose(d.yaw, 180))
  #expect(isClose(d.pitch, 90))
  #expect(isClose(d.roll, -45))
}
