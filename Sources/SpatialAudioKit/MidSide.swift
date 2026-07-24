import Foundation

/// ステレオのミッド/サイド変換。
///
/// Mid=(L+R)/2 は中央成分（ボーカル・ベース・キック等、両chに共通する音）、
/// Side=(L−R)/2 は左右差（パンされた楽器）。中高域の Side を広げると、ミックスが既に
/// 持つ楽器の左右配置を尊重したまま音場を立体に広げられる。往復（encode→decode）は
/// 元の L/R を厳密に復元する。
public enum MidSide {
  public static func encode(left: [Float], right: [Float]) -> (mid: [Float], side: [Float]) {
    let count = min(left.count, right.count)
    var mid = [Float](repeating: 0, count: count)
    var side = [Float](repeating: 0, count: count)
    for index in 0..<count {
      mid[index] = (left[index] + right[index]) * 0.5
      side[index] = (left[index] - right[index]) * 0.5
    }
    return (mid, side)
  }

  public static func decode(mid: [Float], side: [Float]) -> (left: [Float], right: [Float]) {
    let count = min(mid.count, side.count)
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    for index in 0..<count {
      left[index] = mid[index] + side[index]
      right[index] = mid[index] - side[index]
    }
    return (left, right)
  }
}
