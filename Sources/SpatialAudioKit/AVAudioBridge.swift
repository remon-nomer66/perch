import AVFoundation

// フレームワーク非依存の核を、AVAudioEnvironmentNode が要求する AVFoundation の型へ
// 変換する境界。単位・軸・列挙の対応付けをここ1か所に集める。

extension SphericalDirection {
  /// AVAudioEnvironmentNode の入力に与える3D座標。`cartesian` を Float にするだけ。
  ///
  /// 軸の割り当て（正面=-Z）が環境ノードの実際の向きと合うかは、統合時に実機で
  /// 左右・前後の聞こえを確かめて最終決定する（描画層の責務）。
  public var audioPoint: AVAudio3DPoint {
    let c = cartesian
    return AVAudio3DPoint(x: Float(c.x), y: Float(c.y), z: Float(c.z))
  }
}

extension ListenerOrientation {
  /// リスナーの向き。AVAudio3DAngularOrientation は度で受け取る。
  public var audioOrientation: AVAudio3DAngularOrientation {
    let d = degrees
    return AVAudio3DAngularOrientation(
      yaw: Float(d.yaw),
      pitch: Float(d.pitch),
      roll: Float(d.roll)
    )
  }
}

extension SpatialRenderingQuality {
  /// 品質段階を AVAudioEngine のレンダリングアルゴリズムへ対応付ける。
  public var audioAlgorithm: AVAudio3DMixingRenderingAlgorithm {
    switch self {
    case .standard: return .HRTF
    case .high: return .HRTFHQ
    case .light: return .sphericalHead
    }
  }
}
