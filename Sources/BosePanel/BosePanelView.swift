import DeviceContract
import SwiftUI

/// The expanded Bose panel: the black rounded container, a header of model name and
/// charge, one feature page, and the page dots.
///
/// The container's look — black fill, rounded corners, the header band, the dot row — is
/// the shared notch visual language, matched to the Sony panel so the two brands feel like
/// one app. What sits *inside* is entirely Bose (`BosePanelPages`). The morphing notch
/// shell and the shared now-playing column are the app's, added when this panel is wired
/// in at stage 6; here the panel stands alone so it can be rendered without hardware.
public struct BosePanelView: View {
  public let state: BosePanelState
  public let page: Int
  public let actions: BosePanelActions
  public var cornerRadius: CGFloat

  public init(
    state: BosePanelState,
    page: Int,
    actions: BosePanelActions = BosePanelActions(),
    cornerRadius: CGFloat = 22
  ) {
    self.state = state
    self.page = page
    self.actions = actions
    self.cornerRadius = cornerRadius
  }

  public var body: some View {
    VStack(spacing: 0) {
      header

      Divider()
        .overlay(.white.opacity(0.12))
        .padding(.top, 6)

      pageContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A read-only session still shows every reading, but its controls must not
        // pretend a write will land — matching the Sony panel.
        .disabled(!state.acceptsWrites)
        .padding(.top, 12)

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        BosePageIndicator(count: BosePanelPageID.allCases.count, index: currentPage)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.black))
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      if let name = state.modelName, !name.isEmpty {
        Text(name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      BoseBatteryReadout(battery: state.battery)
    }
    .frame(height: 16)
  }

  @ViewBuilder
  private var pageContent: some View {
    switch BosePanelPageID.allCases[currentPage] {
    case .noise:
      BoseNoisePage(state: state, actions: actions)
    case .equalizer:
      BoseEqualizerPage(state: state, actions: actions)
    case .modes:
      BoseModesPage(state: state, actions: actions)
    case .extras:
      BoseExtrasPage(state: state, actions: actions)
    }
  }

  private var currentPage: Int {
    min(max(page, 0), BosePanelPageID.allCases.count - 1)
  }
}

/// The Bose controls stacked as one scrolling column of cards, one per declared feature —
/// the shape the settings window wants, where there is room to scroll rather than page.
///
/// This is the same content `BosePanelView` pages through, but laid out vertically and, in
/// place of the pager's "not declared" sheets, simply omitting any feature the device does
/// not carry: a card appears only when its feature is present, so nothing dead or empty is
/// ever shown. The notch keeps `BosePanelView` (a fixed slot must page); the window uses
/// this.
public struct BosePanelStackView: View {
  public let state: BosePanelState
  public let actions: BosePanelActions

  public init(state: BosePanelState, actions: BosePanelActions = BosePanelActions()) {
    self.state = state
    self.actions = actions
  }

  public var body: some View {
    VStack(spacing: 12) {
      // Noise control is deliberately omitted here: on the Ultra family the noise state
      // lives on the listening mode, so the audio-modes card below is the single place it
      // is chosen — a separate slider/switch card only duplicated it (see `BoseModesPage`).
      if state.equalizer != nil {
        card { BoseEqualizerPage(state: state, actions: actions) }
      }
      if hasModes {
        card { BoseModesPage(state: state, actions: actions) }
      }
      if hasExtras {
        card { BoseExtrasPage(state: state, actions: actions) }
      }
    }
    // Every card here is a device control: a read-only session shows the readings but
    // must not offer a write it would refuse, matching the pager and the Sony cards.
    .disabled(!state.acceptsWrites)
  }

  private var hasModes: Bool {
    (state.audioModes?.modes.isEmpty == false)
  }

  private var hasExtras: Bool {
    state.spatial != nil || state.sidetone != nil
  }

  /// One black card, matching the Sony settings cards: the pages draw for a black
  /// backdrop, so each feature is given its own.
  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(14)
      .background(RoundedRectangle(cornerRadius: 10).fill(.black))
  }
}

/// One Bose feature sheet, wired to the live model so it redraws as the device (or the
/// user) changes it — the unit the notch pager slides between, mirroring how the Sony
/// sheets sit in the notch. Each `PanelPage` in the notch wraps one of these; observing the
/// model here means a drag on a sheet updates it even when the pager around it does not
/// rebuild. The sheets are the same views the paged panel and the settings stack draw.
public struct BosePanelSheet: View {
  public enum Kind: String, Sendable, CaseIterable {
    case equalizer
    case modes
    case extras
  }

  @ObservedObject private var model: BosePanelModel
  private let kind: Kind

  public init(model: BosePanelModel, kind: Kind) {
    self.model = model
    self.kind = kind
  }

  public var body: some View {
    switch kind {
    case .equalizer: BoseEqualizerPage(state: model.state, actions: model.actions)
    case .modes: BoseModesPage(state: model.state, actions: model.actions)
    case .extras: BoseExtrasPage(state: model.state, actions: model.actions)
    }
  }
}

/// The closed notch bar for a Bose device: the model name at the left edge, the charge at
/// the right. The same shape and margins the shared closed bar uses, drawn here so the Bose
/// panel can be previewed end to end.
public struct BoseClosedBar: View {
  public let modelName: String?
  public let battery: BatteryReading
  public var cornerRadius: CGFloat

  public init(modelName: String?, battery: BatteryReading, cornerRadius: CGFloat = 12) {
    self.modelName = modelName
    self.battery = battery
    self.cornerRadius = cornerRadius
  }

  public var body: some View {
    HStack(spacing: 8) {
      if let name = modelName, !name.isEmpty {
        Text(name)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      BoseBatteryReadout(battery: battery)
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.black))
  }
}
