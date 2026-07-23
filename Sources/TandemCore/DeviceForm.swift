import Foundation

/// 機器がいくつの筐体でできているか。
///
/// バッテリーの申告から決まる。左右それぞれ、あるいは充電ケースの残量を申告する機器は
/// 左右が別筐体である。単一の残量しか申告しない機器は1つの筐体に収まっている。
///
/// 形状そのものを表す値はプロトコルに無い。`ModelSeriesType` は `EXTRA_BASS` や
/// `PREMIUM` といった製品ラインであり、WH-1000XM5とWF-1000XM5はどちらも `PREMIUM` に
/// なる。筐体の数は、表示を決めるうえで実際に必要な区別であり、かつ機器が申告する
/// 値から確実に導ける。
public enum TandemDeviceHousing: Equatable, Sendable {
  /// 左右が別の筐体。充電ケースを持つこともある。
  case separateLeftRight
  /// 1つの筐体。ヘッドバンド型かネックバンド型か、その他か。
  case single
  /// バッテリーの申告が無く、判断できない。
  case unknown
}

/// 装着の形。表示の見た目を決めるためだけに使う。
///
/// プロトコルはこれを教えない。`separateLeftRight` は左右が別筐体という事実から
/// 決まるが、`headband` と `neckband` の区別は型番の慣習からの推定にすぎない。
/// 推定である以上、外れうる。動作を変える判断に使わないこと。
public enum TandemWearingStyle: Equatable, Sendable {
  case earbuds
  case headband
  case neckband
  case unknown
}

extension TandemDeviceFingerprint {
  /// 左右別筐体を示す機能コード。閾値付きは新しい機種で使われる同義のものである。
  private static let leftRightBatteryCodes: Set<UInt8> = [
    0x21,  // LEFT_RIGHT_BATTERY_LEVEL_INDICATOR
    0x22,  // CRADLE_BATTERY_LEVEL_INDICATOR
    0x29,  // LR_BATTERY_LEVEL_WITH_THRESHOLD
    0x2A,  // CRADLE_BATTERY_LEVEL_WITH_THRESHOLD
  ]

  private static let singleBatteryCodes: Set<UInt8> = [
    0x20,  // BATTERY_LEVEL_INDICATOR
    0x28,  // BATTERY_LEVEL_WITH_THRESHOLD
  ]

  /// 機器が申告したバッテリーの構成から、筐体の数を決める。
  public var housing: TandemDeviceHousing {
    let declared = Set(table1Functions.map(\.code))
    if !declared.isDisjoint(with: Self.leftRightBatteryCodes) {
      return .separateLeftRight
    }
    if !declared.isDisjoint(with: Self.singleBatteryCodes) {
      return .single
    }
    return .unknown
  }

  /// 装着の形の推定。
  ///
  /// 左右別筐体であることは申告から決まるので、そこは推定を挟まない。単一筐体の
  /// 場合だけ、ヘッドバンドかネックバンドかを型番の接頭辞から推し量る。Sonyの型番は
  /// `WH-`（ヘッドバンド）、`WF-`（完全ワイヤレス）、`WI-`（ネックバンド）という
  /// 付け方をしているが、`LinkBuds` や `ULT WEAR` のように従わない名前もあるため、
  /// 判断がつかなければ `unknown` を返す。
  ///
  /// 型番は機器が送る文字列であり、こちらで検証していない点にも注意する。
  public var inferredWearingStyle: TandemWearingStyle {
    switch housing {
    case .separateLeftRight:
      return .earbuds
    case .single, .unknown:
      break
    }

    let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if normalized.hasPrefix("WH-") { return .headband }
    if normalized.hasPrefix("WI-") { return .neckband }
    if normalized.hasPrefix("WF-") { return .earbuds }
    return .unknown
  }
}
