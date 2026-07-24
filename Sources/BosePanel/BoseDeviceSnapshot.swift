import BoseCore
import DeviceContract
import Foundation

/// Everything a session has read back from a Bose device, held as the parsed BoseCore
/// readings rather than raw frames. It is the input the panel state is projected from —
/// the counterpart to the reading bundle Sony's `PanelModel` carries, but Bose-shaped.
///
/// Kept as pure data so the projection (`BosePanelState.project`) is a synchronous,
/// hardware-free function that can be exercised entirely on synthetic fixtures.
public struct BoseDeviceSnapshot: Equatable, Sendable {
  public var modelName: String?
  /// The [2.2] battery components exactly as parsed; the projection decides how to show
  /// one figure versus several.
  public var battery: [BmapBatteryComponent]
  /// [1.5] noise-cancellation reading — the source of the CNC *range* and current value.
  public var noiseCancellation: BmapNoiseCancellationReading?
  /// [31.10] live noise control — ANC, wind, spatial, and a fallback CNC value.
  public var liveNoiseControl: BmapNoiseControlSetting?
  /// [1.7] equalizer bands.
  public var equalizerBands: [BmapEqualizerBand]?
  /// [31.6] audio modes. No BoseCore parser exists yet (the block is partly unresolved),
  /// so this is carried as the UI-level type until stage 6.
  public var audioModes: BoseAudioModes?
  /// Sidetone level. No wire mapping yet; carried at the UI level.
  public var sidetone: BoseSidetone?
  public var isControllable: Bool
  public var acceptsWrites: Bool

  public init(
    modelName: String? = nil,
    battery: [BmapBatteryComponent] = [],
    noiseCancellation: BmapNoiseCancellationReading? = nil,
    liveNoiseControl: BmapNoiseControlSetting? = nil,
    equalizerBands: [BmapEqualizerBand]? = nil,
    audioModes: BoseAudioModes? = nil,
    sidetone: BoseSidetone? = nil,
    isControllable: Bool = false,
    acceptsWrites: Bool = false
  ) {
    self.modelName = modelName
    self.battery = battery
    self.noiseCancellation = noiseCancellation
    self.liveNoiseControl = liveNoiseControl
    self.equalizerBands = equalizerBands
    self.audioModes = audioModes
    self.sidetone = sidetone
    self.isControllable = isControllable
    self.acceptsWrites = acceptsWrites
  }
}

extension BosePanelState {
  /// Projects a device snapshot onto the panel state for a given model config.
  ///
  /// A feature is shown only when the config declares it *and* the snapshot has read it:
  /// the config gates capability (so a QC35 never shows the Ultra-2-only EQ), while the
  /// snapshot gates whether a value has arrived yet. Anything failing either test is nil,
  /// and its page draws the "not declared" line instead of a dead control.
  public static func project(
    from snapshot: BoseDeviceSnapshot,
    config: BoseDeviceConfig
  ) -> BosePanelState {
    BosePanelState(
      modelName: snapshot.modelName,
      battery: batteryReading(from: snapshot.battery),
      cnc: cncState(from: snapshot, config: config),
      ancEnabled: liveField(snapshot, config) { $0.ancEnabled },
      windReduction: liveField(snapshot, config) { $0.windBlock },
      equalizer: equalizerState(from: snapshot, config: config),
      audioModes: config.supportsModeBlock ? snapshot.audioModes : nil,
      spatial: liveField(snapshot, config) { $0.spatial },
      // No config axis names sidetone yet (frozen spec §9 does not list it), so it is
      // gated on the snapshot alone until stage 6 adds one.
      sidetone: snapshot.sidetone,
      isControllable: snapshot.isControllable,
      acceptsWrites: snapshot.acceptsWrites
    )
  }

  /// The CNC range and current value. The range comes from [1.5] (it declares `numSteps`);
  /// when only [31.10] has been read, the protocol-level 0...10 the write layer enforces
  /// is used as the fallback — a BMAP constant, not a model-specific bake-in.
  private static func cncState(
    from snapshot: BoseDeviceSnapshot,
    config: BoseDeviceConfig
  ) -> BoseCNCState? {
    guard config.supports(.noiseCancellationRead) || config.supports(.noiseControlLiveWrite)
    else { return nil }

    if let reading = snapshot.noiseCancellation, config.supports(.noiseCancellationRead) {
      let maximum = max(reading.maximumStep, 0)
      return BoseCNCState(range: 0...maximum, wireValue: reading.currentStep)
    }
    if let live = snapshot.liveNoiseControl, config.supports(.noiseControlLiveWrite) {
      return BoseCNCState(range: liveWriteCNCRange, wireValue: live.cnc)
    }
    return nil
  }

  /// The [31.10] documented CNC range, used only as a fallback when [1.5] has not been
  /// read. Not model-specific — it is the range the BMAP write layer itself enforces.
  private static let liveWriteCNCRange = 0...10

  /// Reads one field off the [31.10] live control, but only when the config declares the
  /// block — so ANC / wind / spatial vanish together on a model without [31.10].
  private static func liveField<T>(
    _ snapshot: BoseDeviceSnapshot,
    _ config: BoseDeviceConfig,
    _ field: (BmapNoiseControlSetting) -> T
  ) -> T? {
    guard config.supports(.noiseControlLiveWrite), let live = snapshot.liveNoiseControl
    else { return nil }
    return field(live)
  }

  private static func equalizerState(
    from snapshot: BoseDeviceSnapshot,
    config: BoseDeviceConfig
  ) -> BoseEqualizerState? {
    guard config.supports(.equalizer), let bands = snapshot.equalizerBands, !bands.isEmpty
    else { return nil }
    return BoseEqualizerState(
      bands: bands.map { band in
        BoseEqualizerBandState(
          bandId: band.bandId,
          range: band.minimum...band.maximum,
          value: band.current
        )
      }
    )
  }

  /// Maps parsed battery components onto the shared reading. A single component is the
  /// whole-headset figure; several become device-numbered slots, kept PII-free by index
  /// (their component ids are device-defined and unverified, so no L/R/case label is
  /// invented here).
  private static func batteryReading(from components: [BmapBatteryComponent]) -> BatteryReading {
    guard !components.isEmpty else { return .unknown }
    if components.count == 1 {
      return BatteryReading(cells: [.init(enclosure: .single, percent: components[0].percent)])
    }
    return BatteryReading(
      cells: components.enumerated().map { index, component in
        .init(enclosure: .other(index: index), percent: component.percent)
      }
    )
  }
}
