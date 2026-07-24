import Foundation

/// HRTF レンダリングの品質段階。
///
/// AVAudio3DMixingRenderingAlgorithm への対応付けは描画層で行い、この型自体は
/// フレームワークに依存しないでおく。品質と CPU 負荷はトレードオフの関係にある。
public enum SpatialRenderingQuality: Equatable, Sendable, CaseIterable {
  /// 標準の HRTF。品質と負荷のバランス。既定。
  case standard
  /// 高品質 HRTF。定位・周波数特性が良い代わりに CPU 負荷が高い。
  case high
  /// 両耳間時間差ベースの軽量な球面頭モデル。負荷は最小だが定位は粗い。
  case light
}
