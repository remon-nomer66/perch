import SwiftUI
import TandemSession

/// The "音楽" tab: rules that follow the artist being listened to. The artist is read
/// from a playing player (Spotify or Music) or from a browser tab's title, so a video on
/// the web counts too. A registered name matches when it is anywhere in what is playing —
/// either side of a "feat." included — and an artist rule outranks a site or app rule.
struct MusicRulesView: View {
  @ObservedObject var settings: AppSettingsStore
  @ObservedObject var model: AppModel
  let service: SessionService
  @ObservedObject private var automation = AutomationPermission.shared

  @State private var newArtist = ""
  @State private var newNoise = SoundRule.NoiseAction.keep
  /// -1 keeps the equaliser; anything else is a preset identifier.
  @State private var newPreset = -1
  @State private var newListening = SoundRule.ListeningAction.keep

  /// Only the artist rules; site and app rules live on the "設定" tab.
  private var artistRules: [SoundRule] {
    settings.rules.filter {
      if case .artist = $0.trigger { return true }
      return false
    }
  }

  var body: some View {
    Form {
      Section(L("音楽（アーティスト）ルール", "Music (artist) rules")) {
        Toggle(L("ルールを有効にする", "Enable rules"), isOn: $settings.isRulesEnabled)
        Text(
          L(
            "再生中の曲のアーティストで切り替えます。Spotify・ミュージックの再生情報か、"
              + "ブラウザのタブのタイトルから判定します（YouTube などのウェブ再生も対象。"
              + "タブの判定は実際に音を出しているブラウザに限ります）。"
              + "設定したアーティスト名が含まれていれば適用します（「feat.」のどちらかに入っていてもOK）。"
              + "アーティストのルールはサイトやアプリのルールより優先されます。",
            "Switches by the artist of the playing track, read from Spotify or Music, or "
              + "from a browser tab's title (web playback such as YouTube counts too; tab "
              + "titles only count while that browser is audibly playing). A rule "
              + "applies when its artist name appears in what is playing — either side of a "
              + "\"feat.\" included. Artist rules outrank site and app rules."
          )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

        if automation.playerDenied {
          Label(
            L(
              "ミュージック/Spotify の操作が許可されていません。再生中の判定には、"
                + "システム設定 > プライバシーとセキュリティ > オートメーション から許可してください。",
              "Controlling Music/Spotify is not permitted. For playback detection, allow it "
                + "in System Settings > Privacy & Security > Automation."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11))
          .foregroundStyle(.orange)
        }
        if automation.browserDenied {
          Label(
            L(
              "ブラウザ操作が許可されていません。ウェブ再生のアーティスト判定には、"
                + "システム設定 > プライバシーとセキュリティ > オートメーション から許可してください。",
              "Browser control is not permitted. To read the artist from web playback, allow "
                + "it in System Settings > Privacy & Security > Automation."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11))
          .foregroundStyle(.orange)
        }

        ForEach(Array(artistRules.enumerated()), id: \.element.id) { index, rule in
          RuleRow(
            rule: rule,
            isFirst: index == 0,
            isLast: index == artistRules.count - 1,
            moveUp: { move(rule, by: -1) },
            moveDown: { move(rule, by: 1) },
            delete: { settings.rules.removeAll { $0.id == rule.id } }
          )
        }

        if model.supportsRules {
          newRuleEditor
        } else {
          RuleEditorUnavailableNotice(reason: model.ruleUnavailableReason)
        }
      }
    }
    .formStyle(.grouped)
    .onDisappear { model.endPreview(using: service) }
  }

  @ViewBuilder
  private var newRuleEditor: some View {
    TextField(L("アーティスト名", "Artist name"), text: $newArtist)
      .textFieldStyle(.roundedBorder)

    // New rules are pinned to the connected model: an equaliser preset is that device's
    // own identifier and does not carry to another.
    Text(
      "\(L("対象機種", "Device")): \(model.panel.summary.modelName ?? "—")"
    )
    .font(.system(size: 11))
    .foregroundStyle(.secondary)

    RuleActionEditor(
      model: model,
      service: service,
      noise: $newNoise,
      preset: $newPreset,
      listening: $newListening
    )

    HStack {
      if isDuplicate {
        Text(L("同じアーティストのルールが既にあります。", "A rule for this artist already exists."))
          .font(.system(size: 11))
          .foregroundStyle(.orange)
      }
      Spacer()
      Button(L("ルールを追加", "Add Rule"), action: addRule)
        .disabled(!canAddRule)
    }
  }

  private var trimmedArtist: String {
    newArtist.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One rule per artist *per device*: a new rule is pinned to the connected model, so
  /// the same artist on a different model is a distinct rule, not a duplicate — only the
  /// same artist on the same model collides. The matcher already skips a rule scoped to
  /// another model, so a same-name rule on a different device never fights this one.
  private var isDuplicate: Bool {
    let target = ArtistMatch.normalize(trimmedArtist)
    guard !target.isEmpty else { return false }
    let scope = model.panel.summary.modelName
    return artistRules.contains { rule in
      guard case .artist(let name) = rule.trigger else { return false }
      return ArtistMatch.normalize(name) == target && rule.deviceModel == scope
    }
  }

  private var canAddRule: Bool {
    let hasAction = newNoise != .keep || newPreset >= 0 || newListening != .keep
    return hasAction && !trimmedArtist.isEmpty && !isDuplicate
  }

  private func move(_ rule: SoundRule, by offset: Int) {
    settings.rules = RuleOrdering.moving(
      settings.rules, id: rule.id, by: offset, within: artistRules
    )
  }

  private func addRule() {
    guard !trimmedArtist.isEmpty, !isDuplicate else { return }
    var rule = SoundRule(trigger: .artist(trimmedArtist))
    rule.deviceModel = model.panel.summary.modelName
    rule.noise = newNoise
    rule.equalizerPreset = newPreset >= 0 ? UInt8(newPreset) : nil
    rule.listening = newListening
    settings.rules.append(rule)

    newArtist = ""
    newNoise = .keep
    newPreset = -1
    newListening = .keep
    // The rule is registered; the audition ends and the device goes back to how it was.
    model.endPreview(using: service)
  }
}

/// One rule's row on either rules screen: what it is and what it changes, the device it
/// is pinned to, and the controls to reorder or remove it. Order is priority within a
/// list, so rows are walked up and down rather than deleted and re-added.
struct RuleRow: View {
  let rule: SoundRule
  let isFirst: Bool
  let isLast: Bool
  let moveUp: () -> Void
  let moveDown: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 1) {
        Text(RuleDisplay.triggerLabel(rule.trigger))
          .font(.system(size: 12, weight: .medium))
        Text(RuleDisplay.actionSummary(rule))
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Text(RuleDisplay.deviceScopeLabel(rule.deviceModel))
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
      Spacer()
      Button(action: moveUp) {
        Image(systemName: "chevron.up").foregroundStyle(isFirst ? .quaternary : .secondary)
      }
      .buttonStyle(.plain)
      .disabled(isFirst)
      .accessibilityLabel(L("優先度を上げる", "Raise priority"))
      Button(action: moveDown) {
        Image(systemName: "chevron.down").foregroundStyle(isLast ? .quaternary : .secondary)
      }
      .buttonStyle(.plain)
      .disabled(isLast)
      .accessibilityLabel(L("優先度を下げる", "Lower priority"))
      Button(action: delete) {
        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L("ルールを削除", "Delete rule"))
    }
  }
}
