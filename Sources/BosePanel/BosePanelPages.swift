import BoseCore
import SwiftUI

/// The gestures a page can drive, gathered so a page carries one value rather than a
/// fistful of loose closures. Each maps to a `BosePanelModel` command.
public struct BosePanelActions {
  /// CNC drag, in UI *strength* terms (higher = quieter); `isFinal` on release.
  public var dragCNCStrength: (Int, Bool) -> Void
  public var setANC: (Bool) -> Void
  public var setWind: (Bool) -> Void
  /// EQ band drag by band id, in gain terms; `isFinal` on release.
  public var dragEqualizerBand: (UInt8, Int, Bool) -> Void
  public var selectMode: (Int) -> Void
  public var setSpatial: (BmapNoiseControlSetting.Spatial) -> Void
  public var setSidetone: (BoseSidetone) -> Void

  public init(
    dragCNCStrength: @escaping (Int, Bool) -> Void = { _, _ in },
    setANC: @escaping (Bool) -> Void = { _ in },
    setWind: @escaping (Bool) -> Void = { _ in },
    dragEqualizerBand: @escaping (UInt8, Int, Bool) -> Void = { _, _, _ in },
    selectMode: @escaping (Int) -> Void = { _ in },
    setSpatial: @escaping (BmapNoiseControlSetting.Spatial) -> Void = { _ in },
    setSidetone: @escaping (BoseSidetone) -> Void = { _ in }
  ) {
    self.dragCNCStrength = dragCNCStrength
    self.setANC = setANC
    self.setWind = setWind
    self.dragEqualizerBand = dragEqualizerBand
    self.selectMode = selectMode
    self.setSpatial = setSpatial
    self.setSidetone = setSidetone
  }
}

/// The Bose pages in display order. One source both the pager (dot count) and the view
/// follow.
public enum BosePanelPageID: String, CaseIterable, Sendable {
  case noise
  case equalizer
  case modes
  case extras
}

// MARK: - Noise page

/// The noise page: one continuous CNC slider (Aware ⇄ Quiet), then the two independent
/// switches — ANC and wind reduction. The CNC slider is shown in *strength* terms so
/// dragging toward Quiet cancels more, hiding the wire's inversion behind honest labels.
struct BoseNoisePage: View {
  let state: BosePanelState
  let actions: BosePanelActions

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BosePageTitle(text: L("ノイズコントロール", "Noise Control"))

      if state.cnc == nil && state.ancEnabled == nil && state.windReduction == nil {
        BoseNotDeclared(
          text: L(
            "この機器はノイズコントロールを申告していません",
            "This device does not declare noise control"
          )
        )
      } else {
        if let cnc = state.cnc { cncSlider(cnc) }

        VStack(alignment: .leading, spacing: 8) {
          if let anc = state.ancEnabled {
            BoseSwitchRow(
              title: L("ノイズキャンセリング", "Noise Cancelling"),
              isOn: anc,
              set: actions.setANC
            )
            .frame(width: 240)
          }
          if let wind = state.windReduction {
            BoseSwitchRow(
              title: L("風ノイズ低減", "Wind Reduction"),
              isOn: wind,
              set: actions.setWind
            )
            .frame(width: 240)
          }
        }
      }
    }
  }

  /// The blend as one slider between the two audible ends. The end the finger is near is
  /// the one it selects; the wire's inversion (0 = quietest) never surfaces because the
  /// slider is expressed in cancellation strength, which counts the intuitive way.
  private func cncSlider(_ cnc: BoseCNCState) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Text(L("外音", "Aware"))
          .font(.system(size: 8))
          .foregroundStyle(.white.opacity(0.35))
        BoseLevelSlider(
          value: cnc.strength,
          range: cnc.range,
          onChange: { strength, isFinal in actions.dragCNCStrength(strength, isFinal) }
        )
        .frame(height: 14)
        Text(L("静か", "Quiet"))
          .font(.system(size: 8))
          .foregroundStyle(.white.opacity(0.35))
      }
      .frame(width: 300)
    }
  }
}

// MARK: - Equalizer page

/// The three-band EQ: Bass / Mid / Treble named rather than labelled by frequency, since
/// the Ultra 2's three bands are known by name in its own app.
struct BoseEqualizerPage: View {
  let state: BosePanelState
  let actions: BosePanelActions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      BosePageTitle(text: L("イコライザー", "Equalizer"))

      if let equalizer = state.equalizer {
        HStack(spacing: 0) {
          ForEach(equalizer.bands) { band in
            VStack(spacing: 3) {
              Text(gain(band.value))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.white.opacity(band.value == 0 ? 0.35 : 0.8))
              BoseBandSlider(
                value: band.value,
                range: band.range,
                flat: 0,
                onChange: state.acceptsWrites
                  ? { newValue, isFinal in
                    actions.dragEqualizerBand(band.bandId, newValue, isFinal)
                  }
                  : nil
              )
              Text(Self.name(for: band.bandId))
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
          }
        }
        .frame(width: 260)
      } else {
        BoseNotDeclared(
          text: L("この機器はイコライザーを申告していません", "This device does not declare an equalizer")
        )
      }
    }
  }

  private func gain(_ value: Int) -> String {
    value > 0 ? "+\(value)" : "\(value)"
  }

  /// Band names from the frozen spec's band ids (0 Bass, 1 Mid, 2 Treble). An id the
  /// device numbers but this app has no name for falls back to the number, never a guess.
  private static func name(for bandId: UInt8) -> String {
    switch bandId {
    case BmapEqualizer.bassBandId: L("低音", "Bass")
    case BmapEqualizer.midBandId: L("中音", "Mid")
    case BmapEqualizer.trebleBandId: L("高音", "Treble")
    default: "\(bandId)"
    }
  }
}

// MARK: - Modes page

/// The audio modes as a grid of tiles, the selected one filled. Names come from the
/// device; an editable mode carries a small pencil so the ones a user can customise are
/// distinguishable from the presets.
struct BoseModesPage: View {
  let state: BosePanelState
  let actions: BosePanelActions

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      BosePageTitle(text: L("オーディオモード", "Audio Modes"))

      if let audioModes = state.audioModes, !audioModes.modes.isEmpty {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
          spacing: 5
        ) {
          ForEach(audioModes.modes) { mode in
            modeTile(mode, isSelected: mode.slot == audioModes.selectedSlot)
          }
        }
        .frame(width: 300)
      } else {
        BoseNotDeclared(
          text: L("この機器はオーディオモードを申告していません", "This device does not declare audio modes")
        )
      }
    }
  }

  private func modeTile(_ mode: BoseAudioMode, isSelected: Bool) -> some View {
    Button {
      actions.selectMode(mode.slot)
    } label: {
      HStack(spacing: 4) {
        Text(mode.name)
          .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
          .lineLimit(1)
        if mode.isEditable {
          Image(systemName: "pencil")
            .font(.system(size: 7))
            .foregroundStyle(isSelected ? Color.black.opacity(0.5) : Color.white.opacity(0.4))
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Extras page

/// Spatial audio and sidetone together on the last sheet: each a segmented picker, each
/// hidden entirely when the device does not declare it.
struct BoseExtrasPage: View {
  let state: BosePanelState
  let actions: BosePanelActions

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      BosePageTitle(text: L("その他", "More"))

      if state.spatial == nil && state.sidetone == nil {
        BoseNotDeclared(
          text: L(
            "この機器は空間オーディオやサイドトーンを申告していません",
            "This device declares neither spatial audio nor sidetone"
          )
        )
      } else {
        if let spatial = state.spatial { spatialRow(spatial) }
        if let sidetone = state.sidetone { sidetoneRow(sidetone) }
      }
    }
  }

  private func spatialRow(_ spatial: BmapNoiseControlSetting.Spatial) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(L("空間オーディオ", "Spatial Audio"))
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.6))
      HStack(spacing: 5) {
        ForEach(BmapNoiseControlSetting.Spatial.allCases, id: \.self) { option in
          BoseSegmentButton(
            title: Self.spatialLabel(option),
            isSelected: spatial == option,
            fixedWidth: true
          ) {
            actions.setSpatial(option)
          }
          .frame(width: 92)
        }
      }
    }
  }

  private func sidetoneRow(_ sidetone: BoseSidetone) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(L("サイドトーン", "Sidetone"))
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.6))
      HStack(spacing: 5) {
        ForEach(BoseSidetone.allCases, id: \.self) { option in
          BoseSegmentButton(
            title: Self.sidetoneLabel(option),
            isSelected: sidetone == option,
            fixedWidth: true
          ) {
            actions.setSidetone(option)
          }
          .frame(width: 68)
        }
      }
    }
  }

  private static func spatialLabel(_ spatial: BmapNoiseControlSetting.Spatial) -> String {
    switch spatial {
    case .off: L("オフ", "Off")
    case .room: L("固定", "Still")
    case .head: L("ヘッド追従", "Motion")
    }
  }

  private static func sidetoneLabel(_ sidetone: BoseSidetone) -> String {
    switch sidetone {
    case .off: L("オフ", "Off")
    case .high: L("高", "High")
    case .medium: L("中", "Medium")
    case .low: L("低", "Low")
    }
  }
}
