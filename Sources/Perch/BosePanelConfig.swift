import BoseCore

extension BoseDeviceController {
  /// The config the Bose panel draws from, given the one the session talks with.
  ///
  /// A catalogued product id settles it: one config drives both the wire and the panel,
  /// and the device's name is not looked at. Only a device the catalog does not know — by
  /// an unlisted id, or by announcing none — has its reported name consulted, and then
  /// only to take away a display axis the hardware decides and the wire does not: wind
  /// reduction, which earbuds lack though their [31.10] payload carries the byte. The
  /// provisional Ultra 2 profile such a device falls back to offers it, so unlisted
  /// earbuds would show a switch for hardware they do not have.
  ///
  /// The name is localisable and renamable, which is why it never decides the model when
  /// an id can; as the backstop for a device nothing else describes, it is still the best
  /// signal there is. It never changes the wire dialect.
  nonisolated static func panelConfig(
    wire: BoseDeviceConfig,
    productId: UInt16?,
    modelName: String?
  ) -> BoseDeviceConfig {
    let catalogued = productId.map(BoseCatalog.isSupported(productId:)) ?? false
    guard !catalogued, wire.supportsWindReduction,
      let name = modelName?.lowercased(),
      name.contains("earbud") || name.contains("buds")
    else { return wire }
    return BoseDeviceConfig(
      rfcommChannel: wire.rfcommChannel,
      initializeAddress: wire.initializeAddress,
      features: wire.features,
      batteryLayout: wire.batteryLayout,
      editableSlots: wire.editableSlots,
      presetSlots: wire.presetSlots,
      supportsWindReduction: false
    )
  }
}
