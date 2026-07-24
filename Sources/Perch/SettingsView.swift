import AppKit
import NotchKit
import ServiceManagement
import SwiftUI
import TandemSession
import UniformTypeIdentifiers

/// The settings window. "一般" mirrors the device controls the notch offers, so the
/// device stays controllable from a plain window — including when the notch itself is
/// switched off in "設定".
struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var appearanceStore: NotchAppearanceStore
  @ObservedObject var settingsStore: AppSettingsStore
  @ObservedObject var updateChecker: UpdateChecker
  let service: SessionService
  @StateObject private var loginItem = LoginItemModel()

  private enum Tab: Hashable { case general, behavior, notch, about }
  /// Held here, outside the `.id` below: the language switch rebuilds the TabView,
  /// and a selection owned by it would reset to the first tab on every switch.
  @State private var selectedTab = Tab.general

  var body: some View {
    TabView(selection: $selectedTab) {
      GeneralTab(model: model, service: service)
        .tabItem { Label(L("一般", "General"), systemImage: "slider.horizontal.3") }
        .tag(Tab.general)
      BehaviorTab(settings: settingsStore, loginItem: loginItem, model: model, service: service)
        .tabItem { Label(L("設定", "Settings"), systemImage: "gearshape") }
        .tag(Tab.behavior)
      NotchSettingsView(store: appearanceStore, settings: settingsStore)
        .tabItem { Label(L("ノッチ", "Notch"), systemImage: "macwindow") }
        .tag(Tab.notch)
      AboutTab(updateChecker: updateChecker, settings: settingsStore)
        .tabItem { Label(L("情報", "About"), systemImage: "info.circle") }
        .tag(Tab.about)
    }
    // Tabs and rows bake their strings when built; a new identity re-renders the
    // whole window in the newly chosen language.
    .id(settingsStore.language)
  }
}

/// The same pages the notch panel shows, built once here so the panel and the settings
/// window cannot drift apart in what they let the user change.
extension AppModel {
  func panelPages(using service: SessionService) -> [PanelPage] {
    PanelPages.all(
      equalizer: panel.equalizer,
      noiseControl: panel.noiseControl,
      listeningMode: panel.listeningMode,
      applyNoiseControl: { [weak self] target in
        guard let self else { return }
        self.applyNoiseControl(target, using: service)
      },
      dragNoiseLevel: { [weak self] level, isFinal in
        guard let self else { return }
        self.dragNoiseLevel(level: level, isFinal: isFinal, using: service)
      },
      applyListening: { [weak self] target in
        guard let self else { return }
        self.applyListening(target, using: service)
      },
      applyEqualizerPreset: { [weak self] identifier in
        guard let self else { return }
        self.applyEqualizerPreset(identifier, using: service)
      },
      dragEqualizerBand: { [weak self] index, step, isFinal in
        guard let self else { return }
        self.dragEqualizerBand(index: index, step: step, isFinal: isFinal, using: service)
      },
      speakToChat: panel.speakToChat,
      applySpeakToChat: { [weak self] enabled in
        guard let self else { return }
        self.applySpeakToChat(enabled: enabled, using: service)
      },
      applySpeakToChatDetail: { [weak self] sensitivity, timeout in
        guard let self else { return }
        self.applySpeakToChatDetail(sensitivity: sensitivity, timeout: timeout, using: service)
      },
      sidetone: panel.sidetone,
      applySidetone: { [weak self] enabled in
        guard let self else { return }
        self.applySidetone(enabled: enabled, using: service)
      }
    )
  }
}

// MARK: - General (device controls)

/// The notch panel's pages, stacked vertically on dark cards: the pages draw
/// themselves for the notch's black backdrop, so each card recreates it.
private struct GeneralTab: View {
  @ObservedObject var model: AppModel
  let service: SessionService

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        DeviceStatusHeader(
          summary: model.panel.summary,
          battery: model.panel.battery,
          retry: { await service.session.handle(.manualRetry) }
        )

        if model.panel.summary.isControllable {
          if let caveat = model.panel.summary.caveat {
            Label(caveat, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11))
              .foregroundStyle(.orange)
          }

          // The report control sits right by the caveat: an unverified model is exactly
          // the one worth reporting, so it belongs beside the warning that prompts it.
          SupportIssueSection(
            gather: {
              let session = await service.session
              guard let fingerprint = await session.deviceFingerprint else { return nil }
              let captures = await session.supportCaptures()
              return (fingerprint, captures)
            },
            gestureSnapshot: {
              await service.session.gestureCaptures()
            }
          )

          ForEach(model.panelPages(using: service)) { page in
            page.content
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(14)
              .background(RoundedRectangle(cornerRadius: 10).fill(.black))
              // A read-only session still shows every reading; only the writes are
              // withheld, and the caveat above says why.
              .disabled(!model.panel.summary.acceptsWrites)
          }
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct DeviceStatusHeader: View {
  let summary: DeviceSummary
  let battery: BatteryLayout
  /// Fires the session's manual retry. Shown only in the two states the state
  /// machine leaves on an explicit ask.
  var retry: (() async -> Void)?

  @State private var isRetrying = false

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.modelName ?? L("対応機器なし", "No supported device"))
          .font(.system(size: 13, weight: .semibold))
        Text(statusText)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        if let retry, showsRetry {
          Button(L("再接続", "Reconnect")) {
            guard !isRetrying else { return }
            isRetrying = true
            Task {
              await retry()
              isRetrying = false
            }
          }
          .disabled(isRetrying)
          .padding(.top, 4)
        }
      }
      Spacer()
      Text(batteryText)
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  /// The two states that do not resolve on their own: another host holding the
  /// session, and a retry budget already spent.
  private var showsRetry: Bool {
    switch summary.status {
    case .takenByAnotherDevice, .unreachable: true
    default: false
    }
  }

  private var statusText: String {
    switch summary.status {
    case .noDevice: L("対応機器が音声の出力先になっていません", "No supported device is the sound output")
    case .connecting: L("接続しています", "Connecting")
    case .reading: L("機器の情報を読み取っています", "Reading device information")
    case .unverified: L("接続済み(未確認の機種)", "Connected (unverified model)")
    case .ready: L("接続済み", "Connected")
    case .takenByAnotherDevice: L("別の端末が操作しています", "Another device is in control")
    case .unreachable: L("機器に接続できませんでした", "Could not connect to the device")
    }
  }

  private var batteryText: String {
    switch battery {
    case .single(let value):
      value.map { "\(L("電池", "Battery")) \($0)%" } ?? ""
    case .leftRight(let left, let right, let charging):
      [
        left.map { "L \($0)%" },
        right.map { "R \($0)%" },
        charging.map { "\(L("ケース", "Case")) \($0)%" },
      ]
      .compactMap(\.self)
      .joined(separator: "  ")
    case .unknown:
      ""
    }
  }
}

// MARK: - Behavior (app settings)

private struct BehaviorTab: View {
  @ObservedObject var settings: AppSettingsStore
  @ObservedObject var loginItem: LoginItemModel
  @ObservedObject var model: AppModel
  let service: SessionService
  /// Watched so a denial seen mid-session surfaces its warning without a reopen.
  @ObservedObject private var automation = AutomationPermission.shared

  private enum TriggerKind: Hashable { case site, app }
  private struct AppChoice: Identifiable, Equatable {
    let id: String
    let name: String
  }

  @State private var newTriggerKind = TriggerKind.site
  @State private var newSite = ""
  @State private var newApp = SoundRule.knownApps[0].bundleID
  /// Apps picked from disk this session, so the picker can show what was chosen.
  @State private var pickedApps: [AppChoice] = []
  @State private var newNoise = SoundRule.NoiseAction.keep
  /// -1 keeps the equaliser; anything else is a preset identifier.
  @State private var newPreset = -1
  @State private var newListening = SoundRule.ListeningAction.keep

  var body: some View {
    Form {
      Section(L("自動切り替えルール", "Auto-switch rules")) {
        Toggle(L("ルールを有効にする", "Enable rules"), isOn: $settings.isRulesEnabled)
        Text(
          L(
            "再生中のプレーヤー(Spotify・ミュージック)を最優先に、次に最前面のアプリ、"
              + "そしてブラウザ各ウィンドウの手前のタブで判定します(別ディスプレイも対象)。"
              + "ソースを離れるとルールが変えた項目だけ元に戻り、手動で変えた項目はそのまま残ります。"
              + "複数のルールに当てはまる場合は、上にあるルールが優先されます。"
              + "初回はブラウザ操作の許可を求められます。",
            "The playing player (Spotify or Music) is matched first, then the frontmost app, "
              + "then the front tab of each browser window (other displays included). "
              + "When a source is left, only what the rule changed is put back; manual "
              + "changes stay. When several rules match, the one higher in the list wins. "
              + "The first use asks for permission to control the browser."
          )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

        // A refused automation permission otherwise just looks like rules that never
        // match; the refusal is only observable when a query fails, so it is shown
        // here the moment one does.
        if automation.browserDenied {
          Label(
            L(
              "ブラウザ操作が許可されていません。サイトのルールを使うには、"
                + "システム設定 > プライバシーとセキュリティ > オートメーション から許可してください。",
              "Browser control is not permitted. For site rules, allow it in "
                + "System Settings > Privacy & Security > Automation."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11))
          .foregroundStyle(.orange)
        }
        if automation.playerDenied {
          Label(
            L(
              "ミュージック/Spotify の操作が許可されていません。再生中の判定と曲の表示には、"
                + "システム設定 > プライバシーとセキュリティ > オートメーション から許可してください。",
              "Controlling Music/Spotify is not permitted. For playback detection and "
                + "the now-playing display, allow it in "
                + "System Settings > Privacy & Security > Automation."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 11))
          .foregroundStyle(.orange)
        }

        ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
              Text(Self.triggerLabel(rule.trigger))
                .font(.system(size: 12, weight: .medium))
              Text(Self.actionSummary(rule))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer()
            // Order is priority: the first matching rule wins, so rows can be walked
            // up and down instead of deleting and re-adding to reorder.
            Button {
              move(rule, by: -1)
            } label: {
              Image(systemName: "chevron.up")
                .foregroundStyle(index == 0 ? .quaternary : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityLabel(L("優先度を上げる", "Raise priority"))
            Button {
              move(rule, by: 1)
            } label: {
              Image(systemName: "chevron.down")
                .foregroundStyle(index == settings.rules.count - 1 ? .quaternary : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(index == settings.rules.count - 1)
            .accessibilityLabel(L("優先度を下げる", "Lower priority"))
            Button {
              settings.rules.removeAll { $0.id == rule.id }
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("ルールを削除", "Delete rule"))
          }
        }

        // The choices a rule offers are the connected device's declarations, so a rule
        // is written against a real device — and while writing one, each choice lands
        // on the device at once so it can be judged by ear.
        if model.panel.summary.isControllable {
          newRuleEditor
        } else {
          Text(
            L(
              "ルールの追加は機器の接続中に行えます。接続中は選んだ設定がその場で機器に反映され、"
                + "聴きながら選べます。",
              "Rules can be added while a device is connected. While connected, each choice "
                + "is applied to the device right away, so it can be judged by ear."
            )
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
      }

      Section(L("起動", "Launch")) {
        Toggle(
          L("ログイン時に自動で起動", "Launch automatically at login"),
          isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.set($0) }
          )
        )
        if let message = loginItem.message {
          Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
    // Leaving the tab or closing the window abandons the audition; the device goes
    // back to how it was.
    .onDisappear { model.endPreview(using: service) }
  }

  @ViewBuilder
  private var newRuleEditor: some View {
    Picker(L("対象", "Target"), selection: $newTriggerKind) {
      Text(L("サイト", "Site")).tag(TriggerKind.site)
      Text(L("アプリ", "App")).tag(TriggerKind.app)
    }
    .pickerStyle(.segmented)

    if newTriggerKind == .site {
      TextField(L("example.com または URL", "example.com or URL"), text: $newSite)
        .textFieldStyle(.roundedBorder)
    } else {
      HStack {
        // The pinned players first, then whatever is running, then anything picked
        // from disk — any app can be a source, not just the scriptable two.
        Picker(L("アプリ", "App"), selection: $newApp) {
          ForEach(appChoices) { app in
            Text(app.name).tag(app.id)
          }
        }
        Button(L("その他…", "Other…"), action: pickAppFromDisk)
      }
    }

    Text(
      L(
        "選んだ設定はその場で機器に反映され、聴きながら選べます。ルールを追加すると元の設定に戻ります。",
        "Choices are applied to the device right away, so they can be judged by ear. "
          + "Adding the rule puts the previous settings back."
      )
    )
    .font(.system(size: 11))
    .foregroundStyle(.secondary)

    Picker(L("ノイキャン", "Noise control"), selection: $newNoise) {
      ForEach(SoundRule.NoiseAction.allCases, id: \.self) { action in
        Text(Self.noiseLabel(action)).tag(action)
      }
    }
    .onChange(of: newNoise) { _, value in
      model.previewNoise(value, using: service)
    }

    // Preset choices are what the connected device declared. While the rule also puts
    // the device into BGM or cinema, the device itself switches the equaliser off, so
    // the two cannot be asked for together.
    Picker(L("イコライザー", "Equalizer"), selection: $newPreset) {
      Text(L("そのまま", "Keep")).tag(-1)
      ForEach(presetChoices, id: \.self) { identifier in
        Text(PresetDisplay.label(for: identifier)).tag(Int(identifier))
      }
    }
    .onChange(of: newPreset) { _, value in
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

    Picker(L("リスニングモード", "Listening mode"), selection: $newListening) {
      ForEach(SoundRule.ListeningAction.allCases, id: \.self) { action in
        Text(Self.listeningLabel(action)).tag(action)
      }
    }
    .onChange(of: newListening) { _, value in
      if value == .backgroundMusic || value == .cinema { newPreset = -1 }
      model.previewListening(value, using: service)
    }

    HStack {
      if isDuplicateTrigger {
        Text(L("同じ対象のルールが既にあります。", "A rule for this target already exists."))
          .font(.system(size: 11))
          .foregroundStyle(.orange)
      }
      Spacer()
      Button(L("ルールを追加", "Add Rule"), action: addRule)
        .disabled(!canAddRule)
    }
  }

  /// The pinned players, then the running regular apps, then whatever was picked
  /// from disk; ourselves excluded — a rule about this app would chase its own tail.
  private var appChoices: [AppChoice] {
    var seen: Set<String> = [Bundle.main.bundleIdentifier].compactMap { $0 }.reduce(into: []) {
      $0.insert($1)
    }
    var choices: [AppChoice] = []
    for app in SoundRule.knownApps where seen.insert(app.bundleID).inserted {
      choices.append(AppChoice(id: app.bundleID, name: app.title))
    }
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
      choices.append(AppChoice(id: id, name: app.localizedName ?? id))
    }
    for picked in pickedApps where seen.insert(picked.id).inserted {
      choices.append(picked)
    }
    return choices
  }

  private func pickAppFromDisk() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
      let bundle = Bundle(url: url), let id = bundle.bundleIdentifier
    else { return }
    let name = (bundle.infoDictionary?["CFBundleName"] as? String)
      ?? url.deletingPathExtension().lastPathComponent
    pickedApps.removeAll { $0.id == id }
    pickedApps.append(AppChoice(id: id, name: name))
    newApp = id
  }

  private var listeningBlocksEqualizer: Bool {
    newListening == .backgroundMusic || newListening == .cinema
  }

  private var presetChoices: [UInt8] {
    model.panel.equalizer?.presets.map(\.identifier) ?? []
  }

  /// The trigger the editor currently describes, nil while the site field does not
  /// parse. One rule per source: this is also the duplicate check's key.
  private var newTrigger: SoundRule.Trigger? {
    switch newTriggerKind {
    case .site: SiteWatcher.normalizedSite(newSite).map(SoundRule.Trigger.site)
    case .app: .app(newApp)
    }
  }

  private var isDuplicateTrigger: Bool {
    guard let newTrigger else { return false }
    return settings.rules.contains { $0.trigger == newTrigger }
  }

  private var canAddRule: Bool {
    let hasAction = newNoise != .keep || newPreset >= 0 || newListening != .keep
    return hasAction && newTrigger != nil && !isDuplicateTrigger
  }

  private func move(_ rule: SoundRule, by offset: Int) {
    guard let index = settings.rules.firstIndex(where: { $0.id == rule.id }) else { return }
    let target = index + offset
    guard settings.rules.indices.contains(target) else { return }
    var reordered = settings.rules
    reordered.swapAt(index, target)
    settings.rules = reordered
  }

  private func addRule() {
    guard let trigger = newTrigger, !isDuplicateTrigger else { return }
    var rule = SoundRule(trigger: trigger)
    rule.noise = newNoise
    rule.equalizerPreset = newPreset >= 0 ? UInt8(newPreset) : nil
    rule.listening = newListening
    settings.rules.append(rule)

    newSite = ""
    newNoise = .keep
    newPreset = -1
    newListening = .keep
    // The rule is registered; the audition ends and the device goes back to how it
    // was. The resets above fire the preview handlers too, but with the hold already
    // cleared they do nothing.
    model.endPreview(using: service)
  }

  private static func triggerLabel(_ trigger: SoundRule.Trigger) -> String {
    switch trigger {
    case .site(let domain): domain
    case .app(let bundleID): SoundRule.appTitle(for: bundleID)
    }
  }

  private static func actionSummary(_ rule: SoundRule) -> String {
    var parts: [String] = []
    if rule.noise != .keep {
      parts.append("\(L("ノイキャン", "NC")): \(noiseLabel(rule.noise))")
    }
    if let preset = rule.equalizerPreset {
      parts.append("EQ: \(PresetDisplay.label(for: preset))")
    }
    if rule.listening != .keep {
      parts.append("\(L("モード", "Mode")): \(listeningLabel(rule.listening))")
    }
    return parts.isEmpty ? L("変更なし", "No changes") : parts.joined(separator: " / ")
  }

  private static func noiseLabel(_ action: SoundRule.NoiseAction) -> String {
    switch action {
    case .keep: L("そのまま", "Keep")
    case .noiseCancelling: L("ノイズキャンセリング", "Noise Cancelling")
    case .ambient: L("外音取り込み", "Ambient Sound")
    case .off: L("オフ", "Off")
    }
  }

  private static func listeningLabel(_ action: SoundRule.ListeningAction) -> String {
    switch action {
    case .keep: L("そのまま", "Keep")
    case .standard: L("標準", "Standard")
    case .backgroundMusic: L("BGM", "Background Music")
    case .cinema: L("シネマ", "Cinema")
    }
  }
}

/// Registers the app as a login item, and reports what actually happened: a binary
/// launched outside its bundle cannot register, and a toggle that silently pretended
/// otherwise would lie about the next login.
@MainActor
final class LoginItemModel: ObservableObject {
  @Published private(set) var isEnabled: Bool
  /// The failure is stored as the system's error description, not as the finished
  /// sentence: the sentence is composed at render time, so a language switch after
  /// the failure re-reads its `L(_:_:)` pair like every other string on screen.
  @Published private(set) var failureDescription: String?

  var message: String? {
    failureDescription.map { "\(L("変更できませんでした", "Could not change")): \($0)" }
  }

  init() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

  func set(_ enable: Bool) {
    do {
      if enable {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      failureDescription = nil
    } catch {
      failureDescription = error.localizedDescription
    }
    isEnabled = SMAppService.mainApp.status == .enabled
  }
}

// MARK: - About

private struct AboutTab: View {
  @ObservedObject var updateChecker: UpdateChecker
  @ObservedObject var settings: AppSettingsStore

  var body: some View {
    VStack(spacing: 10) {
      Group {
        if let icon = NSImage(named: NSImage.applicationIconName) {
          Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 72, height: 72)
        } else {
          Image(systemName: "headphones")
            .font(.system(size: 34))
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel(appName)
      Text(appName)
        .font(.title3.weight(.semibold))
      Text("\(L("バージョン", "Version")) \(version)")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      updateSection
      Text(
        L(
          "対応ヘッドホン・イヤホンをノッチから操作するユーティリティ",
          "A utility for controlling supported headphones and earbuds from the notch"
        )
      )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Text(
        L(
          "本アプリは有志による非公式ツールです。"
            + "ソニーグループ株式会社およびその関連会社が提供・承認・後援するものではなく、"
            + "同社とは一切関係ありません。"
            + "記載されている製品名・商標は各権利者に帰属します。",
          "This app is an unofficial tool built by volunteers. "
            + "It is not provided, endorsed, or sponsored by Sony Group Corporation "
            + "or its affiliates, and has no connection with them. "
            + "Product names and trademarks belong to their respective owners."
        )
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(12)
      .frame(maxWidth: 420)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.quaternary, lineWidth: 1)
      )
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  // MARK: - Update check

  @ViewBuilder
  private var updateSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: updateGlyph)
          .foregroundStyle(updateTint)
        Text(updateHeadline)
          .font(.system(size: 12, weight: .medium))
        if updateChecker.status == .checking {
          ProgressView().controlSize(.small)
        }
        Spacer()
        Button(L("更新を確認", "Check for Updates")) {
          Task { await updateChecker.checkNow() }
        }
        .controlSize(.small)
        .disabled(updateChecker.status == .checking)
      }

      if case .available(let info) = updateChecker.status {
        Text(updateDetail(info))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Button(L("ダウンロード", "Download")) {
            NSWorkspace.shared.open(info.bestDownloadURL)
          }
          .controlSize(.small)
          Button(L("リリースノート", "Release Notes")) {
            NSWorkspace.shared.open(info.releaseURL)
          }
          .buttonStyle(.link)
          Button(L("このバージョンを飛ばす", "Skip This Version")) {
            updateChecker.skipAvailable()
          }
          .buttonStyle(.link)
        }
        Text(
          L(
            "ダウンロードした .dmg を開き、Perch をアプリケーションフォルダにドラッグして"
              + "置き換えてください。設定はそのまま引き継がれます。",
            "Open the downloaded .dmg and drag Perch onto your Applications folder to "
              + "replace it. Your settings carry over."
          )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      } else if case .failed(let reason) = updateChecker.status {
        Text(Self.failureText(reason))
          .font(.system(size: 11))
          .foregroundStyle(.orange)
      }

      Toggle(
        L("起動時に更新を確認", "Check for updates at launch"),
        isOn: $settings.checksForUpdatesAtLaunch
      )
      .font(.system(size: 11))
      .toggleStyle(.checkbox)
      .padding(.top, 2)
    }
    .padding(12)
    .frame(maxWidth: 420, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.quaternary, lineWidth: 1)
    )
    .padding(.top, 8)
  }

  private var updateGlyph: String {
    switch updateChecker.status {
    case .available: "arrow.down.circle.fill"
    case .upToDate: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    default: "arrow.triangle.2.circlepath"
    }
  }

  private var updateTint: Color {
    switch updateChecker.status {
    case .available: .accentColor
    case .upToDate: .green
    case .failed: .orange
    default: .secondary
    }
  }

  private var updateHeadline: String {
    switch updateChecker.status {
    case .idle: L("アップデート", "Updates")
    case .checking: L("確認しています…", "Checking…")
    case .upToDate: L("最新です", "Up to date")
    case .available: L("新しいバージョンがあります", "An update is available")
    case .failed: L("更新を確認できませんでした", "Couldn’t check for updates")
    }
  }

  private func updateDetail(_ info: ReleaseInfo) -> String {
    L(
      "バージョン \(info.version) が公開されています（現在 \(version)）。",
      "Version \(info.version) is available (you have \(version))."
    )
  }

  private static func failureText(_ reason: UpdateCheckFailure) -> String {
    switch reason {
    case .offlineOrUnreachable:
      L(
        "ネットワークに接続できませんでした。時間をおいて再度お試しください。",
        "Couldn’t reach the network. Please try again later."
      )
    case .developmentBuild:
      L("開発ビルドのため確認できません。", "Can’t check for updates from a development build.")
    case .malformedResponse:
      L("応答を読み取れませんでした。", "Couldn’t read the response from the server.")
    }
  }

  private var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Perch"
  }

  /// `swift run` executes the bare binary, whose bundle carries no version; saying
  /// "development build" is more honest than inventing a number for it.
  private var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case (let short?, let build?): return "\(short) (\(build))"
    case (let short?, nil): return short
    default: return L("開発ビルド", "development build")
    }
  }
}
