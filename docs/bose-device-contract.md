# デバイス抽象契約(device-contract)

`docs/bose-support-plan.md` の実装段階2。Sony(Tandem)と Bose(BMAP)を **UI から透過的に扱う共通抽象**の
型と API を、実装(protocol-core 以降)の前に確定する。Codex #2「この抽象化コストは過小評価されている」への回答。

- 前段: [bose-frozen-spec.md](bose-frozen-spec.md)(BMAP 確定仕様)/ [bose-support-plan.md](bose-support-plan.md)(全体設計)
- この段階で**実コード化するのは安定した土台の型のみ**(`Sources/DeviceContract/`)。フィーチャ状態/コマンドの
  詳細型は「決定済み API」として本書に定義し、**段階6(縦切り)で battery+NC の1機能から材料化・検証**する。
  UI 全面移行を一度にやらない(Codex #2 のコスト過小評価を回避)。

---

## 1. 現状の結合(実測)

UI(`Sources/Perch`)は Sony 固有型に強く結合している(spec-freeze 時に計測):

- `PanelModel` のフィールドが Sony の reading 型: `EqualizerReading?` `NoiseControlReading?` `TandemListeningReading?` `SpeakToChatReading?` `SidetoneReading?` `DeviceSummary` `BatteryLayout`
- 操作コールバックが Sony パラメータ型: `TandemNoiseControlState`(18箇所)`TandemListeningSelection` `TandemSpeakToChatSensitivity/Timeout` など
- 各ページ(`NoiseControlPage` 等)が `reading:`(Sony 型)+ `apply:`(Sony 型引数)を直接受ける

→ **UI を両ブランド対応にするには、この結合を契約型へ移す作業を伴う**。一度にやらず縦切りで。

---

## 2. モジュール構成(確定)

```
DeviceContract     ← 新規・純粋(依存なし)。ブランド中立の型と protocol。
  ▲        ▲
  │        │(conform)
TandemCore  BoseCore ← 各ブランドの reading/command を DeviceContract 型へ射影する adapter を持つ
  ▲        ▲
TandemSession BoseSession ← DeviceControl を実装(actor)
        ▲
      Perch(UI)← DeviceContract 型のみを消費(段階6で移行)
```

- **`DeviceContract`**: 純粋な value type + protocol。Sony/Bose どちらにも依存しない。`TandemCore` と同じく依存ゼロ。
- Sony/Bose の core は、自分の reading をこの契約型へ**射影する adapter** を持つ(既存 Sony 型は壊さない。並存させ、UI 側から段階的に契約型へ切替)。
- `TransportPreferenceStore`(Codex #11)もこのモジュールに置き、executable target への逆依存を避ける。

Package.swift: `.target(name: "DeviceContract")` を追加(依存なし)+ `.testTarget(name: "DeviceContractTests")`。
Sony/Bose core と Perch が `DeviceContract` に依存する。

---

## 3. 土台の型(この段階で実コード化・安定)

`Sources/DeviceContract/` に置く。すべて `Sendable & Equatable` の値型。ブランド中立。

```swift
public enum DeviceBrand: String, Sendable, Equatable { case sony, bose }

public struct DeviceIdentity: Sendable, Equatable {
  public var brand: DeviceBrand
  public var modelName: String?
  public var firmwareVersion: String?
  public var codec: String?           // negotiated audio codec, if known
}

/// Brand-neutral connection status. Mirrors DeviceSummary.Status but without Sony types.
public enum ConnectionStatus: Sendable, Equatable {
  case noDevice
  case connecting
  case reading                        // reading capabilities
  case ready
  case unverified(caveat: String)     // controllable, model not verified
  case readOnly(caveat: String)       // recognised, writes gated off
  case contended                      // another host holds the single control session
  case unreachable
  public var isControllable: Bool { … } // ready / unverified
}

/// capability(機能の有無)と write trust(書き込み許可)の分離(Codex #8)。
public enum WriteTrust: Sendable, Equatable {
  case trusted        // verified model, writes go through
  case experimental   // recognised but unverified firmware/model; writes with caveat
  case readOnly       // writes gated off
}

/// Battery as components — single / L·R·case / future multi-component (Bose earbuds).
public struct BatteryReading: Sendable, Equatable {
  public enum Component: Sendable, Equatable {
    case single, left, right, caseEnclosure, labeled(String)
  }
  public struct Cell: Sendable, Equatable {
    public var component: Component
    public var percent: Int?
    public var isCharging: Bool?
  }
  public var cells: [Cell]
}

/// 機能の語彙。capability は「宣言された機能の集合」で表す(申告駆動)。
public enum DeviceFeature: String, Sendable, Equatable, CaseIterable, Hashable {
  case noiseControl, equalizer, audioMode, speakToChat, sidetone
  case spatialAudio, multipoint, autoPause, buttons
}

public struct DeviceCapabilities: Sendable, Equatable {
  public var features: Set<DeviceFeature>   // 宣言された機能(UI 出し分けの根拠)
  public var writeTrust: WriteTrust
}
```

これらは Sony/Bose 双方で無理なく成立する(Sony の `DeviceSummary`/`BatteryLayout` はこの型へ射影可能。
Bose も同様)。**capability(features)と write trust を分離**し、後者は verified profile / firmware 検証で決める。

---

## 4. フィーチャ状態とコマンド(決定済み API・段階6で材料化)

Sony と Bose は機能セットが完全一致しない。**UI の描画ジェスチャは共通**(セグメント選択・スライダー・
プリセット選択・トグル)なので、契約は「ジェスチャ + ブランド中立の状態」で表す。詳細型は縦切りで確定するが、
決めた形は以下:

### 状態(UI が描く。各機能は Optional = 未宣言なら nil)

```swift
public struct NoiseControlSnapshot: Sendable, Equatable {
  public var modes: [NoiseMode]        // 提供されるモード
  public var current: NoiseMode
  public var level: LevelRange?        // 連続レベルがある場合(min/max/current)
  public var focusOnVoice: Bool?       // Sony=声にフォーカス / Bose=wind off 等
}
public enum NoiseMode: Sendable, Equatable { case off, noiseCancelling, ambient }
public struct LevelRange: Sendable, Equatable { public var min, max, current: Int }

public struct EqualizerSnapshot: Sendable, Equatable {
  public var presets: [Preset]         // id + 表示名
  public var selected: Preset.ID?
  public var bands: [Band]?            // 周波数 + 範囲 + 現在値(あれば)
}

public struct AudioModeSnapshot: Sendable, Equatable {   // Sony listening / Bose audio modes
  public var modes: [Mode]             // id + 表示名 + editable
  public var selected: Mode.ID?
}

public struct ToggleSnapshot: Sendable, Equatable {      // speak-to-chat / sidetone / spatial / multipoint
  public var isOn: Bool
  public var isAvailable: Bool
  public var detail: ToggleDetail?     // speak-to-chat の感度/時間など
}
```

### コマンド(UI が送る。ジェスチャ単位)

```swift
public enum DeviceCommand: Sendable, Equatable {
  case setNoiseMode(NoiseMode)
  case setNoiseLevel(Int, isFinal: Bool)          // ドラッグ中は isFinal=false
  case selectEqualizerPreset(EqualizerSnapshot.Preset.ID)
  case setEqualizerBand(index: Int, value: Int, isFinal: Bool)
  case selectAudioMode(AudioModeSnapshot.Mode.ID)
  case setToggle(DeviceFeature, Bool)
  case setSpeakToChatDetail(sensitivity: Int, timeoutSeconds: Int)
}
```

`isFinal` は既存 Sony UI のドラッグ debounce(90ms、`main.swift`)と同じ意味 — ドラッグ中は非最終、離した時に確認。

### ブランド射影(mapping)

| 契約型 | Sony(Tandem) | Bose(BMAP) |
|---|---|---|
| `NoiseControlSnapshot` | `NoiseControlReading`(NC/ambient + ambientLevel + wind) | Ultra: CNC [1.5]/[31.10](level 0-10, 反転)/ QC35: ANR [1.6](off/high/low 離散→modes) |
| `.setNoiseLevel` | ambient level | Ultra CNC(反転を adapter で吸収)。QC35 は level 無し(modes のみ) |
| `EqualizerSnapshot` | presets + bands | Ultra: 3-band [1.7](presets 無し)/ QC35: EQ 無し(nil) |
| `AudioModeSnapshot` | listening(標準/BGM/シネマ + room) | Ultra: audio modes(名前 + editable, [31.x])/ QC35: 無し |
| `ToggleSnapshot`(sidetone) | `SidetoneReading` | [1.11] |
| `ToggleSnapshot`(speakToChat) | `SpeakToChatReading` | Bose に該当機能なし → 未宣言 |
| `ToggleSnapshot`(spatial/multipoint) | Sony に無い → 未宣言 | Ultra のみ |
| `BatteryReading` | `BatteryLayout`(single / L·R·case) | QC35=single / Ultra HP=single / Ultra earbuds=L·R·case |

**射影は各 core の adapter が担う**。UI は契約型だけを見る。Sony/Bose にしか無い機能は Optional が nil / feature 未宣言で自然に出し分く(既存 capability 駆動と同じ)。

**張力の明示**: Bose CNC の「反転(0=最大ANC)」と「anc/wind の同時制御」、QC35 ANR の「level 無し離散」は、
`NoiseControlSnapshot` の `modes`/`level`/`focusOnVoice` の組合せで表現し、**反転や [31.10] の 5バイト同時送信は Bose adapter が隠蔽**する。契約型は反転を知らない。

---

## 5. DeviceControl protocol(セッションの共通面)

UI/AppModel が見るセッションの抽象。Sony=`SessionCoordinator`、Bose=`BoseSession` が実装。

```swift
public protocol DeviceControl: Actor {
  var identity: DeviceIdentity { get async }
  var status: ConnectionStatus { get async }
  var capabilities: DeviceCapabilities { get async }
  var snapshot: DeviceSnapshot { get async }         // battery + 各機能 Snapshot を束ねた器
  func apply(_ command: DeviceCommand) async throws   // read-back 検証は実装側
  func retry() async                                   // manualRetry(contended/unreachable からの復帰)
}
```

- 既存 `SessionService`(`public actor`, `session: SessionCoordinator`)はこの抽象の上位に「ブランド判定 → 対応セッション起動」を足す形で拡張(段階2の device-contract では protocol 定義まで。起動側は段階6)。
- `apply` の **read-back 検証と write-trust ゲートは各セッション実装の責務**。契約は「throw する」ことだけ定める。

---

## 6. 共通トランスポート target の API(Codex #4/#6/#7)

RFCOMM 下回りは Sony/Bose 共有。ただし:

- **サービス探索は任意クロージャでなく strategy 型** `RFCOMMServiceLocator`(BMAP marker で判定 → どの SDP record から SPP チャンネルを確定するか)を transport target 内に閉じ込める(Swift 6 concurrency 安全)。
- **前提改修**: `RFCOMMChannelHost` の `.bufferingNewest(256)` によるサイレント chunk drop を先に修正(unbounded / 明示 overflow failure)。チェックサム無しの BMAP では 1 バイト欠落で framing 恒久崩壊。
- BLE は別 target(`CBCentralManager`)。`OpenedChannel`(write/close/inbound AsyncStream/MTU)の形に載せ、§3.2(bose-support-plan)の isolation/notify 完了/backpressure 要件を満たす。

```swift
public protocol RFCOMMServiceLocating: Sendable {
  /// SDP から制御チャンネルを確定する。引けなければ typed error(降格/リトライへ)。
  func locateControlChannel(on device: /* IOBluetoothDevice 抽象 */) throws -> RFCOMMChannelID
}
```

(具体の IOBluetooth 型は TandemSession/BoseSession 側。契約は「チャンネルを1つ返すか投げる」ことだけ。)

---

## 7. この段階の成果と非目標

**成果(実コード化する)**: `DeviceContract` モジュール(§3 の土台型)+ テスト。Package.swift にターゲット追加。

**決定済み API(文書化・材料化は後段)**: §4 フィーチャ状態/コマンド、§5 DeviceControl、§6 トランスポート strategy。

**非目標(この段階でやらない)**:
- UI(PanelPages/AppModel)の契約型への全面移行 → 段階6(縦切り)で battery+NC の1機能から。
- Sony 既存型の削除・改名 → 並存させ、UI 移行が済んでから整理。
- Bose の reading/command 実装 → 段階3(protocol-core)以降。

これにより「抽象の API を先に確定」しつつ、UI 大改修のリスクを縦切りに分散する(Codex #2/#9)。
