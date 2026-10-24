extension PanelModel {
  /// Whether rules can act on the device that owns the panel right now.
  ///
  /// A rule's actions are the Sony session's own vocabulary — a noise state, an equaliser
  /// *preset identifier* the device declared, a listening mode — and `applyRule` writes
  /// them through that session alone. None of it reaches a Bose device, so while Bose owns
  /// the panel a rule can be neither applied nor meaningfully written.
  var supportsRules: Bool { summary.isControllable && !isBose }

  /// Why the rule editor is withheld, for the notice shown in its place.
  ///
  /// "This device does not support rules" only while that device is actually connected.
  /// Bose owns the panel while it is still connecting or has failed too, and judged on
  /// ownership alone the notice warned about a device nobody could reach; with nothing
  /// connected, the reason is the one `supportsRules` is waiting on — a device.
  var ruleUnavailableReason: RuleEditorUnavailableNotice.Reason {
    isBose && summary.isControllable
      ? .unsupportedDevice(modelName: summary.modelName)
      : .noDevice
  }
}
