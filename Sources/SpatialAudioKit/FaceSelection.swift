import CoreGraphics

/// どの顔を追うかの決め。較正した本人に位置連続性で張り付き、フレーム間で
/// 別人へ飛ばない（「最大の顔」は近くを通った人に切り替わってしまう）。
public enum FaceSelection {
  /// 前フレームで追っていた顔枠に最も近い候補を選ぶ。
  ///
  /// - previous が nil（初回・見失い後の取り直し）は最大の顔から始める。
  /// - 最も近い候補でも中心距離が `maxCenterDistance`（正規化座標）を超えるなら、
  ///   それは別人か誤検出なので nil（ロスト扱い）。
  public static func index(
    of boxes: [CGRect],
    previous: CGRect?,
    maxCenterDistance: CGFloat = 0.25
  ) -> Int? {
    guard !boxes.isEmpty else { return nil }
    guard let previous else {
      return boxes.indices.max { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }
    }
    let center = CGPoint(x: previous.midX, y: previous.midY)
    let distances = boxes.map { hypot($0.midX - center.x, $0.midY - center.y) }
    guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }),
      distances[best] <= maxCenterDistance
    else { return nil }
    return best
  }
}
