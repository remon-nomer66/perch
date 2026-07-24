import Foundation

/// 空間化の設定一式。UI が束縛し、描画層が消費する不変値。
///
/// 更新は既存を書き換えず、変更を反映した新しい値を返す（不変パターン）。これにより
/// オーディオスレッドと UI スレッドの間で設定を安全に受け渡せる。
public struct SpatialAudioParameters: Equatable, Sendable {
  /// 空間化を有効にするか。無効なら素の音をそのまま流す。
  public let isEnabled: Bool
  /// 左右の仮想スピーカー配置。
  public let field: StereoField
  /// レンダリング品質。
  public let quality: SpatialRenderingQuality

  public init(
    isEnabled: Bool = false,
    field: StereoField = StereoField(),
    quality: SpatialRenderingQuality = .standard
  ) {
    self.isEnabled = isEnabled
    self.field = field
    self.quality = quality
  }

  /// 有効・無効を切り替えた新しい設定を返す。
  public func setting(enabled: Bool) -> SpatialAudioParameters {
    SpatialAudioParameters(isEnabled: enabled, field: field, quality: quality)
  }

  /// スピーカー配置を差し替えた新しい設定を返す。
  public func setting(field: StereoField) -> SpatialAudioParameters {
    SpatialAudioParameters(isEnabled: isEnabled, field: field, quality: quality)
  }

  /// 品質を差し替えた新しい設定を返す。
  public func setting(quality: SpatialRenderingQuality) -> SpatialAudioParameters {
    SpatialAudioParameters(isEnabled: isEnabled, field: field, quality: quality)
  }
}
