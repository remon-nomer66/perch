import AppKit
import BoseCore
import BosePanel
import DeviceContract
import SwiftUI

/// A tiny, hardware-free tool that renders the Bose panel to PNG from synthetic data, so
/// the layout can be reviewed without a device or the app running. It touches no Bluetooth
/// and starts no session — it only builds a `BosePanelState` from frozen-spec fixture
/// values and hands SwiftUI views to `ImageRenderer`.
///
/// Run: `swift run bose-panel-preview [output-directory]`.
@main
struct BosePanelPreviewApp {
  @MainActor
  static func main() {
    let outputDirectory = CommandLine.arguments.count > 1
      ? CommandLine.arguments[1]
      : defaultOutputDirectory
    try? FileManager.default.createDirectory(
      atPath: outputDirectory, withIntermediateDirectories: true
    )

    let state = BosePanelState.project(from: fixtureSnapshot, config: .qcUltra2)
    let pages = BosePanelPageID.allCases

    // One PNG per page, so each sheet can be reviewed on its own.
    for (index, page) in pages.enumerated() {
      render(
        panel(state: state, page: index),
        size: CGSize(width: panelWidth + backdropPad * 2, height: panelHeight + backdropPad * 2),
        to: outputDirectory, name: "bose-panel-\(page.rawValue)"
      )
    }

    // The whole expanded panel: every page stacked into one tall image.
    render(
      fullStack(state: state),
      size: CGSize(
        width: panelWidth + backdropPad * 2,
        height: CGFloat(pages.count) * panelHeight
          + CGFloat(pages.count - 1) * stackGap + backdropPad * 2
      ),
      to: outputDirectory, name: "bose-panel-full"
    )

    // The closed notch bar.
    render(
      backdrop {
        BoseClosedBar(state: state).frame(width: closedWidth, height: closedHeight)
      },
      size: CGSize(width: closedWidth + backdropPad * 2, height: closedHeight + backdropPad * 2),
      to: outputDirectory, name: "bose-panel-closed"
    )

    print("Wrote Bose panel previews to \(outputDirectory)")
  }

  // MARK: - Fixture (frozen-spec observed values)

  /// The values the frozen spec records from the test unit: CNC current 5 of 0...10,
  /// EQ Bass 0 / Mid -2 / Treble -6, battery 80%, ANC on with wind off, spatial head-
  /// tracked, Quiet selected, sidetone medium. No device is contacted — these are the
  /// documented captures, not a live read.
  static var fixtureSnapshot: BoseDeviceSnapshot {
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
          BoseAudioMode(slot: 1, name: "Aware", isEditable: false),
          BoseAudioMode(slot: 2, name: "Immersion", isEditable: false),
          BoseAudioMode(slot: 3, name: "Cinema", isEditable: false),
          BoseAudioMode(slot: 4, name: "Home", isEditable: true),
        ],
        selectedSlot: 0
      ),
      sidetone: .medium,
      isControllable: true,
      acceptsWrites: true
    )
  }

  // MARK: - Layout metrics

  static let panelWidth: CGFloat = 640
  static let panelHeight: CGFloat = 200
  static let closedWidth: CGFloat = 260
  static let closedHeight: CGFloat = 32
  static let backdropPad: CGFloat = 20
  static let stackGap: CGFloat = 14

  // MARK: - Composition

  @MainActor
  static func panel(state: BosePanelState, page: Int) -> some View {
    backdrop {
      BosePanelView(state: state, page: page)
        .frame(width: panelWidth, height: panelHeight)
    }
  }

  @MainActor
  static func fullStack(state: BosePanelState) -> some View {
    backdrop {
      VStack(spacing: stackGap) {
        ForEach(Array(BosePanelPageID.allCases.enumerated()), id: \.offset) { index, _ in
          BosePanelView(state: state, page: index)
            .frame(width: panelWidth, height: panelHeight)
        }
      }
    }
  }

  /// A neutral dark backdrop so the panel's rounded black shape reads against it.
  @MainActor
  static func backdrop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(backdropPad)
      .background(Color(white: 0.10))
  }

  // MARK: - Rendering

  @MainActor
  static func render(_ view: some View, size: CGSize, to directory: String, name: String) {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 2
    guard let cgImage = renderer.cgImage else {
      print("render failed: \(name)")
      return
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
      print("encode failed: \(name)")
      return
    }
    let path = (directory as NSString).appendingPathComponent("\(name).png")
    try? data.write(to: URL(fileURLWithPath: path))
  }

  static let defaultOutputDirectory =
    "/private/tmp/claude-501/-Users-lemon1366-Development-sound-connect-mac/9934d141-6495-4dc1-8abc-8e83bcd54db6/tmp"
}

// MARK: - Closed bar convenience

extension BoseClosedBar {
  /// Builds the closed bar from a projected panel state.
  init(state: BosePanelState) {
    self.init(modelName: state.modelName, battery: state.battery)
  }
}
