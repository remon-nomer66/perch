import BoseCore
import Testing

@testable import BosePanel

/// The view-model's projection and optimistic gesture updates, exercised with no session
/// (the optimistic snapshot update is all this stage needs; stage 6 adds the live device
/// round trip). Each gesture updates the panel state at once so the control is responsive.
@MainActor
struct BosePanelModelTests {
  private func ultra2Model() -> BosePanelModel {
    let snapshot = BoseDeviceSnapshot(
      modelName: "QC Ultra 2",
      noiseCancellation: BmapNoiseCancellationReading(
        currentStep: 5, maximumStep: 10, isEnabled: true, rawFlags: 0x03
      ),
      liveNoiseControl: BmapNoiseControlSetting(
        cnc: 5, spatial: .off, windBlock: false, ancEnabled: true
      ),
      equalizerBands: [
        BmapEqualizerBand(bandId: 0, minimum: -10, maximum: 10, current: 0),
        BmapEqualizerBand(bandId: 1, minimum: -10, maximum: 10, current: 0),
        BmapEqualizerBand(bandId: 2, minimum: -10, maximum: 10, current: 0),
      ],
      audioModes: BoseAudioModes(
        modes: [
          BoseAudioMode(slot: 0, name: "Quiet", isEditable: false),
          BoseAudioMode(slot: 4, name: "Home", isEditable: true),
        ],
        selectedSlot: 0
      ),
      sidetone: .medium,
      isControllable: true,
      acceptsWrites: true
    )
    return BosePanelModel(snapshot: snapshot, config: .qcUltra2)
  }

  @Test("The model projects its initial snapshot")
  func initialProjection() {
    let model = ultra2Model()
    #expect(model.state.modelName == "QC Ultra 2")
    #expect(model.state.cnc?.wireValue == 5)
    #expect(model.state.ancEnabled == true)
  }

  @Test("A CNC strength drag updates the state, inverting strength back to the wire")
  func cncDrag() {
    let model = ultra2Model()
    // Strength 8 on a 0...10 range is wire 2.
    model.dragCNCStrength(8, isFinal: true)
    #expect(model.state.cnc?.strength == 8)
    #expect(model.state.cnc?.wireValue == 2)
  }

  @Test("Toggling ANC updates the state")
  func toggleANC() {
    let model = ultra2Model()
    model.setANC(false)
    #expect(model.state.ancEnabled == false)
  }

  @Test("Toggling wind reduction updates the state")
  func toggleWind() {
    let model = ultra2Model()
    model.setWind(true)
    #expect(model.state.windReduction == true)
  }

  @Test("Setting spatial updates the state")
  func setSpatial() {
    let model = ultra2Model()
    model.setSpatial(.room)
    #expect(model.state.spatial == .room)
  }

  @Test("Dragging an EQ band updates that band's value")
  func eqBandDrag() {
    let model = ultra2Model()
    model.dragEqualizerBand(bandId: 1, value: -4, isFinal: true)
    let mid = model.state.equalizer?.bands.first { $0.bandId == 1 }
    #expect(mid?.value == -4)
  }

  @Test("A periodic refresh that did not re-read EQ never reverts a raised band")
  func eqSurvivesStaleRefresh() {
    // The bug: the 4-second refresh reads only battery and noise control, so it carries a
    // stale connect-time EQ (all flat). Applying it must not snap the just-raised band back
    // — the model owns the equalizer once the user has touched it.
    let model = ultra2Model()
    model.dragEqualizerBand(bandId: 1, value: -4, isFinal: true)

    // A refresh snapshot exactly as the controller builds it: fresh battery/noise, but the
    // equalizer bands carried over unchanged from connect (all 0).
    let staleRefresh = BoseDeviceSnapshot(
      modelName: "QC Ultra 2",
      noiseCancellation: BmapNoiseCancellationReading(
        currentStep: 5, maximumStep: 10, isEnabled: true, rawFlags: 0x03
      ),
      liveNoiseControl: BmapNoiseControlSetting(
        cnc: 5, spatial: .off, windBlock: false, ancEnabled: true
      ),
      equalizerBands: [
        BmapEqualizerBand(bandId: 0, minimum: -10, maximum: 10, current: 0),
        BmapEqualizerBand(bandId: 1, minimum: -10, maximum: 10, current: 0),
        BmapEqualizerBand(bandId: 2, minimum: -10, maximum: 10, current: 0),
      ],
      isControllable: true,
      acceptsWrites: true
    )
    model.apply(snapshot: staleRefresh)

    let mid = model.state.equalizer?.bands.first { $0.bandId == 1 }
    #expect(mid?.value == -4)
  }

  @Test("Selecting a mode updates the selection")
  func selectMode() {
    let model = ultra2Model()
    model.selectMode(4)
    #expect(model.state.audioModes?.selectedSlot == 4)
  }

  @Test("Setting sidetone updates the state")
  func setSidetone() {
    let model = ultra2Model()
    model.setSidetone(.low)
    #expect(model.state.sidetone == .low)
  }

  @Test("A gesture for a feature the model does not declare is a no-op")
  func unsupportedGestureIsNoop() {
    // QC35 does not expose the live-control block, so ANC is not part of the state.
    let snapshot = BoseDeviceSnapshot(
      noiseCancellation: BmapNoiseCancellationReading(
        currentStep: 1, maximumStep: 3, isEnabled: true, rawFlags: 0x03
      ),
      isControllable: true,
      acceptsWrites: true
    )
    let model = BosePanelModel(snapshot: snapshot, config: .qc35)
    #expect(model.state.ancEnabled == nil)
    model.setANC(true)
    #expect(model.state.ancEnabled == nil)
  }
}
