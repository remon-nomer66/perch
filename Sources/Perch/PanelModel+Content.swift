extension PanelModel {
  /// Whether the bar has anything to carry, the condition it widens by. Being
  /// controllable is not enough: right after a disconnect — or before the first read
  /// lands — the session can count as controllable while neither a name nor a charge
  /// exists yet, and widening then shows an empty slab where the bare notch should be.
  ///
  /// One definition for every reader. The view widens the bar by it, the hover target
  /// follows it, and its rising edge opens the arrival announcement; three copies of
  /// it were three chances for the bar on screen and the bar that answers to disagree.
  var hasContent: Bool {
    summary.isControllable && (summary.modelName != nil || battery != .unknown)
  }
}
