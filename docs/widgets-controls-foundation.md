# 共通基盤: ウィジェット／コントロール（計画A・B が共有）

計画A（widgets-plan.md）と計画B（control-center-plan.md）が共有する土台。
内部レビューの指摘を反映した確定アーキテクチャ。

## 不変条件（絶対）
- **RFCOMM 制御チャンネルは常に 1 本。所有者はアプリ本体プロセスのみ。**
- **拡張（widget/control）は IOBluetooth を一切開かず、`SessionCoordinator`/`SessionService` を二重生成しない。**
- 拡張がリンクしてよいのは **DTO・App Intent 宣言・IPC・スナップショット読取のみ**。
  `TandemSession` / IOBluetooth / `PlayerBridge` はリンクしない（拡張セーフ層に分離）。

## ターゲット構成（Xcode プロジェクトが前提）

SwiftPM 単体では `.appex` の埋め込み・入れ子署名・拡張の Info.plist/entitlements を生成できない。
実際の **Xcode app プロジェクト** を用意する（既存 SwiftPM のコアはローカル package として取り込む）。

```
Perch.app  (macOS app target, 非サンドボックス)
├─ Contents/PlugIns/PerchWidgets.appex  (widget extension, サンドボックス)
└─ 依存:
   ├─ (local package) TandemCore / TandemSession / NotchKit / PlayerBridge   ← 本体のみ
   └─ PerchShared (拡張セーフ: DTO / Intents / IPC / Snapshot)         ← 本体＋拡張
```

- Widget Extension は Xcode の Widget Extension テンプレートで作成し `Contents/PlugIns` に埋め込む。
- Intent 型は `PerchShared` に置き、**本体・拡張の各ターゲットで `AppIntentsPackage` を登録**する
  （静的ライブラリ/パッケージ経由で共有する場合に必要なメタデータ手順）。
- 署名は **内側（.appex）から外側（.app）へ**。各ターゲットに個別の entitlements。

## App Intent の実行モデル（macOS 26 専用）

- **`AudioPlaybackIntent` を NC 操作に流用しない**（無音バックグラウンド起動の前提は不可）。
- **`openAppWhenRun` は macOS 26 で非推奨**なので使わない。macOS 26 では
  **`supportedModes = [.foreground(.dynamic)]`** を採用し、`.foreground(.dynamic)` は
  まずバックグラウンドで本体を起動、必要時に **`continueInForeground()`** で前面化する。
  前面化の判断（初回 Bluetooth 許可・エラー提示など）と**その前の失敗経路**を明示する。
- **スパイクの合格基準（これを満たすまで「アプリ本体で実行」は暫定扱い）**:
  1. cold（未起動）と warm（起動中）の両方で `perform()` が **本体アプリの PID** で走る。
  2. **既登録の常駐ランタイム（シングルトン）を解決**して使う。
  3. **拡張プロセスでは `SessionCoordinator` を絶対に生成しない**。
  4. 望まぬフォアグラウンド化・二重チャンネルが起きない。TCC（Bluetooth 許可）が想定どおり。
  - 満たせない場合はアーキテクチャを止めるか、定義済みフォールバック（アプリを開く）に切替。
- 最初の Bluetooth 許可プロンプトを隠れた intent 起動で出さない（通常のフォアグラウンド オンボーディング必須）。

## アプリ本体: 直列コマンド実行器（新規、必須）

タップ毎にロックを acquire/release してはいけない（ロックは**セッション寿命**を守るもの。per-tap では
チャンネル保持中に「空き」と誤表示する）。開発用の `tools/control-lock.sh` は**ランタイム用ではない**。

アプリ本体に **1 つの `SessionCoordinator` を保持する直列実行器**を追加する:
- 完全な操作（送信＋read-back まで）を **1 トランザクションとして直列化**。合体（coalescing）は
  **キュー待ちの要求を置換**してよいが、**実行中の送信/read-back トランザクションを中断してはならない**。
- Swift actor は `await` を跨いで**再入**するため、actor 分離だけでは不十分 → 明示的な直列キューで
  2 つの `apply(...)` が論理的に重ならないようにする。
- 連打は**合体/整列**。デバイス/プロファイル変更後の**古い要求は破棄**（session revision で判定）。

### コマンドブリッジ（拡張 → 本体実行器）
`PerchShared` は `TandemSession` をリンクできないため、intent の `perform()` が本体実行器へ
到達する経路を具体化する:
- **共有プロトコル**（`PerchShared` に置く、例 `NoiseControlCommanding`）を定義し、
  本体が実装を **App Intents の依存注入（`AppDependencyManager` / `@Dependency`）で登録**する。
- `perform()` は登録済み依存を解決 → 本体実行器へ委譲。**cold-start の readiness 待ち**（ランタイム/
  チャンネル準備完了までの待機）と **タイムアウト**（未接続・準備失敗時の明確な失敗）を定義する。
- 「IPC」は抽象語で終わらせず、上記を実行可能な契約として記述する。

### 本番排他ロック（ランタイム、`control-lock.sh` とは別物）
- **本体アプリ＝通常ランタイムの唯一の所有者**、**プローブ CLI＝代替の診断所有者**。
- 両者は **1 つのプロセス間本番ロック**を、**チャンネル open の前から close の後まで**保持する。
- すべての UI/intent 書き込みは**同じ実行器**に入る（拡張は決してチャンネルを開かない）。
- 開発/エージェント調整用の `tools/control-lock.sh` はランタイム用ではない（役割を分離する）。

## スナップショット（App Group 共有、表示専用）

拡張は状態を持てないので、本体が capability 駆動の表示情報を共有ストアに書く。**表示専用**であり、
書き込み判断は必ず intent 実行時に **live coordinator 状態**で再検証する。

- 形式: **単一 JSON ファイルを原子的置換**（複数キー UserDefaults は中間状態が漏れる）。
- フィールド: `schemaVersion`, `capturedAt`, `sessionRevision`(不透明トークン), `connectionState`,
  `modelName`(製品型名は可), NC 現在状態＋利用可能モード＋dialect 情報, EQ プリセット一覧＋選択,
  listening features＋選択, `writesAreUnverified`, 直近アクションの result/error。
- **個人情報を入れない**（Bluetooth アドレス等は不可。世代は不透明トークンで表す）。
- **書き込み契機**: material な変化があった時（500ms の UI ループ毎には書かない）。
- **ハートビート（必須）**: material 変化が無くても、接続中は `heartbeatAt` / `leaseExpiresAt` を
  一定間隔で**原子的に更新**する。これが無いと「安定接続」と「クラッシュ」が区別できない。
  - 拡張は `capturedAt`/`leaseExpiresAt` を権威とし、`leaseExpiresAt` を過ぎたスナップショットは
    **オフライン扱い（fail closed）**にする。
  - `schemaVersion` が欠落/破損/非対応なら**同じく fail closed（オフライン/非活性）**。
- **正常終了時**は「未接続/オフライン」スナップショットを同期書き込み。クラッシュ時は lease 失効で吸収。

## タイムライン/再読込（ウィジェットとコントロールで異なる）

- **自動再読込は「操作されたコントロール/ウィジェット」しか保証しない。** 兄弟の 3 コントロール
  （ノイキャン/外音/オフ）は自動更新されないため、**モード変更の read-back 確定後に、本体から
  兄弟を含む全種を明示 reload** する:
  - ウィジェット: `WidgetCenter.shared.reloadTimelines(ofKind:)`（各 kind）。
  - コントロール: `ControlCenter.shared.reloadControls(ofKind:)`（3 種すべて）／必要なら `reloadAllControls()`。
    （名称・可用性は macOS 26 で確認済み。実装時は**実行時の挙動・バジェット・遅延**のみ検証。）
- intent 外の**機器状態変化**（接続/切断/別端末操作）でも同様に本体から reload。
- **鮮度ポリシーは面ごとに異なる**:
  - **ウィジェットは Timeline**: `.never` と `.after(...)` は**排他**（同時併用不可）。**接続中は
    `.after(leaseExpiresAt)`**、**オフライン時は `.never`**（本体駆動の reload に委ねる）。
  - **コントロールは value provider で Timeline を持たない** → `.after(...)` でスケジュール再読込できない。
    クラッシュ由来の失効は **次の操作・アプリからの reload 要求・push でのみ観測**される（Apple は
    コントロールの定期再読込ポリシーを提供しない）。値は provider が snapshot から都度算出。
- reload はバジェット制約があり遅延しうる。

## 操作の正しさ（intent 実装要件）
- intent パラメータは**完全初期化**（widget/control はパラメータを対話的解決しない）。
- **書き込み前に live capability で再検証**（stale スナップショットを信じない）。`sessionRevision` を
  intent に載せ、別機器へ紛れ込むタップを弾く。
- **NC 操作は live 状態を保持**して組む（外音レベル・ambientMode・adaptation・dialect の valueFieldCount）。
  単純な `nc|ambient|off` マップは不足。
- EQ プリセットは live の申告リストで、listening 選択は live features で検証。
- エラーは `perform()` 内で処理し、共有状態に**境界付きの error/status** を書いて return（widget からの
  素の rethrow はしない）。**read-back 成功前に楽観的「確定」を出さない**。

## 署名・配布（OSS 前提、Apple Developer 登録済み）
- **Releases バイナリは Developer ID Application 署名＋Hardened Runtime＋セキュアタイムスタンプ＋notarization**。
  archive/export 検証、**notarization ログの確認**、**Gatekeeper（`spctl`）での実機検証**まで含める。
  （Apple Development は開発用のみで配布不可。）
- **App Group entitlement は app と `.appex` に完全一致で付与**（同一チーム署名）。`<TeamID>.<group>` 形式なら
  登録は省けるが、アクセス判定は署名の `Developer-Team-ID` を見るため **Team ID 署名は必須**。
  ※ ad-hoc での App Group は**あくまでローカル検証用の実験**として扱い、構成として前提にしない。配布は
  Developer ID＋notarization 必須。
- 入れ子署名は**内側（.appex）→外側（.app）**の順。
- **秘密情報は非コミット**（証明書・鍵・プロビジョニング）。Team ID 等は非機密だが `Signing.xcconfig`
  （gitignore、`.example` 同梱）で外出しし直書きしない。
- 「ステートレス ad-hoc ウィジェット」は capability 駆動要件と矛盾（未対応/未接続を判別できず無効な
  コントロールを広告してしまう）→ 汎用 ad-hoc ビルドでは**ウィジェット/コントロールを同梱しない**、
  もしくは「縮退した実験ビルド」と明記する。本要件を満たすのは Team 署名ビルドのみ。

## 事前に潰すコード負債
- `SessionCoordinator.apply(equalizerPreset:)` が **read-back 検証をしていない**（`try?` で握り潰し、
  返り preset を要求値と比較しない）。EQ をウィジェットに載せる前に、**EQ SET 符号化の実機検証＋厳格な
  read-back** を先に済ませる。
- 本体を「常駐ランタイム＋readiness API＋本番ロック＋プローブ調整＋1リクエスト キュー」へリファクタ。

## 実装順序（両計画共通）
1. macOS 26 専用か macOS 14 互換かを決定。Developer ID / App Group 識別子を確定。
2. 実 Xcode app＋widget ターゲットを作り、**Xcode 外での**インストール・署名・共有コンテナ・
   ウィジェット discovery を実証。
3. `.foreground(.dynamic)` の**intent スパイク**で cold/running 実行 PID・前面化・TCC を実測。
4. 本体を単一ランタイム＋readiness＋本番ロック＋プローブ調整＋トランザクションキューへリファクタ。
5. versioned/atomic スナップショット（staleness・アクション結果）を定義・テスト。
6. **NC のみ先行**（連打・UI競合・機器切替・スリープ復帰・切断・プローブ競合・cold 起動・許可拒否のテスト）。
7. リスニングモード追加（live capability 検証後）。
8. EQ 追加（SET 符号化＋厳格 read-back を実機検証後）。

## 確定した決定（ユーザー）
- **macOS 26 専用**。ウィジェット・コントロールとも macOS 26 を最低要件とし、最新 API を前提にできる。
- **有料 Apple Developer 登録済み** → **Developer ID Application 署名＋notarization** で Releases バイナリを配布。
  App Group は同一チーム署名で構成。秘密情報（証明書・鍵・プロビジョニング）は非コミット、Team ID 等は
  `Signing.xcconfig`（gitignore、`.example` 同梱）で外出し。
- **ノッチ UI は従来通り有効**（設定で ON/OFF）。ウィジェット/コントロールのタップは本体の常駐ランタイムに
  委譲し、ノッチ表示の有無は既存設定に従う（ウィジェット導入でノッチ挙動は変えない）。
