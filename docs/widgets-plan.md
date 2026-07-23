# 実装計画A: macOS ウィジェット（WidgetKit）

> 共通アーキテクチャ・署名・スナップショット・実行モデル・実装順序は
> [widgets-controls-foundation.md](./widgets-controls-foundation.md) を参照（本書はウィジェット固有のみ）。

## 目的

ノッチを使わない層向けに、WidgetKit のウィジェットからヘッドセットを操作する。操作はタップのみ。

- **小 (systemSmall)**: ノイズコントロール切替のみ（ノイキャン／外音／オフ）。
- **大 (systemMedium / systemLarge)**: NC ＋ EQ 固定プリセット ＋（対応機種のみ）リスニングモード。

すべて capability 駆動（スナップショットの申告に基づき、未対応区画は出さない）。

## ウィジェット固有の設計

### ファミリーとビュー
- `systemSmall`: NC を **`Button(intent:)`** で。`Toggle` は使わない（Boolean かつ楽観更新で 3 排他モードに不適）。
  - **スナップショットが申告するモードだけ表示**（外音を持たない dialect では「外音」ボタンを出さない）。
  - **選択中のみ強調。非選択ボタンはタップ可能**（`disabled` にしない＝切替できなくなるため）。
  - 未接続時のみ全ボタンを非活性化。
- `systemMedium/Large`: 上段 NC（同上）、中段 EQ プリセット（`Button(intent:)` を横並び、多い場合は
  代表数個に絞る＝ウィジェットは連続操作しないので固定プリセットのみ）、下段（対応時）リスニングモード
  （標準／背景音楽／シネマ、背景音楽の部屋は大サイズのみ）。
- 未接続時: 全操作を非活性化し「接続されていません」を表示。`writesAreUnverified` 時は注意アイコン。

### Intent（`PerchShared`、実行は本体プロセスを目標／foundation のスパイク合格が前提）
- `SetNoiseControlIntent(mode: nc|ambient|off, sessionRevision)`
  — 本体で live NC 状態を読み、外音レベル・ambientMode・adaptation・valueFieldCount を保持して組み立て、
    `apply(noiseControl:)`＋read-back。
- `SetEqualizerPresetIntent(presetID, sessionRevision)` — live 申告リストで presetID を検証してから適用。
- `SetListeningModeIntent(selection, sessionRevision)` — live features で検証してから適用。
- すべて `sessionRevision` を必須パラメータにし、別機器へのタップ紛れを弾く。エラーは perform 内で処理し
  共有状態へ error/status を書いて return。

### 表示データ
- 大ウィジェットは EQ プリセット名・リスニング features をスナップショットから描画（機種申告どおり）。
- EQ のバンド波形やレベルは**表示しない**（連続操作不可のため、プリセット選択のみ）。

## フェーズ（ウィジェット固有、foundation の順序に一致: NC→listening→EQ）
1. 小ウィジェット（NC ボタン）を最初に出す（基盤フェーズ 1–6 完了後）。
2. 大ウィジェットにリスニングモードを追加（基盤フェーズ 7＝live capability 検証後）。
3. 大ウィジェットに EQ プリセットを追加（基盤フェーズ 8＝EQ 符号化＋厳格 read-back 検証後）。

## ウィジェット固有リスク
- 大サイズでの区画過多（EQ プリセット数が機種依存で多い）→ 代表プリセットに限定 or スクロール不可のため折返し。
- ウィジェットのタップ→機器反映の遅延（基盤の実行モデル依存）。pending/stale 表示で吸収。
- macOS ウィジェット配置面（通知センター/デスクトップ）ごとのサイズ差。

## 非目標
- ウィジェット上での連続操作（スライダー・ドラッグ・スワイプ）、EQ バンド編集。
- ウィジェットからの機器ペアリング／接続管理。
