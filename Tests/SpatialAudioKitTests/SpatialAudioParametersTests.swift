import Foundation
import Testing

@testable import SpatialAudioKit

@Test func theDefaultParametersStartDisabledWithStandardQuality() {
  // 既定は無効・標準品質・30°配置。勝手に空間化を始めない。
  let p = SpatialAudioParameters()
  #expect(p.isEnabled == false)
  #expect(p.quality == .standard)
  #expect(p.field == StereoField())
}

@Test func settingEnabledReturnsANewValueAndLeavesTheOriginalUntouched() {
  // 不変更新: 元は書き換えず、変更を反映した新しい値を返す。
  let original = SpatialAudioParameters()
  let enabled = original.setting(enabled: true)
  #expect(original.isEnabled == false)
  #expect(enabled.isEnabled == true)
  // 他のフィールドは引き継がれる。
  #expect(enabled.quality == original.quality)
  #expect(enabled.field == original.field)
}

@Test func settingFieldAndQualityCompose() {
  let p = SpatialAudioParameters()
    .setting(enabled: true)
    .setting(quality: .high)
    .setting(field: StereoField(spread: .pi / 4, distance: 2))
  #expect(p.isEnabled == true)
  #expect(p.quality == .high)
  #expect(p.field.distance == 2)
}

@Test func everyRenderingQualityIsRepresented() {
  // 品質段階の取りこぼしがないことを固定する。
  #expect(Set(SpatialRenderingQuality.allCases) == [.standard, .high, .light])
}
