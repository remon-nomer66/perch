# デバイス抽象契約(device-contract)— 分離 UI 方針

`docs/bose-support-plan.md` の実装段階2。**Sony と Bose は無理に共通 UI を使わず、それぞれ独自の
パネル UI を持つ**。共有するのは「殻(メニューバー + ノッチ窓)」「閉じたノッチバー/メニューアイコンの
薄い表示」「制御セッションは1本という監督」だけ。

> **方針転換の記録**: 当初は Sony/Bose を1つの共通 UI で描く前提で、`DeviceState`・`NoiseControlSnapshot`・
> `DeviceCommand`・`DeviceControl` といった共通フィーチャ語彙を設計していた。しかし Bose(連続 CNC・独立 ANC/wind)
> と Sony(離散 NC + ambient level)を1つの型に押し込むのは、抽象が両機器と戦う原因になり(Codex 2回目レビューが
> その複雑さと格闘していた)、後々辛くなる。**Bose は Bose、Sony は Sony の UI にすれば、この複雑さは丸ごと消える。**
> リッチな契約は破棄し、以下の薄い共有だけを残した。

---

## 1. 共有するもの(薄い)

```
共有(ブランド非依存):
  - アプリの殻: メニューバー常駐 + NotchKit(ノッチ窓)
  - 閉じたノッチバー: 機種名 + バッテリ + 接続ドット
  - メニューバーアイコン: 接続で色が変わる
  - 単一セッション監督: 制御チャンネルは1本。ブランドを判定して対応セッションを
    起動し、旧セッションを閉じてから新セッションを開く

ブランド別(独立・混ぜない):
  Sony: TandemCore / TandemSession + 既存パネル UI(今のまま・無変更)
  Bose: BoseCore / BoseSession + Bose 専用パネル UI(独自ページ)
```

展開パネルの中身は「今どちらのブランドが繋がっているか」で丸ごと切り替える(Sony デバイス→Sony ページ /
Bose デバイス→Bose ページ)。**フィーチャの型を共有しない**ので、各ブランドは実機の形に素直に作れる。

---

## 2. `DeviceContract` モジュール(実コード化済み・薄い)

依存ゼロの純粋値型。閉じたバー/メニュー用の最小語彙だけを持つ:

```swift
public enum DeviceBrand { case sony, bose }               // パネル routing 用

public enum ChargeState { case unknown, notCharging, charging, charged }

public struct BatteryReading {                            // 閉じたバーのバッテリ表示
  enum Enclosure { case single, left, right, caseEnclosure, other(index: Int) }
  struct Cell { enclosure; percent(0...100検証); charge }
  cells // enclosure 一意・順序保持
}

public struct DeviceHeadline {                            // 閉じたバー + メニューアイコン + routing
  brand; modelName(製品モデル名のみ・friendly name 禁止); battery; isControllable
}
```

- `DeviceHeadline` は**フィーチャを一切記述しない**。閉じたバーが描くもの(名前・バッテリ・接続)と、
  どちらのブランドパネルを開くか、だけ。
- バッテリは Codex #9 の指摘(percent 検証・`ChargeState` 4状態・`other(index:)` で PII-free・enclosure 一意化)を維持。
- テスト: `Tests/DeviceContractTests/`(バッテリ不変条件・headline 形状)。

---

## 3. 単一セッション監督(共有の本質)

制御チャンネルは1本(CLAUDE.md / AGENTS.md)。ブランド切替時に「旧を閉じ切ってから新を開く」保証が要る。
ただし監督は**具体的なブランドセッションを参照する**ため、依存ゼロの `DeviceContract` には置けない。
**Perch(アプリ層)に置く**:

```swift
// Perch 内(概念):
enum ActiveSession { case sony(SessionService); case bose(BoseSessionService); case none }
// ブランド判定 → 旧セッション close → 新セッション start。同時に2本開かない。
```

各ブランドセッションは、自分の reading から `DeviceHeadline` を作って閉じたバーへ渡す(Sony/Bose それぞれで
マッピング)。展開パネルへはブランド固有の reading をそのまま渡す。

---

## 4. Sony 側は無変更

この方針の最大の利点: **Sony の既存 UI・既存型(`TandemNoiseControlState` 等)は一切触らない**。
リグレッションゼロ。Sony の `DeviceSummary`/`BatteryLayout` → `DeviceHeadline` の薄いマッピングを1本足すだけ。

---

## 5. Bose 側は独自に作る

- `BoseCore`: BMAP のフレーム codec・機能 parser/builder(実機形状に素直に。Sony に合わせる歪みなし)。
- `BoseSession`: actor セッション(接続手順・set→poll・トランスポート選択)。
- **Bose 専用パネル UI**: CNC の連続スライダー、独立 ANC/wind トグル、3-band EQ、audio modes 等を
  Bose の形のまま描く。Sony のページ構成に合わせる必要はない。
- 閉じたバーへは `DeviceHeadline`(名前 + バッテリ + 接続)だけ渡す。

---

## 6. この段階の成果と非目標

**成果(実コード化済み)**: `DeviceContract` モジュール(`DeviceBrand`/`BatteryReading`/`ChargeState`/`DeviceHeadline`)+ テスト。

**非目標**:
- Sony/Bose を跨ぐ共通フィーチャ UI(=当初のリッチ契約)→ **やらない**。混ぜない。
- 単一セッション監督の実装 → Perch 側で、Bose セッションができてから配線(段階5-6)。

これにより「共有は閉じたバーとセッション1本だけ、展開パネルはブランド別」という、後で辛くならない構成になる。
