import AppKit
import NotchKit
import SwiftUI
import TandemCore
import TandemSession

/// How a device reports its charge, which follows from how many enclosures it has.
///
/// Showing left and right for a headband, or a single figure for earbuds, would be
/// inventing a shape the device never claimed.
enum BatteryLayout: Equatable {
  case single(Int?)
  case leftRight(left: Int?, right: Int?, charging: Int?)
  case unknown
}

/// What the panel needs to draw.
struct PanelModel: Equatable {
  var summary: DeviceSummary = DeviceSummary()
  var battery: BatteryLayout = .unknown
  var equalizer: EqualizerReading?
  var noiseControl: NoiseControlReading?
  var listeningMode: TandemListeningReading?
  var speakToChat: SpeakToChatReading?
  var sidetone: SidetoneReading?
  var nowPlaying: NowPlaying?
  /// True for a few seconds after a device arrives; the quiet mode shows the bar for
  /// exactly this window. Decided by the model, not view state, so a transition the
  /// view was not alive to see still announces itself.
  var announcesArrival = false

  struct NowPlaying: Equatable {
    var title: String?
    var artist: String?
    var isPlaying: Bool
    var artworkURL: String?
  }
}

/// Fixed header geometry shared between the expanded layout and the morphing overlay,
/// so the reserved row in the column and the overlaid name land in the same place.
private enum HeaderLayout {
  static let rowHeight: CGFloat = 16
  static let topInset: CGFloat = 12
  static let sideInset: CGFloat = 16
  static let nowPlayingWidth: CGFloat = 104
  /// The band the overlay centres its labels in vertically while open.
  static var openBandHeight: CGFloat { rowHeight + topInset * 2 }
}

/// The transport actions the now-playing column drives, kept together so the panel view
/// carries one value rather than three loose closures.
struct NowPlayingTransport {
  let playPause: () -> Void
  let next: () -> Void
  let previous: () -> Void
}

struct NotchPanelView: View {
  let presentation: NotchPresenter.Presentation
  /// The cutout in *global screen coordinates*, exactly as `NSScreen` reports it.
  /// Only its size may be read directly; a position must first be shifted into the
  /// hosting window's space — see `notchMidXInWindow`.
  let notchRect: CGRect
  /// True when the notch was synthesised on a screen with no cutout of its own. Such a
  /// notch rests as a thin sliver and is quiet by nature, showing its bar only while
  /// looked at or just after a device arrives.
  var isVirtual: Bool = false
  let appearance: NotchAppearance
  let displayMode: NotchDisplayMode
  let model: PanelModel
  @Binding var page: Int
  let pages: [PanelPage]
  var transport: NowPlayingTransport?
  /// Opens the settings window; the gear beside the page dots.
  var openSettings: (() -> Void)?
  /// Fires the session's manual retry. Shown only in the two states the state
  /// machine leaves on an explicit ask: another host holding the session, and a
  /// retry budget already spent.
  var retry: (() async -> Void)?

  /// One shape whose size changes, never two shapes swapped for one another.
  ///
  /// Cross-fading a small view for a large one reads as a panel being dropped on top
  /// of the notch. Growing a single shape is what makes it read as the notch itself
  /// stretching, which is the whole idea. The name and charge ride the shape the same
  /// way: one instance each, overlaid on the shape, moving between their closed and
  /// open places rather than being drawn once per state.
  var body: some View {
    ZStack(alignment: .top) {
      content
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(.black))
        .overlay { headerOverlay }
        .clipShape(shape)
        // Flattened before the shadow: a filter shadow over a live layer tree can
        // drift from the frame left on the glass, and the cursor then "wipes" the
        // stale shadow into visible trails as it passes underneath the panel.
        .compositingGroup()
        .shadow(color: .black.opacity(isOpen ? 0.55 : 0), radius: 20, y: 8)
        .position(x: notchMidXInWindow, y: size.height / 2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(.interactiveSpring(duration: 0.45, extraBounce: 0.22), value: presentation)
    // The bar also grows and shrinks without the pointer's involvement — a device
    // arriving, the arrival announcement lapsing — and those must spring the same way.
    .animation(.interactiveSpring(duration: 0.45, extraBounce: 0.22), value: isExtended)
  }

  private var isOpen: Bool { presentation == .opened }

  /// The cutout's centre in the hosting window's coordinate space. The strip window
  /// starts at the notch screen's own `minX`, so the global X carries an offset on
  /// any arrangement where that screen is not leftmost — used raw it would draw the
  /// bar displaced, or past the window's edge entirely, while hover kept answering
  /// (the hit testing compares global against global and never notices).
  private var notchMidXInWindow: CGFloat {
    // The strip window starts at the notch screen's own minX. A virtual notch lives on
    // a screen `NSScreen.withNotch` cannot name, so the screen is found by the cutout
    // it sits on — which resolves to the same screen for a real notch too.
    let point = CGPoint(x: notchRect.midX, y: notchRect.maxY - 1)
    let screenMinX = NSScreen.screens.first { $0.frame.contains(point) }?.frame.minX ?? 0
    return notchRect.midX - screenMinX
  }

  /// The bar widens only when it actually has something to carry. Being controllable
  /// is not enough: right after a disconnect — or before the first read lands — the
  /// session can count as controllable while neither a name nor a charge exists yet,
  /// and widening then shows an empty slab where the bare notch should be.
  private var hasContent: Bool {
    model.summary.isControllable
      && (model.summary.modelName != nil || model.battery != .unknown)
  }

  /// Whether the closed bar is drawn at all. The quiet mode keeps the bare notch and
  /// widens only while looked at — pointer on the notch, panel open — or for the few
  /// seconds after a device connects.
  private var isExtended: Bool {
    guard hasContent else { return false }
    // A virtual notch is quiet whatever the display mode says: it rests as a sliver and
    // only shows its bar while looked at or just after a device connects.
    if isVirtual { return presentation != .closed || model.announcesArrival }
    switch displayMode {
    case .always: return true
    case .onHover: return presentation != .closed || model.announcesArrival
    }
  }

  private var size: CGSize {
    guard !isOpen else { return appearance.expandedSize }
    let base: CGSize
    if isExtended {
      base = appearance.closedRect(around: notchRect).size
    } else if isVirtual && presentation == .closed {
      // At rest, with nothing to carry and no pointer on it, the virtual notch is only
      // the sliver: a couple of millimetres of edge, not a menu-bar-tall slab.
      base = appearance.restingSliver(in: notchRect).size
    } else {
      base = notchRect.size
    }
    // The hint is a couple of points of growth, the same gesture NotchDrop makes.
    let extra: CGFloat = presentation == .popping ? 2 : 0
    return CGSize(width: base.width + extra, height: base.height + extra)
  }

  private var shape: NotchShape {
    NotchShape(
      topCornerRadius: appearance.topCornerRadius,
      bottomCornerRadius: isOpen
        ? appearance.expandedBottomCornerRadius
        : appearance.closedBottomCornerRadius
    )
  }

  @ViewBuilder
  private var content: some View {
    if isOpen {
      expandedContent.transition(.opacity)
    } else {
      // The closed bar carries nothing of its own; its name and charge are the
      // overlay's, so they survive the switch to the open layout.
      Color.clear
    }
  }

  // MARK: - Header overlay

  /// The name and charge, drawn once and carried between the closed bar and the open
  /// header. Anchoring them to the shape's own edges also makes them ride the spring's
  /// overshoot: when the collapse drives the bar past its resting width, the labels
  /// travel with the moving edges instead of being centred and clipped at the extreme.
  @ViewBuilder
  private var headerOverlay: some View {
    if isOpen || isExtended {
      let bandHeight = isOpen ? HeaderLayout.openBandHeight : notchRect.height
      ZStack(alignment: .top) {
        HStack(spacing: 8) {
          MorphingDeviceName(name: model.summary.modelName, progress: isOpen ? 1 : 0)
          // The negotiated codec, as a quiet suffix to the name. Only while open —
          // the closed bar has no room for secondary facts.
          if isOpen, let codec = model.summary.codec {
            Text(codec)
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.white.opacity(0.5))
              .transition(.opacity)
          }
        }
        .frame(height: bandHeight)
        .padding(.leading, nameLeadingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        BatteryReadout(battery: model.battery, isExpanded: isOpen)
          .frame(height: bandHeight)
          .padding(.trailing, batteryTrailingInset)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
      .allowsHitTesting(false)
    }
  }

  /// The uniform margin between the closed bar's outer edge and its name/charge, so the
  /// name hugs the left edge and the charge the right by the same amount.
  private static let closedSideInset: CGFloat = 12

  private var nameLeadingInset: CGFloat {
    // Open, the header mirrors around the cutout: the panel is centred on the notch,
    // so giving the name the same margin from the left edge that the charge keeps
    // from the right makes the two sit at equal distances from the cutout. Closed,
    // the name is left-aligned to the bar's edge by a fixed margin.
    isOpen
      ? HeaderLayout.sideInset
      : Self.closedSideInset
  }

  private var batteryTrailingInset: CGFloat {
    // Closed, the charge is right-aligned to the bar's edge by the same fixed margin.
    isOpen
      ? HeaderLayout.sideInset
      : Self.closedSideInset
  }

  // MARK: - Expanded

  private var expandedContent: some View {
    VStack(spacing: 0) {
      // The name and charge are the overlay's; this row only reserves their place.
      Color.clear
        .frame(height: HeaderLayout.rowHeight)
        .padding(.top, HeaderLayout.topInset)

      // One full-width rule across the whole panel, not just the settings column.
      // Nudged down a touch so the header above it keeps a little more air.
      Divider().overlay(.white.opacity(0.12))
        .padding(.top, 6)

      // The media zone is on the left of every page; the page's own sheet is on the
      // right. The player is always present, showing a placeholder when nothing plays.
      HStack(alignment: .top, spacing: HeaderLayout.sideInset) {
        NowPlayingColumn(nowPlaying: model.nowPlaying, transport: transport)
          // Leading-aligned so the artwork shares the name's margin above it, keeping
          // the header and the media block on one left edge.
          .frame(width: HeaderLayout.nowPlayingWidth, alignment: .leading)
        pageContent
      }
      .padding(.horizontal, HeaderLayout.sideInset)
      .padding(.top, HeaderLayout.topInset)
      .padding(.bottom, HeaderLayout.topInset)
    }
    // Top-aligned so a page taller than the panel overflows downward and clips at the
    // bottom, never centring itself and pushing the header up under the notch cutout.
    .frame(width: appearance.expandedWidth, height: appearance.expandedHeight, alignment: .top)
  }

  @ViewBuilder
  private var pageContent: some View {
    switch model.summary.status {
    case .ready, .unverified:
      VStack(alignment: .leading, spacing: 0) {
        // Every page sits side by side on one strip that slides as a whole, so the
        // page being left really does exit toward the side the new one arrives from —
        // the row of sheets the horizontal scroll and the dots have always implied.
        PageStripLayout(progress: CGFloat(currentPage)) {
          ForEach(pages) { panelPage in
            panelPage.content
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              // The pages carry animations and transitions of their own; without an
              // isolating group, a child mid-transition keeps rendering against the
              // slot's stale geometry while the strip slides — which is how a pill
              // ghost ended up floating over the artwork.
              .geometryGroup()
              // Each sheet is cut at its own slot: content wider than the page can
              // never bleed into a neighbouring sheet mid-slide, or across the
              // media zone on the way out.
              .clipped()
          }
        }
        // A read-only session still shows every reading, but its controls must not
        // pretend: a write the coordinator will refuse is not offered. The caveat
        // line below says why.
        .disabled(!model.summary.acceptsWrites)

        HStack(spacing: 8) {
          if let caveat = model.summary.caveat {
            Caveat(text: caveat)
          }
          Spacer(minLength: 0)
          PageIndicator(count: pages.count, index: currentPage)
          settingsGear
        }
      }
      .clipped()
      .animation(.easeOut(duration: 0.24), value: page)

    case .noDevice:
      notice(L("対応機器が音声の出力先になっていません", "No supported device is the sound output"))
    case .connecting:
      notice(L("接続しています", "Connecting"))
    case .reading:
      notice(L("機器の情報を読み取っています", "Reading device information"))
    case .takenByAnotherDevice:
      notice(L("別の端末が操作しています", "Another device is in control"), retry: retry)
    case .unreachable:
      notice(L("機器に接続できませんでした", "Could not connect to the device"), retry: retry)
    }
  }

  /// A notice with the same bottom-right gear the sheets carry: the settings must
  /// stay reachable from the panel with nothing connected at all. A retry closure
  /// adds the way back for the states that only move on an explicit ask.
  private func notice(_ text: String, retry: (() async -> Void)? = nil) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Notice(text: text)
      HStack {
        if let retry { RetryButton(action: retry) }
        Spacer(minLength: 0)
        settingsGear
      }
    }
  }

  /// The way into the settings from the panel itself, kept as quiet as the dots it
  /// sits beside.
  @ViewBuilder
  private var settingsGear: some View {
    if let openSettings {
      Button(action: openSettings) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 9))
          .foregroundStyle(.white.opacity(0.45))
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L("設定", "Settings"))
    }
  }

  private var currentPage: Int {
    min(page, max(pages.count - 1, 0))
  }
}

/// Lays the sheets side by side, shifted by the animated page progress.
///
/// Positions come from layout rather than a render transform: each sheet's clip is the
/// frame it was placed in, so slot and content move as one and a sheet can never be
/// drawn outside its slot mid-slide.
private struct PageStripLayout: Layout {
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (index, subview) in subviews.enumerated() {
      subview.place(
        at: CGPoint(x: bounds.minX + (CGFloat(index) - progress) * bounds.width, y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
      )
    }
  }
}

// MARK: - Status

/// Stays on screen for as long as the device is unverified. A warning shown once at
/// connection would be gone by the time anyone actually changes a setting.
private struct Caveat: View {
  let text: String

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 8))
      Text(text)
        .font(.system(size: 9))
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.orange.opacity(0.75))
    .lineLimit(1)
  }
}

private struct Notice: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.5))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

/// The way back beside the notice. Disabled while the ask is in flight, so a double
/// tap cannot fire the retry twice.
private struct RetryButton: View {
  let action: () async -> Void
  @State private var isRetrying = false

  var body: some View {
    Button {
      guard !isRetrying else { return }
      isRetrying = true
      Task {
        await action()
        isRetrying = false
      }
    } label: {
      Text(L("再接続", "Reconnect"))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(isRetrying ? 0.4 : 0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.12)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isRetrying)
  }
}

// MARK: - Now playing

private struct NowPlayingColumn: View {
  let nowPlaying: PanelModel.NowPlaying?
  let transport: NowPlayingTransport?

  /// The transport row's natural width — three 20pt buttons and two 14pt gaps. The
  /// artwork and the text window match it, so the column reads as one block.
  private static let contentWidth: CGFloat = 88

  var body: some View {
    VStack(spacing: 7) {
      // Takes the room the column can spare, up to its full size. On a short panel
      // the artwork gives way instead of pushing the transport into the bottom
      // margin, so the air under the controls stays equal to the air above the
      // artwork — the two gaps mirror each other.
      Color.clear
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.contentWidth, maxHeight: Self.contentWidth)
        .overlay { artwork }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(helpText)

      // No seek bar: nothing here can seek, and a bar that only looks draggable is a
      // promise the panel cannot keep. The title and artist say something instead.
      if nowPlaying?.title != nil || nowPlaying?.artist != nil {
        VStack(spacing: 1) {
          if let title = nowPlaying?.title {
            MarqueeText(
              text: title,
              font: .system(size: 10, weight: .medium),
              color: .white.opacity(0.92)
            )
          }
          if let artist = nowPlaying?.artist {
            MarqueeText(
              text: artist,
              font: .system(size: 9),
              color: .white.opacity(0.55)
            )
          }
        }
        .frame(width: Self.contentWidth)
      }

      // Right under the title: the controls belong to the block, not to the panel's
      // foot — on a tall panel the leftover space stays below them.
      HStack(spacing: 14) {
        TransportButton(
          symbol: "backward.fill",
          label: L("前の曲", "Previous track"),
          action: transport?.previous
        )
        TransportButton(
          symbol: (nowPlaying?.isPlaying ?? false) ? "pause.fill" : "play.fill",
          label: (nowPlaying?.isPlaying ?? false) ? L("一時停止", "Pause") : L("再生", "Play"),
          action: transport?.playPause
        )
        TransportButton(
          symbol: "forward.fill",
          label: L("次の曲", "Next track"),
          action: transport?.next
        )
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// The album art when the player gives a URL for it, a music-note placeholder while it
  /// loads or when there is none.
  @ViewBuilder
  private var artwork: some View {
    if let string = nowPlaying?.artworkURL, let url = URL(string: string) {
      AsyncImage(url: url) { phase in
        if let image = phase.image {
          image.resizable().aspectRatio(contentMode: .fill)
        } else {
          artworkPlaceholder
        }
      }
    } else {
      artworkPlaceholder
    }
  }

  private var artworkPlaceholder: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(.white.opacity(0.12))
      .overlay {
        Image(systemName: "music.note")
          .font(.system(size: 24))
          .foregroundStyle(.white.opacity(0.35))
      }
  }

  private var helpText: String {
    [nowPlaying?.title, nowPlaying?.artist].compactMap(\.self).joined(separator: " — ")
  }
}

private struct TransportButton: View {
  let symbol: String
  /// What the symbol means, for assistive technologies — the image alone says nothing.
  let label: String
  let action: (() -> Void)?

  var body: some View {
    Button { action?() } label: {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .accessibilityLabel(label)
  }
}

/// Text that stays put when it fits and glides sideways when it does not, so a long
/// title is read in passing rather than cut at the edge.
///
/// Two copies chase each other around a loop, the classic marquee: the seam never
/// shows because the second copy enters before the first has fully left.
private struct MarqueeText: View {
  let text: String
  let font: Font
  let color: Color

  @State private var textWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @State private var isGliding = false

  /// The pause before the glide, so a fresh title can be read from its start.
  private static let initialHold: Double = 1.2
  /// Points per second: a stroll, not a ticker.
  private static let speed: CGFloat = 20
  private static let gap: CGFloat = 24

  private var overflows: Bool { textWidth > containerWidth + 0.5 }

  /// The layout is owned by a single truncating line, sized by the window it is given
  /// and never by the string. The gliding copies are drawn in an overlay, which cannot
  /// widen the row, and everything outside the window is masked away — the string
  /// passes across a fixed opening rather than stretching it.
  var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(color)
      .lineLimit(1)
      .opacity(overflows ? 0 : 1)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .leading) {
        if overflows {
          HStack(spacing: Self.gap) {
            Text(text).font(font).foregroundStyle(color).fixedSize()
            Text(text).font(font).foregroundStyle(color).fixedSize()
          }
          .offset(x: isGliding ? -(textWidth + Self.gap) : 0)
        }
      }
      .background {
        // The natural width, measured off an invisible copy so the visible one can be
        // truncated without losing the number the loop is timed by.
        Text(text).font(font).fixedSize()
          .hidden()
          .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
      }
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { containerWidth = $0 }
      .mask(edgeFade)
      .clipped()
      .task(id: "\(text)|\(overflows)") {
      // A new title starts at rest, whatever the previous one was doing.
      var still = Transaction()
      still.disablesAnimations = true
      withTransaction(still) { isGliding = false }

      guard overflows else { return }
      try? await Task.sleep(for: .seconds(Self.initialHold))
      guard !Task.isCancelled else { return }
      withAnimation(
        .linear(duration: (textWidth + Self.gap) / Self.speed).repeatForever(autoreverses: false)
      ) {
        isGliding = true
      }
    }
  }

  /// Soft edges, so the text slips out of the window instead of being cut. The leading
  /// edge only fades once the glide starts — at rest the head of the string is what is
  /// being read — while the trailing edge fades whenever there is more to come.
  private var edgeFade: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
        .frame(width: isGliding ? 6 : 0)
      Rectangle().fill(.black)
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: overflows ? 6 : 0)
    }
  }
}

// MARK: - Header

/// The device name, one pair of texts serving both the closed bar and the open header.
///
/// Closed, the pair stacks at the series hyphen: a single line would have to be
/// truncated to fit beside the cutout, and the characters that tell one model from
/// another come after the hyphen. Open, the same two texts slide onto one line —
/// series first — and grow to header size on the way.
private struct MorphingDeviceName: View {
  let name: String?
  /// 0 closed, 1 open. Set discretely; the layout and fonts animate through it.
  let progress: CGFloat

  var body: some View {
    if let name, !name.isEmpty {
      let parts = HeaderTitleMorph.split(name)
      if parts.series.isEmpty {
        modelText(parts.model)
      } else {
        TitleMorphLayout(progress: progress) {
          Text(parts.series)
            .modifier(MorphingFont(size: 8 + 4 * progress))
            .foregroundStyle(.white.opacity(0.55 + 0.45 * min(progress, 1)))
          modelText(parts.model)
        }
        .lineLimit(1)
      }
    }
    // No name, nothing shown: the sheet already says why there is no device, and a
    // dash where a name should be reads as a stray mark, not as an explanation.
  }

  private func modelText(_ model: String) -> some View {
    Text(model)
      .modifier(MorphingFont(size: 10 + 2 * progress))
      .foregroundStyle(.white.opacity(0.92 + 0.08 * min(progress, 1)))
      .lineLimit(1)
  }
}

/// Lays the two halves of the name out by the morph geometry, animating the progress
/// so the halves travel between the stacked and the one-line arrangements.
private struct TitleMorphLayout: Layout {
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    placement(for: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 2 else { return }
    let placement = placement(for: subviews)
    subviews[0].place(
      at: CGPoint(x: bounds.minX + placement.series.x, y: bounds.minY + placement.series.y),
      anchor: .topLeading,
      proposal: .unspecified
    )
    subviews[1].place(
      at: CGPoint(x: bounds.minX + placement.model.x, y: bounds.minY + placement.model.y),
      anchor: .topLeading,
      proposal: .unspecified
    )
  }

  private func placement(for subviews: Subviews) -> HeaderTitleMorph.Placement {
    HeaderTitleMorph.placement(
      series: subviews.first.map { $0.sizeThatFits(.unspecified) } ?? .zero,
      model: subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero,
      progress: progress
    )
  }
}

/// Animates the point size itself, so the text is re-set at every intermediate size
/// instead of being stretched as a picture of its two endpoints.
private struct MorphingFont: ViewModifier, Animatable {
  var size: CGFloat

  // The animation system reads this off the main actor; the plain value it exchanges
  // is safe to hand over from anywhere.
  nonisolated var animatableData: CGFloat {
    get { size }
    set { size = newValue }
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: .semibold))
  }
}

/// The charge readout, one instance serving both the closed bar and the open header.
/// The case's charge only earns its place when the panel has room for it, so it joins
/// and leaves with the opening.
private struct BatteryReadout: View {
  let battery: BatteryLayout
  let isExpanded: Bool

  var body: some View {
    HStack(spacing: isExpanded ? 10 : 8) {
      switch battery {
      case .single(let value):
        BatteryPip(label: nil, value: value, symbol: "battery.100")
      case .leftRight(let left, let right, let charging):
        BatteryPip(label: "L", value: left, isExpanded: isExpanded)
        BatteryPip(label: "R", value: right, isExpanded: isExpanded)
        if isExpanded, let charging {
          BatteryPip(label: nil, value: charging, symbol: "case", isExpanded: isExpanded)
            .transition(.opacity)
        }
      case .unknown:
        EmptyView()
      }
    }
  }
}

struct BatteryPip: View {
  let label: String?
  let value: Int?
  var symbol: String?
  /// Closed, a labelled L/R pip stacks to stay narrow; open, there is room, so it keeps
  /// the side-by-side layout.
  var isExpanded: Bool = false

  /// Below 20% the charge is shown in red; at 5% or less it also pulses, so a nearly
  /// empty earbud is hard to miss. Unknown ("—") is never treated as low.
  private var isLow: Bool { (value ?? 100) < 20 }
  private var isCritical: Bool { (value ?? 100) <= 5 }

  var body: some View {
    if let label, !isExpanded {
      // The L/R earbud charges stack — side label above, charge below — so each column
      // is only as wide as the number, keeping the pair clear of the notch cutout. Each
      // L/R column is its own view, so the two charges update and animate independently.
      VStack(spacing: 1) {
        labelText(label)
        chargeText
      }
    } else {
      HStack(spacing: 3) {
        if let symbol {
          Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.5))
        } else if let label {
          labelText(label)
        }
        chargeText
      }
    }
  }

  private func labelText(_ label: String) -> some View {
    Text(label)
      .font(.system(size: isExpanded ? 9 : 8, weight: .medium))
      .foregroundStyle(.white.opacity(0.5))
  }

  /// A fixed width holds the position steady whether the charge is one digit or three,
  /// so "5" and "100" sit in the same place rather than shifting the layout.
  private var chargeText: some View {
    // Closed, the charge matches the model line of the device name (10pt); open, it
    // keeps the slightly larger size the roomier header carries.
    Text(value.map { "\($0)" } ?? "—")
      .font(.system(size: isExpanded ? 11 : 10, weight: .medium).monospacedDigit())
      .foregroundStyle(isLow ? Color.red : Color.white.opacity(0.9))
      .lineLimit(1)
      // Wide enough for a full "100" at either size; wrapping a charge onto two
      // lines is worse than the extra points of width.
      .frame(width: isExpanded ? 23 : 21, alignment: .center)
      .modifier(BatteryPulse(active: isCritical))
  }
}

/// Pulses the charge while it is critically low, driven by the clock rather than view
/// lifecycle so a redraw of the pip does not restart or stall the blink.
private struct BatteryPulse: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      TimelineView(.animation) { context in
        let phase = 0.5 + 0.5 * cos(context.date.timeIntervalSinceReferenceDate * 2 * .pi)
        content.opacity(0.2 + 0.8 * phase)
      }
    } else {
      content
    }
  }
}

// MARK: - Pages

struct PanelPage: Identifiable {
  let id: String
  let content: AnyView
}

/// Horizontal, and on the same line as the caveat, so it reads as part of the panel
/// rather than as marks floating beside it.
private struct PageIndicator: View {
  let count: Int
  let index: Int

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<count, id: \.self) { position in
        Circle()
          .fill(.white.opacity(position == index ? 0.85 : 0.22))
          .frame(width: 4, height: 4)
      }
    }
    .animation(.easeOut(duration: 0.15), value: index)
  }
}
