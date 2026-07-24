import Testing

@testable import Perch

@Test("The pager's stop count and the built pages follow one declared order")
@MainActor
func pagesFollowTheDeclaredOrder() {
  let pages = PanelPages.all(
    spatial: SpatialAudioController(),
    equalizer: nil,
    noiseControl: nil,
    listeningMode: nil,
    applyNoiseControl: { _ in },
    dragNoiseLevel: { _, _ in },
    applyListening: { _ in },
    applyEqualizerPreset: { _ in },
    dragEqualizerBand: { _, _, _ in },
    speakToChat: nil,
    applySpeakToChat: { _ in },
    applySpeakToChatDetail: { _, _ in },
    sidetone: nil,
    applySidetone: { _ in }
  )
  #expect(pages.map(\.id) == PanelPages.pageIDs)
  #expect(pages.count == PanelPages.count)
}
