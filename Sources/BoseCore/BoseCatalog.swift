import Foundation

/// A recognised model: the USB-style product id it announces, a human name, its
/// internal codename, and the config that drives every protocol decision for it.
public struct BoseDeviceModel: Equatable, Sendable {
  public let productId: UInt16
  public let codename: String
  public let productName: String
  public let config: BoseDeviceConfig

  public init(productId: UInt16, codename: String, productName: String, config: BoseDeviceConfig) {
    self.productId = productId
    self.codename = codename
    self.productName = productName
    self.config = config
  }
}

/// Maps a product id to the model that owns it.
///
/// Only the four models the frozen spec confirmed at byte level are listed; the
/// roughly thirty others are recognised as Bose (`vendorId`) but not yet supported,
/// so a lookup returns `nil` rather than throwing. For an unknown id a caller uses
/// `fallbackConfig`, the Ultra 2 profile the spec names as the provisional default,
/// so the app degrades instead of failing on a device it has not been taught.
public enum BoseCatalog {
  /// Bose's vendor id in the USB Implementer's Forum numbering. Shared by every model, so
  /// it identifies the maker but never a specific device.
  public static let vendorId: UInt16 = 0x05A7

  /// Bose's company id in the Bluetooth SIG numbering — the *other* namespace a Device ID
  /// record may declare (its VendorIDSource says which). Not interchangeable with
  /// `vendorId`: the same maker has a different number in each, and a QC Ultra Earbuds was
  /// seen announcing this one, so checking only the USB id refuses a genuine Bose device.
  public static let bluetoothSIGVendorId: UInt16 = 0x009E

  /// Whether `vendorId` names Bose in the numbering `source` declares. A Device ID record
  /// uses 1 for the Bluetooth SIG list and 2 for the USB one; when it declares neither,
  /// either number is accepted, since one of them is still Bose and nothing else is.
  public static func isBoseVendor(_ vendorId: UInt16, source: UInt16?) -> Bool {
    switch source {
    case 1: vendorId == bluetoothSIGVendorId
    case 2: vendorId == self.vendorId
    default: vendorId == bluetoothSIGVendorId || vendorId == self.vendorId
    }
  }

  private static let models: [UInt16: BoseDeviceModel] = [
    0x4082: BoseDeviceModel(
      productId: 0x4082,
      codename: "wolverine",
      productName: "QC Ultra Headphones (2nd Gen)",
      config: .qcUltra2
    ),
    0x4062: BoseDeviceModel(
      productId: 0x4062,
      codename: "edith",
      productName: "QC Ultra Earbuds (2nd Gen)",
      config: .qcUltra2Earbuds
    ),
    // Verified on hardware rather than taken from the reference list: a unit announcing
    // this id (SIG vendor 0x009E, name "Bose QC Ultra Earbuds") completed a full BMAP
    // session — device name, firmware, four-byte-per-component battery, [1.5] noise
    // cancellation, block 31 modes and the three-band equalizer all read back. So it
    // speaks the Ultra 2 dialect, and being earbuds it carries no wind reduction.
    0x4072: BoseDeviceModel(
      productId: 0x4072,
      codename: "edith",
      productName: "QC Ultra Earbuds",
      config: .qcUltra2Earbuds
    ),
    0x4020: BoseDeviceModel(
      productId: 0x4020,
      codename: "baywolf",
      productName: "QuietComfort 35 II",
      config: .qc35
    ),
    0x400C: BoseDeviceModel(
      productId: 0x400C,
      codename: "wolfcastle",
      productName: "QuietComfort 35",
      config: .qc35
    ),
  ]

  /// The provisional profile for an unrecognised id, per the frozen spec.
  public static let fallbackConfig: BoseDeviceConfig = .qcUltra2

  /// The model for a product id, or `nil` when it is not one of the supported four.
  public static func model(forProductId productId: UInt16) -> BoseDeviceModel? {
    models[productId]
  }

  /// The config for a product id, falling back to the provisional profile when the id
  /// is unknown so the app can still attempt to talk to the device.
  public static func config(forProductId productId: UInt16) -> BoseDeviceConfig {
    models[productId]?.config ?? fallbackConfig
  }

  /// Whether the id is one of the models this stage supports.
  public static func isSupported(productId: UInt16) -> Bool {
    models[productId] != nil
  }
}
