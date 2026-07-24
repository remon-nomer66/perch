import Foundation
import Testing

@testable import SpatialAudioKit

// 較正の約束: 規定サンプルで ready になり、平均が中心・IPD 中央値が基準になる。

@Test("規定サンプル数で ready になり、進捗が単調に上がる")
func calibrationProgresses() {
  var center = PoseCenter(sampleTarget: 5)
  var lastProgress = -1.0
  for index in 0..<5 {
    let phase = center.add(rotation: .identity, pixelIPD: 60)
    if index < 4 {
      guard case .calibrating(let progress) = phase else {
        Issue.record("較正途中で ready になった")
        return
      }
      #expect(progress > lastProgress)
      lastProgress = progress
    } else {
      #expect(phase == .ready)
    }
  }
}

@Test("中心はサンプルの平均: 対称にばらけた姿勢は真ん中に落ちる")
func centerIsTheMean() {
  var center = PoseCenter(sampleTarget: 4)
  center.add(rotation: Rotation(yaw: 0.2, pitch: 0, roll: 0), pixelIPD: nil)
  center.add(rotation: Rotation(yaw: 0.4, pitch: 0, roll: 0), pixelIPD: nil)
  center.add(rotation: Rotation(yaw: 0.2, pitch: 0, roll: 0), pixelIPD: nil)
  center.add(rotation: Rotation(yaw: 0.4, pitch: 0, roll: 0), pixelIPD: nil)
  guard let mean = center.center else {
    Issue.record("ready になっていない")
    return
  }
  #expect(abs(mean.eulerAngles.yaw - 0.3) < 0.01)
}

@Test("centered は中心からの差分を返す")
func centeredSubtractsTheCenter() {
  var center = PoseCenter(sampleTarget: 2)
  center.add(rotation: Rotation(yaw: 0.3, pitch: 0, roll: 0), pixelIPD: nil)
  center.add(rotation: Rotation(yaw: 0.3, pitch: 0, roll: 0), pixelIPD: nil)
  let difference = center.centered(Rotation(yaw: 0.5, pitch: 0, roll: 0))
  #expect(abs(difference.eulerAngles.yaw - 0.2) < 1e-6)
}

@Test("referenceIPD は較正中の中央値（外れ値に引きずられない）")
func referenceIPDIsTheMedian() {
  var center = PoseCenter(sampleTarget: 5)
  for ipd in [58.0, 60.0, 61.0, 59.0, 300.0] {
    center.add(rotation: .identity, pixelIPD: ipd)
  }
  #expect(center.referenceIPD == 60.0)
}

@Test("瞳が一度も取れなければ referenceIPD は nil")
func noIPDMeansNoReference() {
  var center = PoseCenter(sampleTarget: 2)
  center.add(rotation: .identity, pixelIPD: nil)
  center.add(rotation: .identity, pixelIPD: nil)
  #expect(center.referenceIPD == nil)
}

@Test("ready 後の add は無視される（較正のやり直しは作り直し）")
func readyIsFinal() {
  var center = PoseCenter(sampleTarget: 1)
  center.add(rotation: .identity, pixelIPD: nil)
  center.add(rotation: Rotation(yaw: 1.0, pitch: 0, roll: 0), pixelIPD: nil)
  #expect(center.center?.angle(to: .identity) ?? 1 < 1e-9)
}
