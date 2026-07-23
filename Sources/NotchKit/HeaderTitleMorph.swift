import CoreGraphics

/// Where the two halves of a split device name sit, from the stacked pair the closed
/// bar shows to the single line the expanded header shows.
///
/// The same pair of texts is drawn in both states; only these positions and the font
/// sizes change. That is what makes the expansion read as the closed label growing
/// into the header, rather than one label being swapped for another.
public enum HeaderTitleMorph {
  /// Splits after the first hyphen. Names without one keep the whole string on the
  /// model line rather than being cut at an arbitrary character.
  public static func split(_ name: String) -> (series: String, model: String) {
    guard let hyphen = name.firstIndex(of: "-") else { return ("", name) }
    let series = String(name[name.startIndex...hyphen])
    let model = String(name[name.index(after: hyphen)...])
    return model.isEmpty ? ("", name) : (series, model)
  }

  public struct Placement: Equatable, Sendable {
    /// Top-leading origins within `size`.
    public let series: CGPoint
    public let model: CGPoint
    public let size: CGSize
  }

  /// Positions for a given animation progress: 0 is the stacked closed label, 1 the
  /// one-line header. Values outside 0...1 extrapolate, so a spring's overshoot keeps
  /// the halves moving instead of clamping them at the endpoint mid-bounce.
  public static func placement(
    series: CGSize,
    model: CGSize,
    lineOverlap: CGFloat = 1,
    progress: CGFloat
  ) -> Placement {
    // Stacked: series over model, left-aligned, the lines pulled together slightly.
    let closedModel = CGPoint(x: 0, y: series.height - lineOverlap)
    let closedSize = CGSize(
      width: max(series.width, model.width),
      height: series.height + model.height - lineOverlap
    )

    // One line: series first, each half centred on the taller one's line.
    let lineHeight = max(series.height, model.height)
    let openSeries = CGPoint(x: 0, y: (lineHeight - series.height) / 2)
    let openModel = CGPoint(x: series.width, y: (lineHeight - model.height) / 2)
    let openSize = CGSize(width: series.width + model.width, height: lineHeight)

    return Placement(
      series: lerp(.zero, openSeries, progress),
      model: lerp(closedModel, openModel, progress),
      size: CGSize(
        width: lerp(closedSize.width, openSize.width, progress),
        height: lerp(closedSize.height, openSize.height, progress)
      )
    )
  }

  private static func lerp(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lerp(from.x, to.x, t), y: lerp(from.y, to.y, t))
  }

  private static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
    from + (to - from) * t
  }
}
