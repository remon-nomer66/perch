# ヘッドトラッキング計画（空間オーディオ フェーズ2）— 改訂2

MacBook のカメラで顔の位置と向きを推定し、**音場を空間（部屋）に固定する**。
頭を回すと音源が相対的に反対へ動き、「Mac の位置に音場が張り付いている」感覚を作る。
離席して距離が変わったら、距離感（減衰・こもり）にも反映する。

これは [spatial-audio-plan.md](spatial-audio-plan.md) の「フェーズ2 — 頭部追従」の詳細設計。
改訂2 は Codex レビュー（NEEDS_REVISION, 12件）の指摘を検証のうえ反映したもの。

## 先行事例の調査結果

| 事例 | 手法 | 学び |
|------|------|------|
| Waves Nx デスクトップ | システム音全取り + web カメラ頭部追従（+任意で BT ヘッドトラッカー） | 本機能とほぼ同一の製品が成立していた。2021 年に消費者版撤退＝市場に空白。カメラのみで実用になっていた |
| opentrack NeuralNet tracker | ONNX の頭部姿勢推定モデル（CPU で INT8 推論）。フライトシム定番 | 720p の安価なカメラで実用精度。ただし外部モデル・ONNX Runtime 依存 |
| SmoothTrack / AITrack | 顔ランドマーク→姿勢→ゲームへ送信 | ランドマーク→姿勢の一般パイプラインで実用になる |
| MediaPipe Iris (Google) | 虹彩実径（11.7±0.5mm）で単眼距離推定、誤差 4.3% | 単眼で距離が取れる**原理**の根拠。ただし専用虹彩モデルの結果で、Vision の瞳ランドマーク IPD 法には転用できない（精度は流用不可） |
| Apple（AirPods 系） | `CMHeadphoneMotionManager`（IMU） | **macOS 14 で利用可能（コンパイル確認済み）**。対応機（AirPods/Beats）ではカメラより高レート・低ジッタ。Sony 機では不可 |

## 手法の選定

**姿勢ソースは抽象化し、カメラ（Vision）を主経路、ヘッドホン IMU を機会的経路とする。**

```
HeadPoseProvider（プロトコル）
 ├─ CameraHeadPoseProvider   … Vision。全ヘッドホンで動く主経路。距離も出せる
 └─ HeadphoneMotionProvider  … CMHeadphoneMotionManager。isDeviceMotionAvailable が
                                真のときだけ選択（AirPods等）。ブランド判定はしない
```

- **向き（カメラ）**: `VNDetectFaceRectanglesRequest` (revision 3, macOS 12+) が
  `VNFaceObservation` の yaw / pitch / roll を連続値で返す（各値は nullable）。
- **距離（カメラ）**: **相対距離（比率）方式**。トグル ON 時の較正で「基準ピクセル瞳孔間距離
  `ipd₀`」を記録し、以後 `distanceRatio = ipd₀ / ipdNow` を使う。
  - **絶対距離（メートル）は初期スコープ外**。`videoFieldOfView` は
    **macOS SDK で unavailable（コンパイル不可を確認済み）** で焦点距離が取れず、
    個人 IPD（50〜75mm に分布）の仮定も大誤差源になるため。
  - 比率方式なら**焦点距離も個人 IPD も分子分母で相殺**され、どちらの問題も消える。
    体験（離れたら減衰）に絶対値は不要。
  - yaw による投影短縮の補正: 正面付近（|yaw| 小）でのみ距離を更新し、外れ値は棄却。
  - 瞳が取れない遠距離は顔バウンディングボックス幅比にフォールバック
    （瞳が取れていた間に 幅↔ipd 比を学習しておく）。
- 却下した代替: opentrack の ONNX モデル（外部依存）、MediaPipe（巨大依存）、
  ARKit（macOS に無い）。

カメラ由来の姿勢はドリフトしない（毎フレーム絶対値）。再センターは基準の取り直しだけ。

## 回転の扱い（座標系を最初に固定する）

- Vision の角度符号・カメラ画像のミラーリング・AVAudio の座標系は**それぞれ別物**。
  実装前に「Vision 軸 → 内部表現 → AVAudio 軸」の**変換表を書き、左右・上下・roll
  各軸の実音テストで検証する**（スパイクの必須項目）。
- 中心化（基準姿勢との差分）・平均・スムージングは **クォータニオンで合成**する。
  Euler 成分ごとの引き算/平均は回転として正しくなく、角度境界で不連続になるため。
  Euler 角への変換は AVAudio 境界（`AVAudio3DAngularOrientation`）でのみ行う。
- スムージングは One Euro フィルタ（クォータニオン球面補間版）。

## Bluetooth 遅延との折り合い

motion-to-sound はカメラ+推論+**BT 100〜300ms**。ワールドロック（知覚許容 ≈60ms）は
標準 BT では成立しない。**One Euro は位相遅れをさらに足す**ので「遅延を隠す」とは言わない。

- 機能名は「ワールドロック」ではなく**「ゆっくり追従」**として提供する（体験に正直な名前）。
- スパイクで **BT 込みの実測 motion-to-sound**（実音で計測）を取り、しきい値を超える環境では
  追従を勧めない/無効化する **go/no-go 基準**を設ける。
- 角速度による短時間外挿（音声出力予定時刻へ向けた予測）は**評価項目**とし、採用は実測次第。
- 距離連動も同じ遅延で反映されるが、歩行は秒オーダーの現象なので**体感上**問題にならない
  （遅延が消えるわけではない）。

## 音声グラフへの接続（distance 単値ではなく listener pose で）

`AVAudioEnvironmentNode` の減衰は「音源位置と `listenerPosition` の距離」で決まり、
単独の距離値を渡す API ではない。音源距離は既に `StereoField.distance` が所有している。

- **静的設定（音場の形）と動的状態（リスナーの姿勢）を分離**する:
  `ListenerPose(position, orientation)` を導入し、`updateListenerPose` で
  `listenerPosition` / `listenerAngularOrientation` を更新する。音源は Mac に固定。
- 距離比は較正点からのリスナー後退（`position.z`）に写す。
- 遠距離の「こもり」は距離減衰からは出ないので、**明示的なローパス（既存 Biquad）**を
  距離比に応じて滑らかに掛ける。

## 振る舞いの決め

- **中心の定義**: トグル ON 時の最初の ~1 秒の姿勢平均（クォータニオン平均）と `ipd₀` を基準に。
  ノッチ UI に再センター操作。
- **追う顔の固定**: 較正時の顔を**位置連続性 + ヒステリシス**で追い続ける（「最大の顔」は
  別人へ飛び得るため不採用）。見失いが安定して続いた後にのみ再取得する。
- **顔ロスト**: 向きは ~2 秒のクロスフェードで正面へ。**距離効果は中立へ戻す**
  （暗所・横向きの検出失敗を「離席」と誤解して音量を下げない）。姿勢角が nil の
  フレームは信頼度低として扱う。
- **UI 状態**: 「追跡中 / 見失い / 権限なし / カメラ使用中」を表示する。
- **カメラ選択**: 内蔵カメラを明示既定にする（Continuity Camera が勝手に立ち上がる事故を防ぐ）。

## 権限・プライバシー

- `NSCameraUsageDescription`（ローカライズ込み）**と** Hardened Runtime の
  `com.apple.security.device.camera` entitlement の**両方**を追加する
  （現状の `Perch.entitlements` には無い）。
- 権限要求は**明示トグル操作の後**にだけ出す。拒否・制限・後からの設定変更・カメラ中断を
  UI 状態として扱う。
- フレームは保存せず、ログ・クラッシュレポートにも渡さない（テストで検証）。
  姿勢・距離の数値ログも診断モード限定・既定無効・非永続。
- OFF・スリープ・カメラ中断時はセッションを**完全停止**し、バッファ参照の解放を確認する。

## 並行性（Swift 6 strict concurrency）

- キャプチャは **actor（または専用 serial executor）に隔離**し、`CMSampleBuffer` 等の
  生フレームを外に出さない。外へ渡すのは `Sendable` な値（クォータニオン+比率+信頼度）のみ。
- 推論は **in-flight 1 本**・`alwaysDiscardsLateVideoFrames = true`。古い推定は捨てて
  最新だけ反映（レートを守っても遅延を溜めない）。
- `AVCaptureSession.startRunning()` はブロッキングなので MainActor から呼ばない。
- 姿勢更新と音声グラフのライフサイクルは単一の control 経路に集約する。

## 構成

```
SpatialAudioKit/
  HeadPose.swift              // クォータニオン + 距離比 + 信頼度。純粋値型
  RotationMath.swift          // Vision軸→内部→AVAudio軸の変換・球面補間。純粋
  OneEuroFilter.swift         // 球面補間版。純粋・全テスト可
  RelativeDistance.swift      // ipd₀/ipdNow・yawゲート・外れ値棄却・箱幅フォールバック。純粋
  PoseCenter.swift            // 較正（基準姿勢+ipd₀）・再センター。純粋
  TrackingBlend.swift         // 顔ロスト時の正面回帰／距離中立化の時間発展。純粋
  HeadPoseProvider.swift      // プロトコル
  CameraHeadPoseProvider.swift    // AVCapture + Vision。actor 隔離の薄いシェル
  HeadphoneMotionProvider.swift   // CMHeadphoneMotionManager（実行時可用性で選択）
```

音声側は `LiveSpatializer` に `updateListenerPose(ListenerPose)` を追加
（既存 `updateListener(ListenerOrientation)` の拡張）。

## 進め方（検証を先に）

1. **P0 — 署名済み実機スパイク**（Perch 内の隠し診断モードとして実装。裸の SwiftPM CLI は
   TCC が不安定なため）: Vision の姿勢符号の確認（変換表の検証）、静止ジッタ幅、実効レート、
   ipd 比の安定性、顔ロスト率、CPU/電力、**実音での BT 込み motion-to-sound**。
   **フィルタ定数と go/no-go はここで決める。**
2. **P1 — 純粋層を TDD**: RotationMath / OneEuroFilter / RelativeDistance / PoseCenter /
   TrackingBlend。スパイクで確定した座標系仕様に対して書く。
3. **P2 — orientation-only 統合**: トグル + 再センター + 状態表示を空間オーディオシートに追加。
   距離連動はまだ入れない。
4. **P3 — 距離連動（実験機能として分離）**: `listenerPosition` + ローパス接続。
   複数人・照明・眼鏡・外部カメラ・中断復帰を受入条件に含める。

## リスク

- Vision の角度分解能・ジッタが音像に足りるか → **P0 で数値化**。不足ならランドマーク PnP
  へ切替余地（依存ゼロのまま。ただし焦点距離仮定が要るので姿勢のみに使う）。
- BT 遅延で「ゆっくり追従」でも不快なら → 機能を IMU 機（AirPods）と有線の推奨に絞る判断を
  P0 の実測で行う。
- 逆光・暗所 → 信頼度低下時はフィルタ強化 + 距離中立化（音量を下げない側へ倒す）。
