import Foundation
import Testing

@testable import SpatialAudioKit

@Test func aSpikeAboveTheBaselineIsAnOnset() {
  var picker = OnsetPeakPicker()
  // ベースラインで慣らしてから急に立ち上げる。
  for _ in 0..<300 { _ = picker.observe(flux: 0.02, dt: 0.01) }
  let strength = picker.observe(flux: 0.5, dt: 0.01)
  #expect(strength > 0)
  #expect(strength <= 1.0)
}

@Test func aSteadyFluxSettlesToNoOnsets() {
  var picker = OnsetPeakPicker()
  // 一定のフラックスは慣れたら onset にしない（平均と分散に吸収される）。
  for _ in 0..<300 { _ = picker.observe(flux: 0.05, dt: 0.01) }
  var onsets = 0
  for _ in 0..<100 where picker.observe(flux: 0.05, dt: 0.01) > 0 { onsets += 1 }
  #expect(onsets == 0)
}

@Test func theRefractoryPeriodSuppressesDoubleOnsets() {
  var picker = OnsetPeakPicker(refractory: 0.15)
  for _ in 0..<300 { _ = picker.observe(flux: 0.02, dt: 0.01) }
  let first = picker.observe(flux: 0.5, dt: 0.01)
  let immediate = picker.observe(flux: 0.5, dt: 0.01)  // 10ms後 → 不応期内
  #expect(first > 0)
  #expect(immediate == 0)
}

@Test func periodicSpikesAreEachDetected() {
  var picker = OnsetPeakPicker(refractory: 0.15)
  var onsets = 0
  // 0.5秒ごと（=120BPM相当）のスパイク。
  for step in 0..<500 {
    let flux = (step % 50 == 0) ? 0.5 : 0.02
    if picker.observe(flux: flux, dt: 0.01) > 0 { onsets += 1 }
  }
  #expect(onsets >= 8 && onsets <= 12)
}

@Test func nearSilentFluxNeverTriggers() {
  var picker = OnsetPeakPicker(minFlux: 0.003)
  var onsets = 0
  // 下限未満の微小な揺れだけなら onset にしない。
  for step in 0..<300 {
    let flux = (step % 40 == 0) ? 0.002 : 0.0002
    if picker.observe(flux: flux, dt: 0.01) > 0 { onsets += 1 }
  }
  #expect(onsets == 0)
}

@Test func aStrongerSpikeYieldsAStrongerOnset() {
  var weakPicker = OnsetPeakPicker()
  var strongPicker = OnsetPeakPicker()
  for _ in 0..<300 {
    _ = weakPicker.observe(flux: 0.05, dt: 0.01)
    _ = strongPicker.observe(flux: 0.05, dt: 0.01)
  }
  let weak = weakPicker.observe(flux: 0.12, dt: 0.01)
  let strong = strongPicker.observe(flux: 0.6, dt: 0.01)
  #expect(weak > 0)
  #expect(strong >= weak)
}
