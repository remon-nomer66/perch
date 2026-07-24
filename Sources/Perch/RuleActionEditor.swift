import SwiftUI
import TandemSession

/// The three things a rule can change — noise control, equaliser preset, listening mode —
/// as pickers that apply each choice to the connected device at once, so a rule can be
/// judged by ear while it is written. Shared by the site/app editor and the music editor.
struct RuleActionEditor: View {
  @ObservedObject var model: AppModel
  let service: SessionService
  @Binding var noise: SoundRule.NoiseAction
  /// -1 keeps the equaliser; anything else is a preset identifier.
  @Binding var preset: Int
  @Binding var listening: SoundRule.ListeningAction

  private var presetChoices: [UInt8] {
    model.panel.equalizer?.presets.map(\.identifier) ?? []
  }

  private var listeningBlocksEqualizer: Bool {
    listening == .backgroundMusic || listening == .cinema
  }

  var body: some View {
    Text(
      L(
        "選んだ設定はその場で機器に反映され、聴きながら選べます。ルールを追加すると元の設定に戻ります。",
        "Choices are applied to the device right away, so they can be judged by ear. "
          + "Adding the rule puts the previous settings back."
      )
    )
    .font(.system(size: 11))
    .foregroundStyle(.secondary)

    Picker(L("ノイキャン", "Noise control"), selection: $noise) {
      ForEach(SoundRule.NoiseAction.allCases, id: \.self) { action in
        Text(RuleDisplay.noiseLabel(action)).tag(action)
      }
    }
    .onChange(of: noise) { _, value in
      model.previewNoise(value, using: service)
    }

    // Preset choices are what the connected device declared. While the rule also puts
    // the device into BGM or cinema, the device itself switches the equaliser off, so
    // the two cannot be asked for together.
    Picker(L("イコライザー", "Equalizer"), selection: $preset) {
      Text(L("そのまま", "Keep")).tag(-1)
      ForEach(presetChoices, id: \.self) { identifier in
        Text(PresetDisplay.label(for: identifier)).tag(Int(identifier))
      }
    }
    .onChange(of: preset) { _, value in
      model.previewEqualizerPreset(value, using: service)
    }
    .disabled(listeningBlocksEqualizer)
    if listeningBlocksEqualizer {
      Text(
        L(
          "BGM・シネマ中は機器側でイコライザーが無効になるため、同時には指定できません。",
          "The device disables its equalizer during BGM and Cinema, so the two cannot be set together."
        )
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }

    Picker(L("リスニングモード", "Listening mode"), selection: $listening) {
      ForEach(SoundRule.ListeningAction.allCases, id: \.self) { action in
        Text(RuleDisplay.listeningLabel(action)).tag(action)
      }
    }
    .onChange(of: listening) { _, value in
      if value == .backgroundMusic || value == .cinema { preset = -1 }
      model.previewListening(value, using: service)
    }
  }
}
