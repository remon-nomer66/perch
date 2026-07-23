# 実装計画B: コントロールセンター コントロール（ControlWidget）

> 共通アーキテクチャ・署名・スナップショット・実行モデル・実装順序は
> [widgets-controls-foundation.md](./widgets-controls-foundation.md) を参照（本書はコントロール固有のみ）。

## 目的
コントロールセンター（および同経路のメニューバー等）から、ノイズコントロールを素早く切り替える。

## 対応 OS
- **第三者製 Control Center コントロールは macOS 26 Tahoe から対応**（macOS 15 は不可）。→ **macOS 26+ 前提**。
- 実体は `ControlWidget`。ボタンは `ControlWidgetButton`、トグルは `ControlWidgetToggle`。App Intent で駆動。

## 方式（確定）: 3 つの独立コントロール

ユーザー決定により **3 つの独立コントロール**で実装する（1 タイル 3 分割セグメントは公式に無いため）。

- コントロール: **「ノイズキャンセリング」「外音取り込み」「オフ」** の 3 つ。
  - 各 `ControlWidget` は `ControlWidgetButton` で、`SetNoiseControlIntent(mode, sessionRevision)` を実行。
  - `Toggle` ではなく Button 基調（3 排他モードのため）。
  - **`ControlWidgetButton` に固有の「選択状態」は無い** → **value provider が snapshot から算出した
    label / symbol / tint** で「現在このモードか」を表現する（選択中は塗り、非選択は淡色など）。
  - **`controlWidgetStatus(_:)` は操作直後の一時フィードバック専用**で、永続的な「利用不可」表示には使えない。
  - **無効化は macOS 26 の `ControlWidgetTemplate` の provider 駆動 `.disabled(Bool)` を実際に使う**:
    非対応 dialect・未接続・schema 不正・lease 失効の各状態で `.disabled(true)`。加えて **intent 側でも
    書き込み前に live capability を再検証して no-op**（多層防御）。コントロールはギャラリー/レイアウトから
    動的に消せないため、無効時は disabled ＋ provider の外観で示す。
  - ユーザーはコントロールセンターに必要な 3 つを配置＝「3 区画」を 3 タイルで表現。
- capability 駆動: 外音取り込みを持たない dialect（例: NC オン/オフのみ）では「外音」コントロールを
  非活性化。intent 側でも書き込み前に live capability を再検証。

## 状態同期
- **自動再読込は「操作されたコントロール」しか再クエリしない。** 例えば 外音→ノイキャン に変えたら、
  操作された以外の「外音」「オフ」タイルは自動更新されない。→ **read-back 確定後に本体から 3 種すべてを
  明示 reload**する: `ControlCenter.shared.reloadControls(ofKind:)`（3 kind）／必要なら `reloadAllControls()`。
  （API は macOS 26 で確認済み。実装時に SDK 挙動を最終確認。）
- intent 外の機器変化（接続/切断/別端末操作）でも同様に 3 種 reload。
- コントロールは value provider で Timeline を持たないため、クラッシュ由来の失効は次の操作/reload/push で
  のみ観測される（定期再読込は無い）。値は provider が snapshot（lease/heartbeat 付き）から都度算出。
- **read-back 成功前に楽観的「確定」を出さない**。失敗時は直前の確定モードを保持し error/stale を表示。

## フェーズ（コントロール固有）
1. 基盤（foundation.md フェーズ 1–6）完了後、3 つの NC コントロールを実装。
2. 実機（macOS 26）でコントロール追加・タップ・read-back・未接続/非対応 dialect・連打・機器切替を検証。

## コントロール固有の実装時確認事項
- reload API は macOS 26 で確認済み（`ControlCenter.shared.reloadControls(ofKind:)` / `reloadAllControls()`）。
  実装時は**名称でなく実行時の挙動・バジェット・遅延**を検証する。
- 現在状態表示（value provider）と `.disabled(Bool)` の macOS 26 実挙動を実機で確認。
- コントロールが Shortcuts/Siri 等の他 App Intents 面にも露出する点（`isDiscoverable`/`authenticationPolicy` を決定）。

## 非目標
- コントロールセンターでの EQ / リスニングモード操作（大ウィジェット側で扱う）。
- スライダー等の連続操作、1 タイル内の 3 分割セグメント。
