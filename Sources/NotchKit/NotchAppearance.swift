import CoreGraphics
import Foundation

/// Sizes the notch panel is drawn with.
///
/// Adjustable because the physical notch differs between models, and because how far
/// the extension should reach depends on how crowded the surrounding menu bar is. A
/// value that suits one machine looks wrong on the next.
public struct NotchAppearance: Codable, Equatable, Sendable {
  /// How far the closed bar reaches past the notch on each side.
  public var leadingExtension: CGFloat
  public var trailingExtension: CGFloat
  /// Added below the notch so the bar can be taller than the cutout.
  public var closedHeightIncrease: CGFloat
  /// The height of the sliver a virtual notch rests at on a screen with no cutout of
  /// its own. Ignored where the display has a real notch, whose height the hardware
  /// fixes; only the synthesised notch is drawn this thin until it is looked at.
  public var restingHeight: CGFloat

  public var expandedWidth: CGFloat
  public var expandedHeight: CGFloat

  public var closedBottomCornerRadius: CGFloat
  public var expandedBottomCornerRadius: CGFloat
  public var topCornerRadius: CGFloat

  public static let `default` = NotchAppearance(
    leadingExtension: 76,
    trailingExtension: 52,
    closedHeightIncrease: 0,
    restingHeight: restingHeightDefault,
    expandedWidth: 640,
    expandedHeight: 200,
    closedBottomCornerRadius: 12,
    expandedBottomCornerRadius: 22,
    topCornerRadius: 10
  )

  /// Named so the migrating decoder can reuse it: an archive saved before resting
  /// height existed fills the gap with this rather than being discarded whole.
  private static let restingHeightDefault: CGFloat = 10

  public static let limits = Limits()

  public struct Limits: Sendable {
    public let sideExtension: ClosedRange<CGFloat> = 0...260
    public let closedHeightIncrease: ClosedRange<CGFloat> = 0...24
    public let restingHeight: ClosedRange<CGFloat> = 4...32
    public let expandedWidth: ClosedRange<CGFloat> = 360...1100
    public let expandedHeight: ClosedRange<CGFloat> = 120...420
    public let cornerRadius: ClosedRange<CGFloat> = 0...40
  }

  public init(
    leadingExtension: CGFloat,
    trailingExtension: CGFloat,
    closedHeightIncrease: CGFloat,
    restingHeight: CGFloat,
    expandedWidth: CGFloat,
    expandedHeight: CGFloat,
    closedBottomCornerRadius: CGFloat,
    expandedBottomCornerRadius: CGFloat,
    topCornerRadius: CGFloat
  ) {
    let limits = Limits()
    self.leadingExtension = leadingExtension.clamped(to: limits.sideExtension)
    self.trailingExtension = trailingExtension.clamped(to: limits.sideExtension)
    self.closedHeightIncrease = closedHeightIncrease.clamped(to: limits.closedHeightIncrease)
    self.restingHeight = restingHeight.clamped(to: limits.restingHeight)
    self.expandedWidth = expandedWidth.clamped(to: limits.expandedWidth)
    self.expandedHeight = expandedHeight.clamped(to: limits.expandedHeight)
    self.closedBottomCornerRadius = closedBottomCornerRadius.clamped(to: limits.cornerRadius)
    self.expandedBottomCornerRadius = expandedBottomCornerRadius.clamped(to: limits.cornerRadius)
    self.topCornerRadius = topCornerRadius.clamped(to: limits.cornerRadius)
  }

  private enum CodingKeys: String, CodingKey {
    case leadingExtension
    case trailingExtension
    case closedHeightIncrease
    case restingHeight
    case expandedWidth
    case expandedHeight
    case closedBottomCornerRadius
    case expandedBottomCornerRadius
    case topCornerRadius
  }

  /// Routed through the clamping initializer above. The stored archive is external
  /// data like any other — a corrupted or hand-edited value must not size the panel
  /// negative or absurd, and the synthesized decoder would assign raw values straight
  /// to the properties, past the limits.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      leadingExtension: try values.decode(CGFloat.self, forKey: .leadingExtension),
      trailingExtension: try values.decode(CGFloat.self, forKey: .trailingExtension),
      closedHeightIncrease: try values.decode(CGFloat.self, forKey: .closedHeightIncrease),
      // Absent in archives predating this field: fill it rather than fail the whole
      // decode, so an upgrade keeps every other size the owner had already tuned.
      restingHeight: try values.decodeIfPresent(CGFloat.self, forKey: .restingHeight)
        ?? Self.restingHeightDefault,
      expandedWidth: try values.decode(CGFloat.self, forKey: .expandedWidth),
      expandedHeight: try values.decode(CGFloat.self, forKey: .expandedHeight),
      closedBottomCornerRadius: try values.decode(CGFloat.self, forKey: .closedBottomCornerRadius),
      expandedBottomCornerRadius: try values.decode(
        CGFloat.self, forKey: .expandedBottomCornerRadius
      ),
      topCornerRadius: try values.decode(CGFloat.self, forKey: .topCornerRadius)
    )
  }

  /// The thin sliver a virtual notch rests at, in screen coordinates: the top
  /// `restingHeight` of the notch region, hugging the screen edge. The whole of it is
  /// the pointer's target, and left alone it is all that is drawn.
  public func restingSliver(in notch: CGRect) -> CGRect {
    CGRect(
      x: notch.minX,
      y: notch.maxY - restingHeight,
      width: notch.width,
      height: restingHeight
    )
  }

  /// The bar drawn while closed, in screen coordinates.
  public func closedRect(around notch: CGRect) -> CGRect {
    CGRect(
      x: notch.minX - leadingExtension,
      y: notch.minY - closedHeightIncrease,
      width: notch.width + leadingExtension + trailingExtension,
      height: notch.height + closedHeightIncrease
    )
  }

  public var expandedSize: CGSize {
    CGSize(width: expandedWidth, height: expandedHeight)
  }
}

extension CGFloat {
  fileprivate func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}

/// Keeps the chosen sizes across launches.
@MainActor
public final class NotchAppearanceStore: ObservableObject {
  @Published public var appearance: NotchAppearance {
    didSet { save() }
  }

  private let defaults: UserDefaults
  private let key = "NotchAppearance"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key),
      let stored = try? JSONDecoder().decode(NotchAppearance.self, from: data)
    {
      appearance = stored
    } else {
      appearance = .default
    }
  }

  public func reset() {
    appearance = .default
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(appearance) else { return }
    defaults.set(data, forKey: key)
  }
}
