import BosePanel

extension PanelModel {
  /// This panel with the Bose readout folded in, when Bose owns it.
  ///
  /// The *only* place device ownership is decided: Sony while it has a controllable
  /// device, otherwise a Bose device that is the current audio output. Both sessions can
  /// be live at once — the Sony session targets any identified output, whatever its
  /// brand — so `isBose` is the answer every screen reads, rather than each judging by
  /// which session happens to be open. The notch and the settings window used to judge
  /// separately (settings on `bose.panelModel != nil` alone), and with both sessions live
  /// one drew Sony while the other drew Bose.
  ///
  /// The readout is `nil` once the Bose device is gone (every teardown clears it), so a
  /// device that left the output cannot keep owning the panel.
  func foldingIn(bose readout: BoseDeviceController.Readout?) -> PanelModel {
    guard !summary.isControllable, let readout else { return self }
    var owned = self
    owned.summary.status = readout.status
    owned.summary.modelName = readout.modelName
    owned.summary.firmwareVersion = readout.firmwareVersion
    // Ultra 2 accepts the live noise-control and equalizer writes the Bose panel sends,
    // so the header shows no read-only caveat — matching the writable Bose controls.
    owned.summary.acceptsWrites = true
    owned.battery = readout.battery
    owned.isBose = true
    return owned
  }
}

/// Whose device controls a screen draws: the live Bose panel, the Sony pages, or neither.
///
/// Read from the one ownership answer (`PanelModel.isBose`) and whether a live Bose panel
/// exists, by the notch and the settings window alike. Bose ownership with no live panel
/// behind it — connecting, unreachable — draws neither brand. The settings window used to
/// fall through from "Bose with a panel" to "is anything controllable", so a Bose readout
/// left saying `.ready` drew Sony's controls under the Bose device's header (#10).
enum DeviceControls: Equatable {
  case bose(BosePanelModel)
  case sony
  case neither

  init(panel: PanelModel, bosePanel: BosePanelModel?) {
    if panel.isBose {
      self = bosePanel.map(DeviceControls.bose) ?? .neither
    } else {
      self = panel.summary.isControllable ? .sony : .neither
    }
  }

  var isBose: Bool {
    if case .bose = self { return true }
    return false
  }

  /// Whether the Sony device sheets belong on screen. Only for Sony's own device: under
  /// Bose they would draw nothing but "not declared".
  var drawsSonyPages: Bool { self == .sony }

  static func == (lhs: DeviceControls, rhs: DeviceControls) -> Bool {
    switch (lhs, rhs) {
    case (.bose(let left), .bose(let right)): left === right
    case (.sony, .sony), (.neither, .neither): true
    default: false
    }
  }
}
