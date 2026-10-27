import BoseCore
import DeviceContract
import Testing

@testable import BosePanel

/// Projection from a session snapshot onto the panel state: the right values appear, and a
/// feature the model does not declare is hidden rather than shown as a dead control.
struct BosePanelStateProjectionTests {
  // A full Ultra 2 snapshot mirroring the frozen-spec fixture values.
  private func ultra2Snapshot() -> BoseDeviceSnapshot {
    BoseDeviceSnapshot(
      modelName: "QC Ultra 2",
      battery: [BmapBatteryComponent(percent: 80, minutesRemaining: nil, componentId: 0)],
      noiseCancellation: BmapNoiseCancellationReading(
        currentStep: 5, maximumStep: 10, isEnabled: true, rawFlags: 0x03
      ),
      liveNoiseControl: BmapNoiseControlSetting(
        cnc: 5, spatial: .head, windBlock: false, ancEnabled: true
      ),
      equalizerBands: [
        BmapEqualizerBand(bandId: 0, minimum: -10, maximum: 10, current: 0),
        BmapEqualizerBand(bandId: 1, minimum: -10, maximum: 10, current: -2),
        BmapEqualizerBand(bandId: 2, minimum: -10, maximum: 10, current: -6),
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
  }

  @Test("A full Ultra 2 snapshot projects every feature")
  func fullUltra2() {
    let state = BosePanelState.project(from: ultra2Snapshot(), config: .qcUltra2)

    #expect(state.modelName == "QC Ultra 2")
    #expect(state.cnc?.range == 0...10)
    #expect(state.cnc?.wireValue == 5)
    #expect(state.ancEnabled == true)
    #expect(state.windReduction == false)
    #expect(state.spatial == .head)
    #expect(state.equalizer?.bands.count == 3)
    #expect(state.equalizer?.bands.map(\.value) == [0, -2, -6])
    #expect(state.audioModes?.selectedSlot == 0)
    // Sidetone is withheld even when the snapshot carries one: it has no wire mapping, so
    // the control could be moved but would never reach the device.
    #expect(state.sidetone == nil)
    #expect(state.isControllable)
    #expect(state.acceptsWrites)
  }

  @Test("CNC range and value come from the [1.5] reading when present")
  func cncFromNoiseCancellationReading() {
    let snapshot = BoseDeviceSnapshot(
      noiseCancellation: BmapNoiseCancellationReading(
        currentStep: 3, maximumStep: 8, isEnabled: true, rawFlags: 0x03
      )
    )
    let state = BosePanelState.project(from: snapshot, config: .qcUltra2)
    #expect(state.cnc?.range == 0...8)
    #expect(state.cnc?.wireValue == 3)
  }

  @Test("CNC falls back to the [31.10] value and 0...10 range when [1.5] is absent")
  func cncFallbackToLiveWrite() {
    let snapshot = BoseDeviceSnapshot(
      liveNoiseControl: BmapNoiseControlSetting(
        cnc: 7, spatial: .off, windBlock: true, ancEnabled: false
      )
    )
    let state = BosePanelState.project(from: snapshot, config: .qcUltra2)
    #expect(state.cnc?.range == 0...10)
    #expect(state.cnc?.wireValue == 7)
  }

  @Test("A QC35 config hides the Ultra-2-only features even if the snapshot carries them")
  func qc35HidesUltra2Features() {
    // The snapshot happens to carry EQ, live control, and modes; a QC35 config must still
    // hide them, because the model does not expose those blocks.
    let state = BosePanelState.project(from: ultra2Snapshot(), config: .qc35)

    #expect(state.equalizer == nil)
    #expect(state.ancEnabled == nil)
    #expect(state.windReduction == nil)
    #expect(state.spatial == nil)
    #expect(state.audioModes == nil)
    // CNC is still readable on QC35 ([1.5] is in its feature set).
    #expect(state.cnc?.wireValue == 5)
  }

  @Test("The earbuds config hides wind reduction while keeping the rest of the family")
  func earbudsHideWindReduction() {
    // The snapshot carries a wind byte (as the [31.10] block always does), but the earbuds
    // do not physically have the feature, so their config withholds the switch while ANC,
    // CNC, and spatial — which share the block — stay.
    let state = BosePanelState.project(from: ultra2Snapshot(), config: .qcUltra2Earbuds)

    #expect(state.windReduction == nil)
    #expect(state.ancEnabled == true)
    #expect(state.spatial == .head)
    #expect(state.cnc?.wireValue == 5)
  }

  @Test("An empty snapshot hides every feature")
  func emptySnapshotHidesEverything() {
    let state = BosePanelState.project(from: BoseDeviceSnapshot(), config: .qcUltra2)
    #expect(state.cnc == nil)
    #expect(state.ancEnabled == nil)
    #expect(state.windReduction == nil)
    #expect(state.equalizer == nil)
    #expect(state.audioModes == nil)
    #expect(state.spatial == nil)
    #expect(state.sidetone == nil)
    #expect(state.battery == .unknown)
  }

  @Test("A single battery component is the whole-headset figure")
  func singleBattery() {
    let snapshot = BoseDeviceSnapshot(
      battery: [BmapBatteryComponent(percent: 42, minutesRemaining: nil, componentId: 0)]
    )
    let state = BosePanelState.project(from: snapshot, config: .qcUltra2)
    #expect(state.battery.cells.count == 1)
    #expect(state.battery.cells.first?.enclosure == .single)
    #expect(state.battery.cells.first?.percent == 42)
  }

  @Test("Several battery components become PII-free numbered slots")
  func multipleBattery() {
    let snapshot = BoseDeviceSnapshot(
      battery: [
        BmapBatteryComponent(percent: 90, minutesRemaining: nil, componentId: 1),
        BmapBatteryComponent(percent: 70, minutesRemaining: nil, componentId: 2),
        BmapBatteryComponent(percent: 55, minutesRemaining: nil, componentId: 3),
      ]
    )
    let state = BosePanelState.project(from: snapshot, config: .qcUltra2)
    #expect(state.battery.cells.count == 3)
    #expect(state.battery.cells.map(\.enclosure) == [.other(index: 0), .other(index: 1), .other(index: 2)])
    #expect(state.battery.cells.map(\.percent) == [90, 70, 55])
  }
}
