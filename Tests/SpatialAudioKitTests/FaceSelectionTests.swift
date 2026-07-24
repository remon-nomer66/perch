import CoreGraphics
import Testing

@testable import SpatialAudioKit

// 顔選択の約束: 初回は最大、以後は位置連続性で同じ顔に張り付き、近くに候補が
// なければロスト（別人へ飛ばない）。

@Test("前歴なしなら最大の顔を選ぶ")
func picksTheLargestFirst() {
  let small = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
  let large = CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)
  #expect(FaceSelection.index(of: [small, large], previous: nil) == 1)
}

@Test("前フレームの位置に最も近い顔へ張り付く（大きさでは飛ばない）")
func sticksToTheNearest() {
  let previous = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)
  let same = CGRect(x: 0.12, y: 0.41, width: 0.2, height: 0.2)
  let bigger = CGRect(x: 0.6, y: 0.4, width: 0.35, height: 0.35)
  #expect(FaceSelection.index(of: [bigger, same], previous: previous) == 1)
}

@Test("最も近い候補でも遠すぎれば別人 — ロスト扱い")
func farCandidatesAreNotTheSamePerson() {
  let previous = CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2)
  let elsewhere = CGRect(x: 0.7, y: 0.7, width: 0.25, height: 0.25)
  #expect(FaceSelection.index(of: [elsewhere], previous: previous) == nil)
}

@Test("候補なしは nil")
func emptyIsNil() {
  #expect(FaceSelection.index(of: [], previous: nil) == nil)
}
