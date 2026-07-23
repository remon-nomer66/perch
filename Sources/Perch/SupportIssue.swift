import AppKit
import SwiftUI
import TandemCore

/// Opens a pre-filled GitHub issue describing what the connected device declared, for
/// requesting support of an untested model. Nothing is sent from the app: the report is
/// built locally and handed to the browser, so the user reviews it before submitting and
/// no personal data (Bluetooth address, individual identifiers) can be included — the
/// report is built only from `TandemDeviceFingerprint`, which cannot hold those.
enum SupportIssue {
  /// The project's GitHub repository the reports are filed against, as `owner/repo`.
  static let repository = "remon-nomer66/perch"

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発ビルド"
  }

  /// Opens the issue for a report already built. Returns true when the body was too long
  /// for the URL and was placed on the clipboard instead (so the caller can tell the user
  /// to paste it); false when the whole issue opened pre-filled.
  ///
  /// The title always fits, so it pre-fills for a signed-in user either way. Only a long
  /// body — a report carrying raw captures — cannot ride in the URL, and then the copy
  /// buttons are the way in.
  @MainActor @discardableResult
  static func open(report: TandemDeviceSupportReport, repository: String = repository) -> Bool {
    guard let destination = try? TandemIssueLink.destination(repository: repository, report: report)
    else { return false }

    switch destination {
    case .prefilled(let url):
      NSWorkspace.shared.open(url)
      return false
    case .bodyTooLong(let form, let body):
      copyToPasteboard(body)
      NSWorkspace.shared.open(form)
      return true
    }
  }

  @MainActor
  static func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// The settings-window control that files the report. It reads the device once, then
/// offers the title and description both to copy (for anyone not signed in to GitHub) and
/// to open pre-filled in the browser (which auto-fills for a signed-in user).
struct SupportIssueSection: View {
  /// Supplied by the settings view, which reaches the session to read the fingerprint
  /// and take the raw capability captures. Returns nil when no device is connected.
  let gather: () async -> (fingerprint: TandemDeviceFingerprint, captures: [TandemRawCapture])?
  /// The gesture notifications heard so far, polled while the listening window runs
  /// so each touch shows up the moment it lands.
  let gestureSnapshot: () async -> [TandemRawCapture]

  /// How long the report waits for the user to run through their touch gestures.
  /// Enough for the taps and every swipe without feeling like a chore; the wait can
  /// be skipped.
  static let listeningSeconds = 20

  @State private var isGathering = false
  @State private var listening: Task<Void, Never>?
  @State private var remainingSeconds = 0
  @State private var heardGestures: [String] = []
  @State private var report: TandemDeviceSupportReport?
  @State private var copied: Field?
  @State private var bodyOnClipboard = false

  private enum Field { case title, description }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let report {
        prepared(report)
      } else if listening != nil {
        listeningView
      } else {
        gatherButton
      }
    }
  }

  // MARK: - Before the device is read

  private var gatherButton: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button {
          startListening()
        } label: {
          Label(
            L("解析レポートを用意", "Prepare analysis report"),
            systemImage: "ladybug"
          )
        }
        .disabled(isGathering)

        if isGathering {
          ProgressView().controlSize(.small)
          Text(L("機器を読み取っています…", "Reading the device…"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      Text(
        L(
          "接続中の機器が申告した内容（機種名・機能の一覧・各機能の生 capability 応答など）から"
            + "解析レポートを作ります。Bluetooth アドレス等の個人情報は含みません。"
            + "最初に約 \(Self.listeningSeconds) 秒間、タッチ操作の聞き取りを行います（スキップ可）。",
          "Builds an analysis report from what the connected device declared (model name, "
            + "feature list, raw capability responses, and so on). No personal data such as "
            + "the Bluetooth address is included. It starts by listening for touch gestures "
            + "for about \(Self.listeningSeconds) seconds (skippable)."
        )
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Listening for touch gestures

  /// The touch vocabulary is announced, never readable, so the report opens with a
  /// short window that asks the user to perform each gesture while it listens.
  private var listeningView: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(
          L(
            "タッチ操作を聞き取っています… 残り \(remainingSeconds) 秒",
            "Listening for touch gestures… \(remainingSeconds)s left"
          )
        )
        .font(.system(size: 11, weight: .medium))
      }

      Text(
        L(
          "ヘッドホンのタッチ操作（ダブルタップ・前後スワイプ・上下スワイプなど）を"
            + "ひと通り試してください。聞き取れた操作名がレポートに載ります。"
            + "操作に応じて再生中の曲は動きます。",
          "Run through the headphone's touch gestures (double tap, forward/back swipe, "
            + "up/down swipe, and so on). Each gesture heard is named in the report. "
            + "Playback will react to the gestures."
        )
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)

      if !heardGestures.isEmpty {
        Text(
          L("聞き取り済み: ", "Heard: ") + heardGestures.joined(separator: " · ")
        )
        .font(.system(size: 11).monospaced())
        .textSelection(.enabled)
      }

      HStack(spacing: 12) {
        Button(L("スキップして作成", "Skip and build")) {
          stopListening()
          Task { await gatherReport() }
        }
        .buttonStyle(.link)
        Button(L("中止", "Cancel")) {
          stopListening()
        }
        .buttonStyle(.link)
      }
    }
  }

  private func startListening() {
    heardGestures = []
    remainingSeconds = Self.listeningSeconds
    listening = Task {
      // Whatever was heard before the window still counts; the window's job is only
      // to invite the gestures nobody happened to make yet.
      heardGestures = TandemGestureNotificationLog.tokens(in: await gestureSnapshot())
      for second in stride(from: Self.listeningSeconds, through: 1, by: -1) {
        remainingSeconds = second
        for _ in 0..<2 {
          try? await Task.sleep(for: .milliseconds(500))
          if Task.isCancelled { return }
          heardGestures = TandemGestureNotificationLog.tokens(in: await gestureSnapshot())
        }
      }
      if Task.isCancelled { return }
      listening = nil
      await gatherReport()
    }
  }

  private func stopListening() {
    listening?.cancel()
    listening = nil
  }

  private func gatherReport() async {
    isGathering = true
    if let result = await gather() {
      report = TandemDeviceSupportReport(
        fingerprint: result.fingerprint,
        appVersion: SupportIssue.appVersion,
        captures: result.captures
      )
    }
    isGathering = false
  }

  // MARK: - After the device is read

  private func prepared(_ report: TandemDeviceSupportReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      copyRow(
        label: L("タイトル", "Title"),
        value: report.title,
        field: .title,
        text: report.title
      )
      copyRow(
        label: L("説明（解析内容）", "Description (analysis)"),
        value: L("Markdown・約 \(report.body.count) 文字", "Markdown · ~\(report.body.count) chars"),
        field: .description,
        text: report.body
      )

      HStack(spacing: 12) {
        Button {
          bodyOnClipboard = SupportIssue.open(report: report)
        } label: {
          Label(L("GitHub で issue を開く", "Open issue on GitHub"), systemImage: "arrow.up.forward.square")
        }
        Button(L("読み直す", "Re-read")) {
          self.report = nil
          copied = nil
          bodyOnClipboard = false
        }
        .buttonStyle(.link)
      }

      Text(
        L(
          "ログイン済みなら「開く」でタイトルは自動入力されます。解析が長いと説明は URL に載らないため、"
            + "その場合は説明を［コピー］して貼り付けてください。",
          "When signed in, “Open” pre-fills the title. A long analysis will not fit in the "
            + "URL, so copy the description and paste it instead."
        )
          + (bodyOnClipboard
            ? L("（説明はクリップボードにコピー済みです）", " (the description is already on the clipboard)")
            : "")
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
  }

  private func copyRow(label: String, value: String, field: Field, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(size: 12).monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      Button {
        SupportIssue.copyToPasteboard(text)
        copied = field
      } label: {
        Label(
          copied == field ? L("コピー済み", "Copied") : L("コピー", "Copy"),
          systemImage: copied == field ? "checkmark" : "doc.on.doc"
        )
        .font(.system(size: 11))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }
}
