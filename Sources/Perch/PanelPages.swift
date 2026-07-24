import SwiftUI
import TandemCore
import TandemSession

/// The feature pages, one per screen of the vertical pager. Each page shows one
/// thing, and every control on them reflects a value read from the device.
@MainActor
enum PanelPages {
  /// Device-independent sheets live to the LEFT of the device sheets, so they are
  /// reachable even with nothing connected. The device sheets follow. The one source
  /// `count`, `homeIndex` and `all` all agree on, so the pager is built with the right
  /// number of stops before the pages themselves exist.
  static let commonPageIDs = ["spatial"]
  static let devicePageIDs = ["noise", "equalizer", "listening", "speakToChat"]
  static let pageIDs = commonPageIDs + devicePageIDs
  static var count: Int { pageIDs.count }
  /// The first device sheet — the panel's home, shown on open whether or not a device
  /// is connected. The common sheets sit to its left (index 0 … homeIndex-1).
  static var homeIndex: Int { commonPageIDs.count }

  static func all(
    spatial: SpatialAudioController,
    equalizer: EqualizerReading?,
    noiseControl: NoiseControlReading?,
    listeningMode: TandemListeningReading?,
    applyNoiseControl: @escaping (TandemNoiseControlState) -> Void,
    dragNoiseLevel: @escaping (Int, Bool) -> Void,
    applyListening: @escaping (TandemListeningSelection) -> Void,
    applyEqualizerPreset: @escaping (UInt8) -> Void,
    dragEqualizerBand: @escaping (Int, Int, Bool) -> Void,
    speakToChat: SpeakToChatReading?,
    applySpeakToChat: @escaping (Bool) -> Void,
    applySpeakToChatDetail: @escaping (TandemSpeakToChatSensitivity, TandemSpeakToChatTimeout) -> Void,
    sidetone: SidetoneReading?,
    applySidetone: @escaping (Bool) -> Void
  ) -> [PanelPage] {
    let common = [
      PanelPage(id: "spatial", isCommon: true, content: AnyView(SpatialAudioPage(controller: spatial))),
    ]
    let devicePages = [
      PanelPage(id: "noise", content: AnyView(NoiseControlPage(reading: noiseControl, apply: applyNoiseControl, dragLevel: dragNoiseLevel))),
      PanelPage(id: "equalizer", content: AnyView(EqualizerPage(
        equalizer: equalizer,
        listeningActive: listeningMode?.disablesEqualizer ?? false,
        applyPreset: applyEqualizerPreset,
        dragBand: dragEqualizerBand
      ))),
      PanelPage(id: "listening", content: AnyView(ListeningModePage(reading: listeningMode, apply: applyListening))),
      PanelPage(id: "speakToChat", content: AnyView(SpeakToChatPage(
        speakToChat: speakToChat,
        applySpeakToChat: applySpeakToChat,
        applySpeakToChatDetail: applySpeakToChatDetail,
        sidetone: sidetone,
        applySidetone: applySidetone
      ))),
    ]
    let pages = common + devicePages
    assert(pages.map(\.id) == pageIDs, "the built pages must follow pageIDs")
    return pages
  }
}

/// The first common (device-independent) sheet: system-wide spatial audio. It captures
/// the Mac's own audio and spreads it outside the head, so nothing here depends on the
/// connected model. Needs macOS 14.4+ (Core Audio taps); older systems say so.
private struct SpatialAudioPage: View {
  @ObservedObject var controller: SpatialAudioController

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      PageTitle(text: L("空間オーディオ", "Spatial Audio"))

      if controller.isAvailable {
        SwitchRow(
          title: L("空間オーディオ", "Spatial Audio"),
          isOn: controller.isEnabled
        ) { controller.setEnabled($0) }

        // The refinements only matter once it is on.
        if controller.isEnabled {
          SwitchRow(title: L("自動バランス", "Auto balance"), isOn: controller.autoBalance) {
            controller.autoBalance = $0
          }
          SwitchRow(title: L("ゆらぎ", "Movement"), isOn: controller.wander) {
            controller.wander = $0
          }
          SwitchRow(title: L("拍に反応", "Beat reactive"), isOn: controller.beat) {
            controller.beat = $0
          }
        }

        if let error = controller.errorMessage {
          Text(error)
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            L(
              "システム全体の音を頭の外へ広げます。機種に依存しません。",
              "Spreads all system audio outside your head. Works with any device."
            )
          )
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text(
          L(
            "空間オーディオは macOS 14.4 以降が必要です。",
            "Spatial Audio requires macOS 14.4 or later."
          )
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.5))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct PageTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.white.opacity(0.45))
  }
}

/// One tile width for every stacked-tile sheet, so the columns line up page to page.
private enum TileMetrics {
  static let width: CGFloat = 150
}

private struct NoiseControlPage: View {
  let reading: NoiseControlReading?
  let apply: (TandemNoiseControlState) -> Void
  let dragLevel: (Int, Bool) -> Void

  private var isAmbient: Bool {
    guard let reading else { return false }
    return reading.state.isActive && !reading.state.isNoiseCancelling
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      PageTitle(text: L("ノイズコントロール", "Noise Control"))

      if let reading {
        // Only the modes this dialect actually has. An ambient-only or on/off-only
        // function must not show a mode it cannot switch to, since selecting it would
        // send a state outside what the function defines. Voice focus is a variation of
        // ambient sound, not a fourth peer, so it lives beside the ambient tile.
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Self.modes(for: reading), id: \.title) { mode in
            HStack(spacing: 12) {
              SegmentButton(
                title: mode.title,
                isSelected: mode.isSelected(reading.state),
                fixedWidth: true
              ) {
                apply(mode.target(reading))
              }
              .frame(width: TileMetrics.width)

              // The ambient controls sit on the ambient tile's own row: the level and
              // voice focus qualify that mode, so they live beside it, not below all
              // the tiles. The row clips at its own leading edge, so the controls
              // surface from behind the tile instead of travelling across it.
              ZStack(alignment: .leading) {
                if mode.requires == .ambient, isAmbient {
                  ambientControls(reading)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
              }
              .clipped()
            }
          }
        }
      } else {
        Text(
          L(
            "この機器はノイズコントロールを申告していません",
            "This device does not declare noise control"
          )
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .animation(.easeOut(duration: 0.18), value: isAmbient)
  }

  /// The controls that belong to ambient sound: the loudness of the outside world,
  /// and whether voices are emphasised within it. One row, laid along the ambient
  /// tile they qualify.
  @ViewBuilder
  private func ambientControls(_ reading: NoiseControlReading) -> some View {
    let range = reading.range(for: reading.state.ambientMode)
    HStack(spacing: 12) {
      if reading.hasAdjustableLevel {
        HStack(spacing: 8) {
          Text("\(range.lowerBound)")
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.white.opacity(0.35))
          LevelSlider(value: reading.state.ambientLevel, range: range, onChange: dragLevel)
            .frame(width: 130, height: 14)
          Text("\(reading.state.ambientLevel)")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
            // Sized by the range the device declared: a dialect whose scale reaches
            // three digits gets the extra points instead of wrapping.
            .frame(width: range.upperBound >= 100 ? 24 : 18, alignment: .leading)
        }
      }

      // Only offered when the device actually has the voice-focused mode.
      if reading.supportsVoiceFocus {
        Toggle(
          L("声にフォーカス", "Focus on voice"),
          isOn: Binding(
            get: { reading.state.ambientMode == 1 },
            set: { apply(Self.ambientTarget(mode: $0 ? 1 : 0, reading)) }
          )
        )
        .toggleStyle(PanelSwitchStyle(width: 26))
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.75))
        .fixedSize()
      }
    }
  }


  // MARK: - Targets

  enum Requirement { case noiseCancelling, ambient, off }

  struct Mode {
    let title: String
    let requires: Requirement
    let isSelected: (TandemNoiseControlState) -> Bool
    let target: (NoiseControlReading) -> TandemNoiseControlState
  }

  /// The modes the device's dialect actually offers. Off is always present; noise
  /// cancelling and ambient appear only when the function supports them.
  private static func modes(for reading: NoiseControlReading) -> [Mode] {
    allModes.filter { mode in
      switch mode.requires {
      case .noiseCancelling: reading.supportsNoiseCancelling
      case .ambient: reading.supportsAmbient
      case .off: true
      }
    }
  }

  // Computed rather than stored: a stored `static let` would bake the titles in the
  // language of first use and never follow a switch.
  private static var allModes: [Mode] {
    [
      Mode(
        title: L("ノイズキャンセリング", "Noise Cancelling"),
        requires: .noiseCancelling,
        isSelected: { $0.isActive && $0.isNoiseCancelling },
        target: { current in
          TandemNoiseControlState(
            isActive: true,
            isNoiseCancelling: true,
            ambientMode: current.state.ambientMode,
            ambientLevel: current.state.ambientLevel,
            noiseAdaptation: current.state.noiseAdaptation
          )
        }
      ),
      Mode(
        title: L("外音取り込み", "Ambient Sound"),
        requires: .ambient,
        isSelected: { $0.isActive && !$0.isNoiseCancelling },
        // Entering ambient keeps whatever focus mode was last used, rather than
        // forcing it back to plain every time.
        target: { current in ambientTarget(mode: current.state.ambientMode, current) }
      ),
      Mode(
        title: L("オフ", "Off"),
        requires: .off,
        isSelected: { !$0.isActive },
        target: { current in
          TandemNoiseControlState(
            isActive: false,
            isNoiseCancelling: false,
            ambientMode: current.state.ambientMode,
            ambientLevel: current.state.ambientLevel,
            noiseAdaptation: current.state.noiseAdaptation
          )
        }
      ),
    ]
  }

  /// Ambient sound at a given focus mode, keeping the level already set for it so the
  /// loudness does not jump when the focus is toggled.
  private static func ambientTarget(mode: UInt8, _ reading: NoiseControlReading) -> TandemNoiseControlState {
    let range = reading.range(for: mode)
    let level = reading.state.ambientMode == mode
      ? reading.state.ambientLevel
      : min(max(reading.state.ambientLevel, range.lowerBound), range.upperBound)
    return TandemNoiseControlState(
      isActive: true,
      isNoiseCancelling: false,
      ambientMode: mode,
      ambientLevel: level,
      noiseAdaptation: reading.state.noiseAdaptation
    )
  }
}

private struct EqualizerPage: View {
  let equalizer: EqualizerReading?
  /// A listening mode is running, so the device has the equaliser switched off.
  let listeningActive: Bool
  let applyPreset: (UInt8) -> Void
  let dragBand: (Int, Int, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PageTitle(text: L("イコライザー", "Equalizer"))

      if listeningActive {
        Text(
          L(
            "リスニングモード中はイコライザーは無効です",
            "The equalizer is disabled while a listening mode is active"
          )
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.5))
      } else if let equalizer {
        // The presets as a three-wide grid of equal tiles beside the bands, rather
        // than one long scrolling row. A model listing more presets than the grid can
        // show scrolls vertically within its column.
        HStack(alignment: .top, spacing: 12) {
          presetGrid(equalizer)
          // The bands own whatever width the grid leaves, spreading evenly: five
          // sliders sit as comfortably as ten.
          BandRow(equalizer: equalizer, dragBand: equalizer.canEditBands ? dragBand : nil)
            .frame(maxWidth: .infinity)
        }
      } else {
        Text(
          L("この機器はイコライザーを申告していません", "This device does not declare an equalizer")
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
  }

  private func presetGrid(_ equalizer: EqualizerReading) -> some View {
    // Past three rows the grid trades a little tile height for staying on the sheet.
    let compact = equalizer.presets.count > 9
    return ScrollView(.vertical, showsIndicators: false) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
        spacing: compact ? 3 : 4
      ) {
        ForEach(equalizer.presets) { preset in
          SegmentButton(
            title: PresetDisplay.label(for: preset.identifier),
            isSelected: preset.identifier == equalizer.selectedPreset,
            fixedWidth: true,
            compact: compact
          ) {
            applyPreset(preset.identifier)
          }
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(width: 220)
  }

}

/// The listening-mode picker: Standard plus whichever modes the device declared. A
/// background-music mode reveals its rooms; cinema is a plain choice. Nothing here is
/// specific to a model — the buttons follow the device's declared features, and a model
/// that declares none says so rather than showing an empty picker.
private struct ListeningModePage: View {
  let reading: TandemListeningReading?
  let apply: (TandemListeningSelection) -> Void

  private var isBackgroundMusic: Bool {
    if case .backgroundMusic = reading?.selection { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PageTitle(text: L("リスニングモード", "Listening Mode"))

      if let reading, !reading.features.isEmpty {
        // The modes as one left-aligned column of equal tiles, matching the noise
        // sheet. The rooms qualify BGM, so they slide out beside its tile rather
        // than appearing under the whole column.
        VStack(alignment: .leading, spacing: 5) {
          SegmentButton(
            title: L("標準", "Standard"),
            isSelected: reading.selection == .standard,
            fixedWidth: true
          ) {
            apply(.standard)
          }
          .frame(width: TileMetrics.width)

          if reading.hasBackgroundMusic {
            HStack(spacing: 12) {
              // "BGM" reads naturally only in Japanese; English speakers know the
              // mode by its full name.
              SegmentButton(
                title: L("BGM", "Background Music"),
                isSelected: isBackgroundMusic,
                fixedWidth: true
              ) {
                apply(.backgroundMusic(reading.savedRoom))
              }
              .frame(width: TileMetrics.width)

              // Clipped at its own leading edge, so the rooms surface from behind
              // the BGM tile instead of travelling across it.
              ZStack(alignment: .leading) {
                if isBackgroundMusic {
                  HStack(spacing: 5) {
                    ForEach(TandemListeningRoom.allCases, id: \.self) { room in
                      SegmentButton(
                        title: Self.roomLabel(room),
                        isSelected: reading.selection == .backgroundMusic(room),
                        fixedWidth: true
                      ) {
                        apply(.backgroundMusic(room))
                      }
                      .frame(width: 88)
                    }
                  }
                  .transition(.opacity.combined(with: .move(edge: .leading)))
                }
              }
              .clipped()
            }
          }

          if reading.hasCinema {
            SegmentButton(
              title: L("シネマ", "Cinema"),
              isSelected: reading.selection == .cinema,
              fixedWidth: true
            ) {
              apply(.cinema)
            }
            .frame(width: TileMetrics.width)
          }
        }
      } else {
        Text(
          L(
            "この機器はリスニングモードを申告していません",
            "This device does not declare listening modes"
          )
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .animation(.easeOut(duration: 0.18), value: isBackgroundMusic)
  }

  /// The room the background-music mode simulates. The device sends only the raw
  /// small/middle/large value, so the friendly names — which it does not carry — are
  /// supplied here, matching how the official app labels the same three rooms.
  private static func roomLabel(_ room: TandemListeningRoom) -> String {
    switch room {
    case .small: L("マイルーム", "My Room")
    case .middle: L("リビング", "Living Room")
    case .large: L("カフェ", "Cafe")
    }
  }
}

/// One column per band the device declared, labelled with the frequency it reported
/// and the gain in decibels either side of flat. When the device has a custom preset,
/// each band is draggable; otherwise the sliders are read-only.
private struct BandRow: View {
  let equalizer: EqualizerReading
  /// (bandIndex, step, isFinal). Nil when the device declares no editable preset.
  let dragBand: ((Int, Int, Bool) -> Void)?

  var body: some View {
    HStack(spacing: 0) {
      ForEach(visibleBands, id: \.self) { index in
        VStack(spacing: 3) {
          Text(Self.gain(equalizer.decibels(atBand: index)))
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(
              .white.opacity(equalizer.bandSteps[index] == equalizer.flatStep ? 0.35 : 0.8)
            )
          BandSlider(
            step: equalizer.bandSteps[index],
            range: equalizer.stepRange,
            flat: equalizer.flatStep,
            onChange: dragBand.map { drag in { newStep, isFinal in drag(index, newStep, isFinal) } }
          )
          Text(Self.frequency(equalizer.bandFrequencies.indices.contains(index)
            ? equalizer.bandFrequencies[index] : 0))
            .font(.system(size: 7))
            .foregroundStyle(.white.opacity(0.4))
        }
        // Columns share the row evenly, so the sliders spread across whatever width
        // the sheet gives them instead of huddling at the left.
        .frame(maxWidth: .infinity)
      }
    }
  }

  /// A band with no frequency, sitting beside bands that have one, is a slot the
  /// device reports but does not let anyone set — the older generation's first slot,
  /// as found on hardware. When no band has a frequency (a device whose extended
  /// info never answered), nothing is hidden: unlabelled is not the same as unreal.
  private var visibleBands: [Int] {
    let frequencies = equalizer.bandFrequencies
    guard frequencies.contains(where: { $0 > 0 }) else {
      return Array(equalizer.bandSteps.indices)
    }
    return equalizer.bandSteps.indices.filter {
      frequencies.indices.contains($0) && frequencies[$0] > 0
    }
  }

  private static func gain(_ decibels: Int) -> String {
    decibels > 0 ? "+\(decibels)" : "\(decibels)"
  }

  private static func frequency(_ hertz: Int) -> String {
    guard hertz > 0 else { return "—" }
    return hertz >= 1000 ? "\(hertz / 1000)k" : "\(hertz)"
  }
}

/// A plain vertical slider: one thin track, one knob whose height is the value. The
/// knob rides where the finger is, top is boost, bottom is cut — nothing about it has
/// to be learned. A faint tick still marks flat so zero is findable at a glance.
private struct BandSlider: View {
  let step: Int
  let range: ClosedRange<Int>
  let flat: Int
  let onChange: ((Int, Bool) -> Void)?

  private static let height: CGFloat = 58
  private static let knob: CGFloat = 11

  var body: some View {
    let span = max(range.upperBound - range.lowerBound, 1)
    let fraction = Double(step - range.lowerBound) / Double(span)
    let travel = Self.height - Self.knob
    let flatFraction = Double(flat - range.lowerBound) / Double(span)

    ZStack(alignment: .top) {
      Capsule()
        .fill(.white.opacity(0.12))
        .frame(width: 3)
      // The flat mark, so returning a band to zero needs no reading of numbers.
      Rectangle()
        .fill(.white.opacity(0.3))
        .frame(width: 9, height: 1)
        .offset(y: Self.knob / 2 + (1 - flatFraction) * travel)
      Circle()
        .fill(.white.opacity(onChange == nil ? 0.45 : 0.95))
        .frame(width: Self.knob, height: Self.knob)
        .offset(y: (1 - fraction) * travel)
    }
    .frame(width: 20, height: Self.height)
    .contentShape(Rectangle())
    .gesture(drag)
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { report($0.location.y, isFinal: false) }
      .onEnded { report($0.location.y, isFinal: true) }
  }

  private func report(_ y: CGFloat, isFinal: Bool) {
    guard let onChange else { return }
    // Top of the track is the highest step; invert because the y-axis grows downward.
    let travel = Self.height - Self.knob
    let fraction = 1 - min(max((y - Self.knob / 2) / travel, 0), 1)
    let span = range.upperBound - range.lowerBound
    let newStep = range.lowerBound + Int((Double(span) * Double(fraction)).rounded())
    onChange(min(max(newStep, range.lowerBound), range.upperBound), isFinal)
  }
}

/// Speak-to-chat and call-time sidetone on the last sheet: the switches, and — while
/// speak-to-chat is on — its sensitivity and auto-off choices. Everything shown is
/// read from the device; a device that declares neither feature says so instead.
private struct SpeakToChatPage: View {
  let speakToChat: SpeakToChatReading?
  let applySpeakToChat: (Bool) -> Void
  let applySpeakToChatDetail: (TandemSpeakToChatSensitivity, TandemSpeakToChatTimeout) -> Void
  let sidetone: SidetoneReading?
  let applySidetone: (Bool) -> Void

  /// The sidetone switch value, present only when the device declared the setting as
  /// a boolean it can draw a switch for.
  private var sidetoneEnabled: Bool? { sidetone?.isEnabled }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PageTitle(text: L("通話・会話", "Calls & Conversation"))

      if speakToChat != nil || sidetoneEnabled != nil {
        // Two fifths for the switches, three for the settings: the switch labels need
        // less room than the timeout row, so the split leans right. The reader is
        // given its height explicitly — outside the notch's fixed slot (the settings
        // window's scrolling cards) it would otherwise collapse.
        GeometryReader { proxy in
          let spacing: CGFloat = 14
          let fifth = (proxy.size.width - spacing) / 5
          HStack(alignment: .top, spacing: spacing) {
            VStack(alignment: .leading, spacing: 10) {
              if let speakToChat {
                SwitchRow(
                  title: L("スピーク・トゥ・チャット", "Speak-to-Chat"),
                  isOn: speakToChat.isEnabled
                ) { value in
                  applySpeakToChat(value)
                }
              }

              // Only shown when the device's general-setting declaration named
              // sidetone; while the device reports the control as disabled, the
              // switch shows the value but cannot be flipped.
              if let sidetone, let sidetoneEnabled {
                // Worded to fit the settings card's narrower switch column in one
                // piece; the longer phrasing was ellipsised there.
                SwitchRow(
                  title: L("通話中に自分の声を聞く", "Hear your own voice on calls"),
                  isOn: sidetoneEnabled
                ) { value in
                  applySidetone(value)
                }
                .disabled(!sidetone.isControlEnabled)
                .opacity(sidetone.isControlEnabled ? 1 : 0.45)
              }
            }
            .frame(width: fifth * 2, alignment: .topLeading)

            // Clipped at its own leading edge, so the settings surface from the split
            // instead of travelling across the switches.
            ZStack(alignment: .topLeading) {
              if let speakToChat, speakToChat.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                  HStack(spacing: 6) {
                    ForEach(Self.sensitivities, id: \.value) { entry in
                      SegmentButton(title: entry.title, isSelected: speakToChat.sensitivity == entry.value) {
                        applySpeakToChatDetail(entry.value, speakToChat.timeout)
                      }
                    }
                  }
                  HStack(spacing: 6) {
                    ForEach(Self.timeouts(speakToChat.capability), id: \.value) { entry in
                      SegmentButton(title: entry.title, isSelected: speakToChat.timeout == entry.value) {
                        applySpeakToChatDetail(speakToChat.sensitivity, entry.value)
                      }
                    }
                  }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
              }
            }
            .frame(width: fifth * 3, alignment: .topLeading)
            .clipped()
          }
        }
        .frame(height: 54)
      } else {
        Text(
          L(
            "この機器はスピーク・トゥ・チャットやサイドトーンを申告していません",
            "This device declares neither Speak-to-Chat nor sidetone"
          )
        )
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .animation(.easeOut(duration: 0.18), value: speakToChat?.isEnabled ?? false)
  }

  // Computed rather than stored: a stored `static let` would bake the titles in the
  // language of first use and never follow a switch.
  private static var sensitivities: [(value: TandemSpeakToChatSensitivity, title: String)] {
    [
      (.automatic, L("自動", "Auto")),
      (.high, L("高", "High")),
      (.low, L("低", "Low")),
    ]
  }

  /// The auto-off choices, labelled with the seconds the device reported plus a
  /// keep-open option.
  private static func timeouts(
    _ capability: TandemSpeakToChatCapability
  ) -> [(value: TandemSpeakToChatTimeout, title: String)] {
    [
      (.fast, "\(capability.fastSeconds)\(L("秒", "s"))"),
      (.medium, "\(capability.mediumSeconds)\(L("秒", "s"))"),
      (.slow, "\(capability.slowSeconds)\(L("秒", "s"))"),
      (.none, L("解除まで", "No limit")),
    ]
  }
}

private struct SwitchRow: View {
  let title: String
  let isOn: Bool
  let set: (Bool) -> Void

  var body: some View {
    Toggle(title, isOn: Binding(get: { isOn }, set: { set($0) }))
      .toggleStyle(PanelSwitchStyle(width: 30))
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.85))
  }
}

/// A switch drawn with its own colours. The stock switch takes its tint from the
/// window's key state, and the notch panel never becomes key, so on and off rendered
/// almost identically there — blue only while the panel happened to be interacted
/// with. This one is unmistakably blue whenever it is on.
private struct PanelSwitchStyle: ToggleStyle {
  var width: CGFloat = 30

  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: 6) {
        configuration.label
        // Grows when the row is given width, so stacked switches share one right
        // edge; hugged rows (fixedSize) collapse it and keep the label-side gap.
        Spacer(minLength: 0)
        Capsule()
          .fill(configuration.isOn ? Color.blue : Color.white.opacity(0.25))
          .frame(width: width, height: width * 0.58)
          .overlay(alignment: configuration.isOn ? .trailing : .leading) {
            Circle()
              .fill(.white)
              .padding(1.5)
          }
          .animation(.easeOut(duration: 0.15), value: configuration.isOn)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct SegmentButton: View {
  let title: String
  let isSelected: Bool
  var fixedWidth = true
  /// A slightly shorter tile, for grids that would otherwise outgrow the sheet.
  var compact = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 3 : 5)
        .frame(maxWidth: fixedWidth ? .infinity : nil)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
        )
    }
    .buttonStyle(.plain)
  }
}

/// A slider drawn to be legible on the panel's black background, where the stock
/// control renders as a bare knob with no visible track. Driven directly by a drag
/// gesture so the value follows the pointer and reports its final position on release.
private struct LevelSlider: View {
  let value: Int
  let range: ClosedRange<Int>
  let onChange: (Int, Bool) -> Void

  private static let knob: CGFloat = 12

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let span = max(range.upperBound - range.lowerBound, 1)
      let fraction = Double(value - range.lowerBound) / Double(span)
      let knob = Self.knob

      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.15)).frame(height: 4)
        // The fill tracks the knob's centre, so track and knob agree at both ends.
        Capsule()
          .fill(.white.opacity(0.85))
          .frame(width: knob / 2 + CGFloat(fraction) * (width - knob), height: 4)
        Circle()
          .fill(.white)
          .frame(width: knob, height: knob)
          .offset(x: CGFloat(fraction) * (width - knob))
      }
      .frame(height: knob)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in report(gesture.location.x, width: width, isFinal: false) }
          .onEnded { gesture in report(gesture.location.x, width: width, isFinal: true) }
      )
    }
  }

  /// The pointer is mapped through the same geometry the knob is drawn with — its
  /// centre travels `knob/2 … width - knob/2` — so the value under the pointer is the
  /// value the knob lands on, with no half-knob offset at the ends.
  private func report(_ x: CGFloat, width: CGFloat, isFinal: Bool) {
    let span = range.upperBound - range.lowerBound
    let travel = max(width - Self.knob, 1)
    let fraction = min(max((x - Self.knob / 2) / travel, 0), 1)
    let level = range.lowerBound + Int((Double(span) * Double(fraction)).rounded())
    onChange(level, isFinal)
  }
}
