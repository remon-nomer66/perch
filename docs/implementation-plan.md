# 実装計画

macOSのノッチから対応Bluetoothヘッドホンを操作する常駐アプリを新規に構築する。

## 1. 目的と達成条件

`sound-connect-pc` で確立したSony Tandemプロトコル実装を土台に、常用に耐えるネイティブアプリを作る。研究用途の成果物は持ち込まない。

達成条件はシナリオごとに分けて定義する。計測は3つの区間に分離する。終了点を1つにまとめると、計測手段が実際に保証する意味とずれるためである。

| 区間 | 開始点 | 終了点 | 計測手段 |
| --- | --- | --- | --- |
| A: 状態反映 | 入力イベント | 対応する状態変更をコミットした時点 | `os_signpost` |
| B: 描画到達 | 入力イベント | 当該revisionの反映を観測した後の最初のディスプレイ更新 | `os_signpost` と `CADisplayLink` |
| C: アニメーション完了 | 入力イベント | 実際に使用する遷移アニメーションの完了 | そのアニメーションの完了ハンドラ |

入力ごとにrevisionを発行し、Viewの更新または対応するレイヤーのコミット地点でそのrevisionを観測する。単に次の `CADisplayLink` コールバックで区間を閉じると、UIが更新されていなくても合格してしまうためである。

目標値は区間Bで定める。入力の発生位相は描画周期に対して任意なので、固定のミリ秒ではなくディスプレイの `refreshDuration` の倍数で定める。

| シナリオ | 前提 | 目標 |
| --- | --- | --- |
| peekの反応 | ポインタがノッチ矩形へ100ms滞在済み | p95で2周期以内 |
| 展開（`ready`かつ利用する値を取得済み） | クリックのmouseDown | p95で6周期以内 |
| 展開（未接続） | クリックのmouseDown。骨格と前回値、取得中表示を描く | p95で3周期以内 |

`ready` のシナリオは「利用する値が事前に取得済みであること」を開始条件に含める。取得していない値を待つ時間は、この目標の対象外とする。

区間Bは次回描画周期までの自動計測であり、実際に画面へ提示された時刻の保証ではない。実表示は8.2の受入試験で高速度撮影により補完する。その測定条件を次のとおり定める。

| 項目 | 定義 |
| --- | --- |
| 開始端（peek） | カーソルがノッチ矩形へ入った撮影フレームから100ms後 |
| 開始端（展開） | クリック動作が撮影像に現れたフレーム |
| 終了端 | シナリオごとの視覚的到達点。peekは拡大の開始、未接続時の展開は骨格の表示、`ready` の展開は確定値の表示 |
| 試行回数 | シナリオごとに20回 |
| ウォームアップ | 各シナリオの計測前に5回実行する |
| 記録項目 | ディスプレイのリフレッシュレートと撮影フレームレート |
| 判定 | 20回中19回以上が、区間Bの目標に滞在判定の許容誤差と撮影周期1フレーム分を加えた値以内 |

20回の標本でp95を論じても判定が定義に左右されるため、合否は回数で直接定める。

区間Bの終了端となる描画コミットの観測点は、`NSView.updateLayer` の完了、レイヤーのコミット境界、`CATransaction` の境界のいずれを用いるかを実装時に1つ選び、固定する。周期は各試行の `CADisplayLink` の `targetTimestamp` と `timestamp` の差から取得する。

操作感については、機能あたりの送信中要求を最大1件、待機中を最大1件（最新のみ保持）とし、スライダー操作中にこれを超えないことを計測で確認する。

Bluetooth以外の権限は、アクセシビリティ・入力監視・画面収録を一切要求しない。

## 2. 前提として確認済みの事実

macOS 26 世代 / Swift 6 系で検証した。

- Sony Tandemの読み取りと、EQ・外音制御・リスニングモード・Speak-to-Chat・Sidetoneの書き込みは実装・実機検証済みである
- 既存実装は操作のたびにRFCOMMを開閉する一発完結型であり、そのままではノッチUIの応答要件を満たさない
- `MRMediaRemoteGetNowPlayingInfo` は自前ビルドのバイナリからは常にnilを返す。Apple署名のplatform binary経由でのみ応答する
- dylibをplatform binaryへ注入する回避策は、arm64ビルドではPAC不整合でSIGSEGV、arm64eビルドでは応答が返らない
- ScriptingBridgeによるSpotifyおよびMusicの情報取得と再生操作は正常に動作する

したがって再生情報はScriptingBridgeで扱い、非公開APIには依存しない。

## 3. 基本方針

### 3.1 対象環境と配布範囲

| 項目 | 値 |
| --- | --- |
| deployment target | macOS 14.0 |
| 観測 | `@Observable` |
| 配布 | 段階方針。当面はローカルビルド、将来はGitHub Releases |

`Package.swift` の `platforms` と `Info.plist` の `LSMinimumSystemVersion` を14.0で一致させる。

配布は段階方針とする。当面はローカルビルドとし、安定した自己署名証明書で署名して、初回のみGatekeeperの警告を手動で解除する。GitHub Releasesでの第三者配布を始める段階で、Developer ID署名、secure timestamp、`notarytool` による公証、staple、`codesign --verify` と `spctl` による検証へ移行する(`tools/package_app.sh release` は資格情報が揃っている場合に公証まで行う)。7章の配布・公証の項もこの段階方針に従う。

### 3.2 ライセンスと由来

| 対象 | 状況 | 方針 |
| --- | --- | --- |
| `TandemCore` の移植元 | 本人の著作物。著作権ヘッダーを含まない | 制約なく移植する |
| `functiontypes.json` | soundconnectd。`MIT OR Apache-2.0` | MITを選択して取り込む。`THIRD_PARTY_NOTICES.md` に表示を保持し、由来は `tools/protocol-source/NOTICE.md` に記録する |
| NotchDrop | MIT, Copyright (c) 2024 Lakr Aream | `NotchKit` は標準の macOS 手法で独自実装（複製していない）。MIT のため取り込むこと自体は許される |
| Gadgetbridge / BudsLink・Bluetooth-Battery-Meter | AGPL-3.0 / GPL-3.0 | 本リポジトリは AGPL-3.0 のため取り込み可能（GPLv3↔AGPLv3 互換）。現状は参照のみ。実際に取り入れた箇所（旧世代NCのバイト配列＝Gadgetbridge、借用実機で独立検証）は `THIRD_PARTY_NOTICES.md` に帰属 |
| `libmdr` (`mos9527/SonyHeadphonesClient`) | MIT。ただし `ProtocolV2T1.hpp` 等はSonyアプリからの抽出物 | mos9527 の寄与は MIT だが、**Sony 抽出部分は Sony の著作物のため取り込まない**。カタログは soundconnectd を採用 |
| Sony製品画像・型番メタデータ | 権利表記なし。画像はSonyの著作物 | 使用しない。形状は機器の申告から導く |

ウィンドウレベルの設定や `safeAreaInsets` の利用はAPIの用法であり、著作物ではない。`NotchKit` は独自に実装する。仮に非自明なコードを流用する場合は、`NOTICE` にMITライセンス全文と著作権表示を保持する。

Phase 0で移植対象の一覧とライセンス確認結果を記録し、新リポジトリのライセンスを定める。**本リポジトリのライセンスは AGPL-3.0 に定めた。** 上表の「取り込まない」はライセンス互換性の問題ではなく（MIT/AGPL-3.0/GPLv3 はいずれも AGPL-3.0 と互換）、Sony 著作物の除外と当初の慎重方針によるものである。

fixtureとログは匿名化する。テストfixtureからBluetoothアドレス、機器の個体識別子、マルチポイント接続先名を除去する。`OSLog` は `privacy: .private` を既定とし、公開してよい値だけ `.public` を明示する。

### 3.3 値の状態モデル

機能ごとに次の構造を持つ。1つの値に状態を畳み込むと、初回未取得の表現と、複数機能を続けて操作した際の取り違えが避けられないためである。

| 要素 | 意味 |
| --- | --- |
| `confirmed` | 機器から取得した値。未取得なら空 |
| `desired` | ユーザーが要求した値。要求がなければ空 |
| `transaction` | 進行中の変更。下記の構造 |
| `queuedLatest` | 送信待ちの最新値 |
| `freshness` | `unknown` / `fresh` / `stale` |

表示値は `desired` があればそれを、なければ `confirmed` を使う。

#### 変更トランザクション

機器はローカルで採番した識別子を返さない。したがって識別子の突き合わせによる確認は成立しない。代わりに、SET送信後に自分で開始した検証GETの結果で判定する。

| 要素 | 意味 |
| --- | --- |
| `revision` | ローカル採番。表示の整合にのみ使う |
| `requestedValue` | 送信した値 |
| `sessionEpoch` | 送信時のセッション識別子 |
| `setOperationID` | SET要求の識別子 |
| `verificationOperationID` | SET後に開始した検証GETの識別子 |
| `phase` | `sending` / `awaitingVerification` / `done` / `failed` |

確定条件は、`verificationOperationID` の応答値が `requestedValue` と一致することだけとする。機器からの通知は確定条件に含めず、到着した場合に検証GETを早く開始するトリガーとして扱う。通知が届かない機能でも確定できるようにするためである。送っていない値が確定することはないため、安全境界は維持される。

機器がSETを受理してから値へ反映するまで遅れる場合がある。したがって最初の不一致で失敗としない。

- 機能ごとにsettle時間を定める
- 検証GETが不一致だった場合、短いバックオフを置いて再検証する。回数の上限を設ける
- 上限に達したら、最後に取得した値を `confirmed` として採用してから `failed` を確定させる。UIと実機の値が食い違ったまま残ることを防ぐ

settle時間、バックオフ間隔、上限回数は定数として一箇所に置き、注入したclockで決定的に試験する。

`sessionEpoch` が現在値と異なる応答、および現在のトランザクションより古い `operationID` のGET応答は破棄する。遅延到着したGETが `confirmed` を過去の値へ戻すことを防ぐ。

`queuedLatest` が存在する間は `desired` を最新の要求値のまま維持する。先行トランザクションの確定によって、待機中の値の楽観表示を消してはならない。

終端の処理を明示する。`desired` を残したままにすると、以後の通知や通常GETで更新された `confirmed` を永久に覆い隠す。

| 結果 | `confirmed` | `desired` | `queuedLatest` | `freshness` | 次の動作 |
| --- | --- | --- | --- | --- | --- |
| 成功かつ待機なし | `requestedValue` | 空 | 空 | `fresh` | なし |
| 成功かつ待機あり | `requestedValue` | 待機値を維持 | 空 | `fresh` | 次を開始 |
| 検証が不一致 | 最後に取得した値 | 空 | 空 | `fresh` | なし |
| 検証がtimeout | 変更しない | 空 | 空 | `stale` | なし |
| キューによる即時拒否 | 変更しない | 空 | 空 | 変更しない | なし |
| ACK timeout（本応答あり） | 通常どおり検証へ進む | — | — | — | 検証を継続 |
| 本応答のtimeout | 変更しない | 空 | 空 | `stale` | 下記の回復へ移る |
| 書き込みエラー | 変更しない | 空 | 空 | `stale` | セッション破棄を通知 |
| タスク取消 | 変更しない | 空 | 空 | 変更しない | なし |
| 照合状態の喪失 | 変更しない | 空 | 空 | `stale` | 以後のSETを拒否 |
| セッション無効化 | 変更しない | 空 | 空 | `stale` | 全機能を一括で終端する |

セッション無効化では、全機能のトランザクションを1回の操作でまとめて終端する。機能ごとに順次終端すると、途中で届いた通知が終端済みの機能を更新し得るためである。

#### 書き込み後の取消とtimeout

SETは送信してしまえば機器へ届いた可能性がある。したがってトランザクションの進行を明示的な状態として持つ。

| 状態 | 意味 |
| --- | --- |
| `beforeWrite` | writerへ渡す前 |
| `writtenAwaitingResponse` | 書き込み済みで本応答を待っている |
| `verifying` | 本応答を受け、検証GETを待っている |
| `recoveryPending(epoch:)` | 本応答がtimeoutし、旧epochを無効化した。再handshakeを待っている |
| `recoveryReading` | 新しいepochで回復GETを実行している |

各状態での事象の扱いを次のとおり定める。

| 状態 | 呼び出し側の取消 | timeout | 切断 |
| --- | --- | --- | --- |
| `beforeWrite` | 安全に取り消す。`desired` を空にする | — | 終端する |
| `writtenAwaitingResponse` | 受け付けない。呼び出し側から切り離して継続する | `recoveryPending` へ | `recoveryPending` へ |
| `verifying` | 受け付けない | 検証の再試行上限まで継続。上限で `failed` | `recoveryPending` へ |
| `recoveryPending` | 受け付けない | 再handshakeできなければ `failed` かつ `stale` | 維持する |
| `recoveryReading` | 受け付けない | `failed` かつ `stale` | `recoveryPending` へ戻す |

本応答のtimeoutでは、旧 `sessionEpoch` を原子的に無効化する。この時点で `desired` と `queuedLatest` は破棄し、`freshness` を `stale` にする。実機の値が不明な状態で楽観表示を残さないためである。

回復中の規則は次のとおりとする。

- 同一機能への新規SETは、回復が終わるまで拒否する
- 再handshake後、回復GETを通常のSETより先に実行する
- `freshness` を `fresh` に戻せるのは、現在のepochで回復GETが成功し、かつそれより新しいSETが存在しない場合だけである

回復記録は通常のトランザクションとは別に保持し、exactly-onceで終端する。

各終端は、競合する通知やtimeoutが同時に発生した場合もexactly-onceで行われることを試験する。

成功して待機がない状態でヘッドホン本体を操作した場合、その通知が直ちに表示へ反映されることを試験する。

| 状況 | 表示 |
| --- | --- |
| `freshness` が `unknown` | その機能のページを取得中として示す |
| `fresh` かつ送信中でない | 通常 |
| 送信中 | わずかな脈動 |
| `stale` | 減光 |
| 確認失敗 | `confirmed` へ戻すアニメーション |

機能ごとに独立した構造を持つため、ある機能の送信中に別の機能を操作しても互いを上書きしない。

#### 所有者

この構造、debounce、`queuedLatest`、トランザクションの進行は、すべて `TandemController` が単独で保持する。`DeviceState` はrevisionを伴う不変のスナップショットを受け取るだけとし、自身で状態を進めない。所有者を分けると、送信済みの値、楽観表示、待機件数、revisionが非同期にずれる。

3.5の優先度クラスにある `control` と `verification` の専用枠は、並列に実行する枠ではない。単一のin-flight executorに対する優先的な受付枠である。

#### トランザクション外の値更新

ヘッドホン本体の操作や別端末からの変更も反映する必要がある。トランザクションが進行していない場合の更新規則を次のとおり定める。

| 入力 | `confirmed` を更新する条件 |
| --- | --- |
| 通知 | 進行中のトランザクションがない。かつ現在の `sessionEpoch` である |
| 通常GETの応答 | 進行中のトランザクションがない。かつ現在の `sessionEpoch` である。かつ、より新しいSETまたは検証GETが発行されていない |

進行中のトランザクションがある間は、通知も通常GETも `confirmed` を更新しない。検証GETの結果だけが確定を与える。

#### 失敗と切断

| 事象 | 扱い |
| --- | --- |
| 検証GETの値が要求値と一致しない | `transaction` を `failed` にする。`desired` と `queuedLatest` を破棄し、`confirmed` へ戻す |
| 検証GETがtimeoutした | 同上 |
| セッション切断 | 全機能の `transaction`、`desired`、`queuedLatest` を破棄し、`freshness` を `stale` にする |

失敗時に `queuedLatest` を次のトランザクションへ進めることはしない。確認できなかった直後に、確認していない値をさらに送るためである。

前回値の保存は機器の安定ID単位に分ける。

#### 連続操作

外音レベルのような連続値は、操作中に120msのdebounceを掛け、機能あたり送信中1件・待機中1件（最新のみ）に制限する。確定後、その機能と競合し得る機能を再取得する。

### 3.4 制御可能性の判定

機種・firmware・protocol・capability・必須機能構成の照合は、`ready` へ遷移するための必須条件とする。照合前および照合失敗時、`TandemController` は全てのSETを拒否する。これを不変条件として単体テストで固定する。

#### SETのlease

`invalidateSession` をEffectとして非同期に実行すると、actorの再入により、Controllerが古い `ready` のまま新しいSETを受理する窓が開く。これを防ぐため、SETにleaseを持たせる。

leaseは `sessionEpoch`、対象機器の識別子、capabilityの世代番号を含む。

- UI由来のSET投入とセッションの失効は、同一の順序付きコマンド列へ集約する
- leaseはSETを受理する時点と、writerへ渡す直前の2回照合する
- いずれかで不一致なら送信しない

出力先の変更または切断と、SETの投入およびdebounceの発火が同時に起きる場合を試験する。

### 3.5 通信契約

#### 受信

- バイトストリームを継続的に解釈する。1回の読み取りに複数frameが含まれる場合と、frameが途中で切れる場合の双方を扱う
- start byteで同期し、escape解除、checksum検証、end byteまでを1frameとする
- checksum不一致または解釈不能なframeは破棄し、次のstart byteまで読み飛ばす。破棄件数を記録する

再同期の規則を明示する。

| 状況 | 扱い |
| --- | --- |
| 最大frame長を超えてもend byteが来ない | バッファを破棄し、次のstart byteから再同期する |
| escapeされていないstart byteがframeの途中に現れた | そこを新しいframeの先頭として再同期する |
| バッファ末尾がescapeで終わる | 続きのバイトが来るまで保留する。最大frame長を超えたら破棄する |

delegateからの引き渡しを含め、全ての受け渡し段で容量と溢れた場合の規則を定める。既定の無制限バッファや、コールバックごとの `Task` 生成は使わない。消費側が止まった際に際限なく増えるためである。

| 段 | 所有者 | 容量 | 溢れた場合 |
| --- | --- | --- | --- |
| delegateの直後 | `RFCOMMTransport` | 固定容量のリングバッファ | セッション異常 |
| parserの入力 | `FrameStreamParser` | 最大frame長の定数倍 | セッション異常 |
| 応答経路 | `TandemRouter` | 有限 | セッション異常 |
| 通知経路 | `TandemRouter` | 機能キーごとに1件 | 最新値へ畳み込む |

セッション異常では、黙って続行しない。チャネルの切断、待機中要求の一括完了、再handshakeへ原子的に移る。

配送経路は2本に分ける。同一経路に混ぜると、通知の集中によって要求応答が捨てられ、timeoutを誘発するためである。

| 経路 | 対象 | 廃棄 |
| --- | --- | --- |
| 応答経路 | ACKと要求応答 | 廃棄しない。ただし容量は有限とする |
| 通知経路 | 機器からの通知 | 機能キー単位で最新値へ畳み込む |

応答経路を無制限にすると、消費側が停止した場合にメモリが際限なく増える。一方で応答を捨てると正当な応答を失う。したがって有限容量とし、超過した時点でセッション異常として扱う。具体的にはチャネルを破棄し、待機中の全要求を専用のエラーで完了させ、再handshakeする。捨てるのではなく、やり直す。

通知経路で畳み込みではなく廃棄が発生した場合、該当する機能の `freshness` を `stale` にして再取得を促す。

`control` とSETおよび検証GETは、UI由来の要求キューを経由せず、内部の直列executorで順番を待つ。UIの要求で埋まったキューによって、正しさに必要な処理が待たされることを防ぐ。

バッファ上限、消費停止、重複応答、通知の集中を組み合わせた負荷試験を行う。

#### 送信

- RFCOMMへの書き込みは単一のwriterへ集約する
- 部分書き込みを扱い、全バイトを書き切るまで継続する

送信側も有界化する。writerが部分書き込みや停止に陥った状態で通知が集中すると、ACKが際限なく溜まる。

| キュー | 容量 | 溢れた場合 |
| --- | --- | --- |
| ACK | 有限 | `sessionFault` |
| 通常要求 | 有限 | 3.5の優先度規則に従う |

ACKは通常要求より優先するが、無条件に優先し続けると通常要求が永久に送信されない。連続してACKを送出する上限を設け、上限に達したら通常要求を1件通す。

#### ACK

- 受信frameに対し、seqを反転したACKを即時返す
- ACK frameに対してはACKを返さない

#### 要求

- 要求は全体で直列とする。機器側が同時トランザクションを扱えない前提を明示する
- 応答の照合はcommandだけでなく、inquiry種別・table番号・slot等の識別子まで含める

`operationID` はローカルの採番であり、機器は返さない。したがって応答の帰属は次の契約とする。

- wire上のseqが要求と応答の相関に使えるかをPhase 1で確認する。使える場合は照合キーへ含める
- 使えない場合、応答は「現在ただ1件だけ進行中の要求」にのみ帰属させる。要求を全体で直列にしているため、これが成立する
- timeoutなどで帰属が曖昧になったセッションは破棄して再handshakeする。曖昧なまま次の要求を出さない
- 完了済みの要求と同じ照合キーの応答が後から届いた場合は破棄し、件数を記録する

ただし「要求1が完了し、同じ照合キーの要求2を送信した後に、要求1の重複応答が届く」場合、破棄すべき古い応答か要求2の正当な応答かを区別できない。したがって次のいずれかを満たすことをPhase 1の判断ゲートとする。

1. wire上のseqが相関に使える。この場合は照合キーへ含めて解決する
2. 使えない場合、同じ照合キーを再利用する前にセッションを更新する。これを安全側の既定とする

静止時間を置くだけの回避は、プロトコル上の遅延上限を根拠にできる場合に限り認める。「実機で重複を観測しなかった」ことは根拠にしない。有限回の試験では非発生を保証できず、誤帰属した検証GETは誤った値を確定させるためである。

seq相関の可否は、機種とfirmwareごとにPhase 1の必須成果物として確認し、結果を記録する。可否によって実行手順が変わる。

| seq相関 | 検証GETの再試行手順 |
| --- | --- |
| 使える | 照合キーにseqを含める。settle時間とバックオフのみで再試行する |
| 使えない | 再試行の前にチャネルを閉じ、再handshakeと再照合を行ってから実行する |

検証GETの再試行は同じ照合キーを繰り返し使うため、この分岐を3.3のsettleとバックオフの設計へ組み込む。使えない場合の再試行は高価なので、上限回数を小さく取る。
- ACK timeoutは1秒、応答timeoutは5秒とし、定数として一箇所に置く

要求は `awaitingACK` と `awaitingResponse` を独立して保持する。両方が満たされた時点で完了とする。

| 状況 | 扱い |
| --- | --- |
| ACK、本応答の順で到着 | 完了 |
| 本応答、ACKの順で到着 | 完了。順序は問わない |
| 本応答が先に届き、ACKがtimeout | 完了として扱う。機器は処理しているためである。ACK欠落は記録する |
| ACKのみ届き、本応答がtimeout | 失敗。SETの場合は「変更された可能性がある」として、検証GETで実際の値を確認してから確定する |
| 重複ACK | 破棄する |
| どちらも届かない | 失敗。セッションを破棄して再handshakeする |
- timeout時は当該セッションを破棄して再handshakeする。SETは自動再送しない
- 要求キューに上限を設ける。超過時の扱いは下記の優先度に従う
- 各要求のcontinuationはexactly-onceで再開する。完了フラグを持ち、応答・timeout・切断・キュー破棄のうち最初の1つだけが再開する
- clockを注入可能にし、timeoutを決定的に試験する

要求は次の優先度クラスを持つ。

| クラス | 対象 | 満杯時 |
| --- | --- | --- |
| `control` | handshake、機能capability取得 | 破棄しない |
| `verification` | SET後の検証GET | 破棄しない |
| `coalescibleWrite` | 連続値のSET | 同一機能の待機分を最新値で置き換える |
| `read` | 通常GET | 同一機能の最も古いものから破棄する |

SETとその検証GETは、単一の内部トランザクションとして通常キューの外で連続実行する。通常キューの空きに依存させると、SETを受理した後で検証GETが拒否され、確認できないまま変更だけが残るためである。同時に進行する内部トランザクションは常に1件とする。

`control` にも専用の実行枠を設ける。

したがって即時拒否の対象は `read` と、新規の `coalescibleWrite` だけである。`coalescibleWrite` の置き換えは3.3の `queuedLatest` と同じ機構で行う。拒否と破棄はいずれも専用のエラーで完了させ、呼び出し側を待たせない。

### 3.6 識別子の分離

有効性の判定に用いる識別子を3つに分ける。単一の世代番号では、同一RFCOMM接続のまま状態が進む場合に有効な通知まで無効と判定してしまうためである。

| 識別子 | 増える契機 | 用途 |
| --- | --- | --- |
| `connectionAttemptID` | RFCOMMのオープン試行1件ごと | オープン完了の有効性 |
| `sessionEpoch` | RFCOMMチャネルの生成と破棄 | 受信frameと通知コールバックの有効性 |
| `operationID` | 要求1件ごと | 応答とtimeoutの照合 |
| `policyGeneration` | `SessionPolicy` の状態遷移 | グレースタイマーとバックオフタイマーの有効性 |

`connectionAttemptID` はオープン試行の識別子であり、確立後のチャネルを表さない。したがってチャネルの生存期間には別途 `channelID` を用いる。

| 事象 | 付与する識別子 |
| --- | --- |
| `channelOpened` | `connectionAttemptID` と `channelID` |
| `channelFailed` | `connectionAttemptID` |
| `channelClosedUnexpectedly` | `channelID` と `sessionEpoch` |
| `channelClosedByUs` | `channelID`、`sessionEpoch`、`closeOperationID` |
| 受信frameと検証完了 | `sessionEpoch` |

`channelOpened` は「現在 `connecting` であり、対象機器と `connectionAttemptID` の双方が一致する」場合にのみ受理する。それ以外は必ず閉じる。同一attemptの重複した `channelOpened` も、`connecting` を離れていれば閉じる。

reducerへ投入する前に現在値と突き合わせ、一致しない事象は次のとおり扱う。

| 事象 | 識別子が古い場合の扱い |
| --- | --- |
| `channelOpened` | 開いたチャネルを直ちに閉じる。状態は変更しない |
| その他 | 破棄する。状態を変更しない |

古い `channelClosedByUs` が新しい接続の確立後に届いても、現在のセッションを落とさない。`channelOpened` だけは無視ではなく明示的なcloseとする。無視するとチャネルが漏れるためである。

### 3.7 接続ポリシー

Tandemの制御セッションは同時に1クライアントしか保持できない。Macが保持している間、スマートフォン側の純正アプリは使用できなくなる。したがって保持は必要最小限とする。

`SessionPolicy` は `reduce(state, event) -> (state, [Effect])` の純粋関数として実装する。副作用は `Effect` として返し、呼び出し側が実行する。

状態は次の通りとする。

| 状態 | 意味 |
| --- | --- |
| `released` | RFCOMM未接続 |
| `connecting` | RFCOMMを開いている |
| `verifying` | handshakeと3.4の照合、機能capability取得を行っている |
| `ready` | 制御可能 |
| `contended` | 他端末が制御権を保持していると確認できた。自動で奪い返さない |
| `suspended(resume:)` | 既定出力から外れ、グレース中。RFCOMMは保持する。復帰先を保持する |
| `retryWaiting` | バックオフ待ち |
| `retryExhausted` | 一時障害の再試行が上限に達した。手動で復帰できる |
| `incompatible` | 非互換と判定された。手動でも復帰しない |
| `sleeping` | システムスリープ中 |

事象は次の通りとする。

`defaultOutputChanged(DeviceIdentity?)` / `channelOpened` / `channelFailed` / `channelClosedUnexpectedly` / `channelClosedByUs` / `verificationSucceeded` / `verificationRejected` / `verificationFailedTransient(reason:)` / `controlContended` / `sessionFault(kind:channelID:epoch:)` / `graceExpired` / `backoffExpired` / `bluetoothDisconnected` / `willSleep` / `didWake` / `manualRetry` / `manualRelease`

#### セッション障害と回復バリア

応答のtimeout、バッファの溢れ、応答の帰属不能は、いずれも `sessionFault` として同じ経路で扱う。ポリシーに受け口がないと、再handshakeの契機が状態機械の外に置かれ、順序が保証されない。

`sessionFault` を受けた状態は `recovering` へ遷移する。`recovering` は接続と照合が済んでいても、**全てのSETを閉じる回復バリア**として働く。`verificationSucceeded` の直後に `ready` を開けてしまうと、回復GETより先に通常のSETを受理してしまう。

回復の順序を次に固定する。

1. 旧 `sessionEpoch` を無効化する
2. 待機中の要求を一括で完了させる
3. チャネルを閉じる
4. 再接続する
5. 照合する
6. 回復記録があれば回復GETを実行する
7. `ready` へ遷移してSETを再び受け付ける

回復記録の扱いは障害の種類で分ける。

| 障害 | 回復記録 |
| --- | --- |
| SET本応答のtimeout | 作成する。機器へ届いた可能性があるため |
| 検証GETのtimeout | 作成する |
| バッファの溢れ、帰属不能 | 進行中のSETがあれば作成する |
| 書き込み前の切断 | 作成しない |

`invalidateSession` は通常のトランザクションを終端するが、回復記録は終端しない。回復記録は別に保持し、回復GETの完了または再接続の断念でのみ終端する。

#### 対象機器の保持

`released` を除く全ての状態は、対象機器の識別子を保持する。既定出力の変化を真偽値で表すと、機器Aから機器Bへ切り替えた際に、Bが既定出力であるにもかかわらずAのセッションへ復帰してしまうためである。

`defaultOutputChanged` は次のとおり解釈する。

| 変化後 | 現在の対象との関係 | 扱い |
| --- | --- | --- |
| 対象機器 | 一致 | 復帰または接続開始 |
| 別の候補機器 | 不一致 | 保持中のチャネルを閉じ、`sessionEpoch` を無効化し、新しい `connectionAttemptID` でその機器へ接続する |
| 候補でない機器、または出力なし | — | 対象を失ったものとして扱う |

`suspended` からの復帰は、保持した対象と一致する場合に限る。

遷移の優先順位を次の順で評価する。上位に該当した時点で確定し、下位の規則は適用しない。

1. `willSleep` は全状態から `sleeping` へ遷移する
2. `manualRelease` は全状態から `released` へ遷移する
3. `sleeping` にいる場合、`didWake` 以外の全事象で状態を維持し、接続を伴うEffectを発行しない
4. `bluetoothDisconnected` が現在の対象機器のものであれば、全状態から `released` へ遷移する
5. `defaultOutputChanged` が現在の対象と異なる候補機器を示す場合、対象を切り替えて `connecting` へ遷移する
6. `incompatible` にいて、事象が保持中の対象に関するものである場合、状態を維持する
7. 以下の個別規則を適用する

`incompatible` は対象機器の識別子を保持する。ある機器が非互換であっても、別の対応機器へ切り替えた場合には接続できなければならないためである。規則5は規則6より上位に置く。

`didWake` は復帰時点の既定出力を伴う。スリープ中に届いた `defaultOutputChanged` で接続を始めないためである。

#### 再試行回数

ポリシーの状態は、対象機器ごとの `failureCount` を保持する。

handshakeやcapability取得の失敗は `verificationFailedTransient(reason:)` という事象で表す。`verificationRejected` は非互換の確定を表し、両者を区別する。

| 契機 | 扱い |
| --- | --- |
| `channelFailed`、`verificationFailedTransient`、`channelClosedUnexpectedly` | `failureCount` を1増やす。上限未満なら `retryWaiting`、上限以上なら `retryExhausted` |
| `verificationSucceeded` | 0へ戻す |
| 対象機器の切り替え | 0へ戻す |
| `manualRetry` | 0へ戻す |

成功後にリセットしないと、過去の一時障害が累積し、後日の1回の切断で即座に上限へ達してしまう。

| 現状態 | 事象 | 次状態 |
| --- | --- | --- |
以下、「対象を得た」は `defaultOutputChanged` が候補機器を示したこと、「対象を失った」は候補でない機器または出力なしを示したことを指す。

| 現状態 | 事象 | 次状態 |
| --- | --- | --- |
| `released` | 対象を得た | `connecting` |
| `connecting` | `channelOpened` | `verifying` |
| `connecting` | `channelFailed` | `retryWaiting` |
| `connecting` | 対象を失った | `released`（オープン中の接続は完了時に閉じる） |
| `verifying` | `verificationSucceeded` | `ready` |
| `verifying` | `verificationRejected` | `incompatible` |
| `verifying` | 対象を失った | `released`（未完了の検証は破棄し、接続を閉じる） |
| `ready` | 対象を失った | `suspended(resume: ready)`（60秒のグレース開始） |
| `suspended` | 保持した対象を得た | 保持した復帰先へ戻る |
| `suspended` | `graceExpired` | `released` |
| `suspended` | `channelClosedUnexpectedly` | `released` |
| `ready` / `verifying` | `controlContended` | `contended` |
| `ready` / `verifying` | `channelClosedUnexpectedly` かつ対象を保持している | `retryWaiting` |
| `ready` / `verifying` | `channelClosedUnexpectedly` かつ対象を失っている | `released` |
| `retryWaiting` | `backoffExpired` | `connecting` |
| `retryWaiting` | 対象を失った | `released` |
| `retryExhausted` / `contended` | 対象を得た | 状態を維持する |
| `retryExhausted` / `contended` | 対象を失った | `released` |
| `retryExhausted` / `contended` | `manualRetry` かつ対象が現に既定出力 | `connecting` |
| `sleeping` | `didWake` かつ候補機器が既定出力 | `connecting` |
| `sleeping` | `didWake` かつそれ以外 | `released` |

#### 意図的なcloseの完了

ポリシーが発行した `closeChannel` に対して届く `channelClosedByUs` は、状態を変更しない。状態変更は `closeChannel` を発行した遷移の時点で既に済んでいるためである。完了通知でさらに `released` へ落とすと、`contended`、`retryWaiting`、`incompatible` を維持できない。

`closeChannel` には `closeOperationID` を持たせ、完了通知と対応付ける。対応付かない `channelClosedByUs` は破棄する。

`manualRelease` だけが明示的に `released` へ遷移させる。

`verifying` 中に既定出力を失った場合は `suspended` にせず接続を破棄する。未完了の検証を飛ばして `ready` に到達し、SETが可能になることを防ぐためである。

意図しない切断で既定出力のままの場合は `released` にせず `retryWaiting` とする。`released` にすると既定出力のままで再接続の契機を失うためである。

`suspended` 中に切断を受けた場合は `released` とする。切断済みのまま復帰して `ready` へ戻ることを防ぐためである。

`contended` および `retryExhausted` 中に対象を失った場合も `released` とする。`manualRetry` は、対象機器が現に既定出力である場合にのみ受け付ける。対象でない機器へ接続することを防ぐためである。

#### Effect

`reduce` が返す副作用は次のとおりとする。

`openChannel(attemptID)` / `cancelOpen` / `closeChannel` / `invalidateSession` / `startVerification` / `startGrace` / `cancelGrace` / `scheduleBackoff(n)` / `cancelBackoff`

| 遷移 | Effect |
| --- | --- |
| `released → connecting` | `openChannel` |
| `connecting → verifying` | `startVerification` |
| `connecting → retryWaiting` | `scheduleBackoff` |
| `connecting → released` | `cancelOpen`、`closeChannel` |
| `verifying → ready` | なし |
| `verifying → incompatible` | `closeChannel`、`invalidateSession` |
| `verifying → released` | `closeChannel`、`invalidateSession` |
| `ready → suspended` | `startGrace` |
| `suspended → ready` | `cancelGrace` |
| `suspended → released` | `cancelGrace`、`closeChannel`、`invalidateSession` |
| `* → contended` | `closeChannel`、`invalidateSession` |
| `* → retryWaiting` | `closeChannel`、`invalidateSession`、`failPendingRequests`、`scheduleBackoff` |
| `* → retryExhausted` | `closeChannel`、`invalidateSession`、`failPendingRequests`、`cancelBackoff` |
| `retryWaiting → connecting` | `cancelBackoff`、`openChannel` |
| `retryWaiting → released` | `cancelBackoff` |
| `contended → connecting` | `openChannel`、再試行回数のリセット |
| `retryExhausted → connecting` | `openChannel`、再試行回数のリセット |
| `sleeping → connecting` | `openChannel`、`failureCount` のリセット |
| 対象機器の切り替え | `cancelOpen`、`cancelGrace`、`cancelBackoff`、`closeChannel`、`invalidateSession`、`openChannel`（新しい対象へ）、`failureCount` のリセット |

対象機器を切り替える際は、遷移元の状態が保持していたオープン試行、グレースタイマー、バックオフタイマーを全て取り消してから、旧セッションを無効化する。取り消しを省くと、旧対象のタイマーが新しい対象の接続へ干渉する。
| `* → released` | 保持中の資源に応じて `cancelOpen` / `cancelGrace` / `cancelBackoff` / `closeChannel` / `invalidateSession` |
| `* → sleeping` | `closeChannel`、`invalidateSession`、全タイマー取消 |

全状態と全事象の組み合わせについて、次状態とEffectの両方をテーブル駆動で試験する。定義のない組み合わせは状態維持かつ副作用なしとし、それも試験対象とする。

#### `contended` の扱い

「RFCOMMは開くがhandshake応答が来ない」という観測は、パケット欠落、パーサの不具合、firmware差異でも生じ、他端末による占有と区別できない。誤って `contended` と判定すると自動復帰が恒久的に止まる。

したがって初期実装では `controlContended` を発火させない。handshakeのtimeoutは一時障害として扱い、バックオフして再試行し、上限で `retryExhausted` とする。Phase 1で再現可能な拒否応答または固有のエラーを実機で確認できた場合に限り、その条件で `controlContended` を発火させる。

再接続は指数バックオフとし、上限で `retryExhausted` に停止する。`contended` および `retryExhausted` からの自動復帰は行わない。

### 3.8 対象機器の一意特定

表示名の一致による判定は行わない。同型機器の併用、A2DPとHFPの切替、複数Bluetooth出力を安全に扱えないためである。

- CoreAudioの既定出力から `kAudioDevicePropertyDeviceUID` と transport type を取得する
- Bluetooth出力のUIDから機器アドレスを取り出し、`IOBluetoothDevice` のアドレスと突き合わせる
- 対応付けができない場合、または候補が複数ある場合は接続せず、ユーザーへ選択を求める

UIDが機器アドレスを含む形式であることは公開された契約ではない。したがって解析処理は交換可能なadapterとして隔離し、OSバージョン別のfixtureを持つ。将来のOS更新で解析できなくなった場合は、自動同定を諦めて手動選択へ落ちる。誤った機器へSETするより、選択を求める方が安全である。

手動選択した場合は、Audio UIDと `IOBluetoothDevice` の識別子の対応を保存する。ここでの安定IDは `IOBluetoothDevice` のアドレス文字列とし、保存はハッシュ値で行う。UIとログには出さない。

同定の経路にかかわらず、SETを送る前に毎回、対象が接続中であること、ペアリング済みであること、3.4の照合を通過していることを確認する。

この確認とフォールバックの実装をPhase 1の完了条件に含める。

### 3.9 並行性の隔離境界

| 対象 | 隔離 |
| --- | --- |
| `DeviceState`、`NowPlayingCenter`、全てのView | `@MainActor` |
| `TandemController`、`TandemRouter` | actor |
| `RFCOMMTransport` | 専用スレッドとRunLoop。外部へは `AsyncStream` とasyncメソッドだけを出す |
| ScriptingBridge呼び出し | 専用のシリアルキューまたはスレッド。actorには置かない |

境界を越える値は全て `Sendable` なスナップショット構造体とする。`@Observable` の更新はメインアクター上でのみ行う。

ScriptingBridgeをactorへ置かないのは、Swiftのactorが専用スレッドを持たず協調スレッドプール上で動くためである。同期のApple Eventsが相手アプリの停止で長時間返らないと、プール全体を圧迫する。専用のシリアルキューまたは専用スレッドへ閉じ込め、bridgeオブジェクトの生成と使用を同じ実行コンテキストで行う。

結果にはソースの世代番号を付け、遅れて返ってきた結果を破棄する。相手アプリが応答しない状態でも、UIとセッション処理が止まらないことを試験する。

## 4. アーキテクチャ

```
IOBluetoothRFCOMMChannel
        │
   RFCOMMTransport      TandemTransport プロトコルの実体。単一writer
        │
   TandemRouter         ストリーム解釈、即時ACK、応答と通知の振り分け
        │
   TandemController     actor。要求の直列化とSETの可否判定
        │
   SessionCoordinator   actor。単一の隔離主体
        │
   DeviceState          @MainActor。UIが購読する単一の状態
        │
   NotchPanelView
```

`SessionCoordinator` は次を単独で所有する。所有者を1つに定めないと、識別子の採番とEffectの実行が別々の場所で進み、検証の開始とセッション無効化が競合する。

- CoreAudio、Bluetooth、電源、RFCOMMの各コールバックの直列化
- `connectionAttemptID`、`sessionEpoch`、`policyGeneration`、`closeOperationID` の採番
- `SessionPolicy` への事象の投入
- Effectの実行と、その完了事象の再投入

Effectは識別子を伴い、冪等とする。古いEffectの完了が届いた場合も安全であることを試験する。

再生系は独立系統とする。

```
DistributedNotificationCenter / ScriptingBridge / NSWorkspace
        │
   NowPlayingSource     プレーヤーごとの実装
        │
   NowPlayingCenter     ソース選択と再同期
        │
   NowPlayingColumn
```

## 5. ディレクトリ構成

```
Package.swift
README.md
LICENSE
docs/implementation-plan.md
Support/Info.plist
Support/Perch.entitlements
tools/package_app.sh
Sources/
  TandemCore/        プロトコル層。既存から移植
  TandemSession/     常駐セッション
  NowPlaying/        再生情報と再生操作
  NotchKit/          ノッチのウィンドウ・幾何・入力・ページャー
  Perch/      アプリ本体
Tests/
  TandemCoreTests/
  TandemSessionTests/
  NotchKitTests/
  NowPlayingTests/
```

### 5.1 TandemCore

`sound-connect-pc` から移植する。プロトコル解釈のロジックは変更しない。

```
TandemFrame.swift        ReadOnlyHandshake.swift   ReadOnlyStatus.swift
FeatureState.swift       Equalizer.swift           ExternalSound.swift
ListeningMode.swift      SpeakToChat.swift         GeneralSetting.swift
Multipoint.swift         VerifiedDevice.swift
```

移植時に、実機の個体名、Bluetoothアドレス、ローカルパス、ユーザー名を含む文字列を除去する。コメントアウトされた旧コードを残さない。

### 5.2 TandemSession

既存の `MacTandemReadOnlyProbe.swift`（2093行）が持つ責務を分割して再構成する。

| ファイル | 責務 |
| --- | --- |
| `TandemTransport.swift` | 送受信の抽象プロトコルと注入可能なclock |
| `RFCOMMTransport.swift` | IOBluetoothの実装。単一writer、部分書き込み処理 |
| `FrameStreamParser.swift` | 3.5の受信ストリーム解釈 |
| `TandemRouter.swift` | 即時ACKと、応答・通知の振り分け |
| `TandemRequest.swift` | 要求の型定義。command、照合キー、timeout |
| `TandemController.swift` | actor。直列実行とSET可否の不変条件 |
| `SessionCoordinator.swift` | actor。識別子の採番、事象の投入、Effectの実行 |
| `FeatureRequests.swift` | 機能別の要求生成。TandemCoreへ委譲する |
| `SessionPolicy.swift` | 3.7の純粋reducer |
| `AudioOutputObserver.swift` | 既定出力の監視と3.8の同定 |
| `BluetoothObserver.swift` | 接続と切断の監視 |
| `PowerObserver.swift` | スリープと復帰の監視 |
| `DeviceState.swift` | `@MainActor @Observable`。3.3の状態を保持 |

各ファイルは400行を上限とする。

### 5.3 NowPlaying

| ファイル | 責務 |
| --- | --- |
| `NowPlayingSnapshot.swift` | 曲ID、タイトル、アーティスト、長さ、位置、再生中か、ジャケット参照、ソース |
| `NowPlayingSource.swift` | プロトコル。購読、取得、再生操作、権限状態 |
| `SpotifySource.swift` | `com.spotify.client.PlaybackStateChanged` の購読とScriptingBridge操作 |
| `MusicAppSource.swift` | `com.apple.Music.playerInfo` の購読とScriptingBridge操作 |
| `NowPlayingCenter.swift` | ソース選択、再同期、publish |
| `ArtworkCache.swift` | ソースと曲IDの複合キーによるメモリキャッシュ |

#### 権限との関係

分散通知の購読はApple Eventsを伴わないため、権限なしで動作する。ScriptingBridgeの呼び出しはApple Eventsを送るため権限を要する。両者を明確に分ける。

- 起動時に `AEDeterminePermissionToAutomateTarget` を `askUserIfNeeded` を偽にして呼び、対象アプリごとに未判定・許可・拒否を判定する。この呼び出しはプロンプトを出さない
- 許可済みの場合のみ、購読開始直後に現在値を1回取得する
- 未判定の場合は分散通知だけで動作する。ジャケット表示と再生操作のUIは出さない
- ユーザーがジャケット表示または再生操作を明示的に求めた時に、`askUserIfNeeded` を真にして許可を要求する
- 拒否された場合、以後その操作のUIを出さない

#### 再同期

分散通知は配送保証がなく、遅延や欠落があり得る。ペイロードの形式も公開された契約ではない。したがって通知だけに依存しない。

- `NSWorkspace` でプレーヤーアプリの起動と終了を監視する
- ノッチ展開時に再同期する
- 60秒間隔で再同期する
- 再生位置はノッチが開いている間だけ1秒間隔で補間する

いずれも権限が許可済みの場合に限る。

#### ソース選択

1. 再生中のソースを優先する
2. 同順の場合、最後に有効なイベントを発したソースを選ぶ

欠落フィールドは許容し、取得できた範囲だけ反映する。ジャケットキャッシュは件数上限を設け、ディスクへ書かない。

ScriptingBridgeのglueをSwiftPMへ組み込む方式は、Phase 0で実証する。組み込めない場合は `NSAppleScript` による最小限の呼び出しにフォールバックする。

### 5.4 NotchKit

アプリ非依存の部品として、NotchDropのコードを複製せずに実装する。

| ファイル | 責務 |
| --- | --- |
| `ScreenNotchGeometry.swift` | ノッチ矩形の算出 |
| `NotchWindow.swift` | borderless NSWindow |
| `NotchWindowController.swift` | 内蔵ディスプレイに1枚だけ配置 |
| `NotchShape.swift` | 反転角のマスク |
| `PointerMonitor.swift` | ポインタ位置の観測 |
| `NotchPresenter.swift` | closed / peek / expanded の状態機械 |
| `VerticalPager.swift` | ホイールによるページ送り |
| `NotchAccessorySlot.swift` | ノッチ左右へ表示要素を差し込む口 |

#### 幾何

`auxiliaryTopLeftArea` と `auxiliaryTopRightArea` は「遮られていない左上・右上の領域」であり、ノッチ矩形そのものではない。中央の遮蔽領域は、同一のスクリーン座標系で座標から求める。

```
x      = leftArea.maxX
width  = rightArea.minX - leftArea.maxX
height = safeAreaInsets.top
y      = screen.frame.maxY - height
```

幅の引き算で求めてはならない。画面の原点が0でない配置、左右非対称な領域、領域に余白がある場合に、位置または幅を誤る。誤った矩形はクリック判定をずらし、他アプリのメニュー操作を妨げる。

次を満たさない場合はノッチなしと判定する。

- `safeAreaInsets.top` が0より大きい
- 左右いずれの領域もnilでない
- `width` が正である
- 求めた矩形が画面のframeに含まれる

算出は純粋関数とし、原点が非ゼロの画面、左右非対称な領域、無効な領域を含むfixtureで固定する。

再計算の契機は次の通りとする。

- `NSApplication.didChangeScreenParametersNotification`
- ディスプレイの追加と取り外し
- メニューバー自動非表示設定の変化

判定は「内蔵ディスプレイがあるか」ではなく「有効なノッチ矩形を持つ画面があるか」で行う。ノッチのない内蔵ディスプレイ、幾何の取得失敗、未対応の画面構成でも到達不能にならないためである。

有効なノッチ矩形が1つもない間は、ユーザー設定より優先してメニューバー項目を強制表示する。`LSUIElement` のため、これがないと設定、権限の要求、終了へ到達する手段が完全に失われる。

画面構成が変わって有効なノッチ矩形が現れたら、強制表示を解除してユーザー設定へ戻す。

#### 入力

- closed かつアクセサリ非表示の間は `ignoresMouseEvents` を真にする。背後のメニューとステータス項目の操作を妨げないためである
- peek と expanded の間は偽にし、ウィンドウをキーにできるようにする
- 他アプリへのクリックを横取りしない
- キーボードは監視しない

ポインタの追跡は、ウィンドウがイベント対象であるか否かで受け取れる経路が変わる。グローバルモニタは自アプリ宛てのイベントを受け取らず、ローカルモニタは他アプリ宛てを受け取らない。したがって全状態を覆うために次を併用する。

| 経路 | 用途 |
| --- | --- |
| グローバルモニタ | ウィンドウがイベント対象でない間のポインタ位置 |
| ローカルモニタ | 展開後の自ウィンドウ上の操作 |
| `NSEvent.mouseLocation` の周期取得 | グローバルモニタが利用できない場合の主経路 |

グローバルモニタの利用可否と配送範囲はOSとTCCの状態に左右され得る。したがってPhase 2の前提として、初期化済みでないTCC状態において、許可プロンプトも入力監視への登録も発生せず、closed状態のポインタ移動を取得できることを実機で確認する。確認できない場合はポーリングを主経路とする。

ポーリングの条件を数値で定める。

| 項目 | 値 |
| --- | --- |
| closed時のサンプリング周期 | 100ms |
| ノッチ矩形内を検出した後の周期 | 33ms |
| 滞在タイマーの起点 | 矩形内を検出した最初のサンプルの時刻 |
| 滞在判定の許容誤差 | サンプリング周期1回分 |
| closed時のCPU使用率上限 | 0.5% |

モニタとタイマーの登録と解除のライフサイクルを明示し、ウィンドウの再生成や画面構成の変更で二重登録が起きないことを試験する。

#### ウィンドウの属性

次をPhase 2の着手前に実機で確定させる。

| 項目 | 確認すること |
| --- | --- |
| ウィンドウ種別 | `NSWindow` と `NSPanel` のどちらが要件を満たすか |
| level | メニューバーより前面に出て、かつ他アプリの操作を妨げない値 |
| `collectionBehavior` | `canJoinAllSpaces`、`fullScreenAuxiliary`、`stationary`、`ignoresCycle` の要否 |
| activation policy | `LSUIElement` 下でウィンドウをキーにできるか |
| フルスクリーン | 他アプリのフルスクリーンSpaceでノッチ領域へ到達できるか |

#### ホイール

- `scrollingDeltaY` を累積し、閾値を超えた時点で1ページだけ送る
- 送出したら、そのジェスチャが `.ended` に達するまでラッチし、追加の送出を行わない
- `momentumPhase` が `.none` 以外の間は送出しない
- 端に達した場合は8ポイントのバウンスで限界を示す

累積、ラッチ、慣性抑止は純粋関数として実装し、単体テストで固定する。

### 5.5 Perch

```
main.swift              AppDelegate.swift        AppModel.swift
NotchPanelView.swift    NowPlayingColumn.swift   DeviceHeaderView.swift
Pages/NoiseControlPage.swift    Pages/EqualizerPage.swift
Pages/SpeakToChatPage.swift     Pages/SidetonePage.swift
Pages/ConnectionPage.swift
Settings/SettingsStore.swift    Settings/SettingsView.swift
```

## 6. UI仕様

### 6.1 3つの状態

| 状態 | 内容 |
| --- | --- |
| closed | 何も描かない。設定でノッチ左右のアクセサリを有効にした場合のみ表示する |
| peek | ポインタが100ms滞在で数ポイント膨らむ |
| expanded | クリックで展開する |

### 6.2 展開パネル

左に再生カラム、右にヘッダーと縦ページャーを置く。

```
┌──────────┬────────────────────────────────────────┐
│          │  機種名          L 82  R 79  ケース 95  │
│ ジャケット │  ───────────────────────────────────  │
│          │                                        │
│ ▁▁▁▂▁▁   │  （1ページ分の機能）                 ○●○○○ │
│ ⏮  ⏯  ⏭  │                                        │
└──────────┴────────────────────────────────────────┘
```

- 再生カラムは幅96ポイント。ジャケット、再生位置バー、`⏮ ⏯ ⏭` を縦に並べる
- 曲名とアーティストはパネルに常設しない。ジャケットへのポインタ滞在時にツールチップで示す
- 再生中でない、対応プレーヤーが動作していない、または権限が未許可の場合、再生カラムを幅0へアニメーションで畳み、右側を全幅に広げる。空のプレースホルダは置かない
- ヘッダーの機種名とバッテリーは全ページで固定表示する
- ホイールはパネル全体で受け付ける

### 6.3 ページ構成

| 順 | ページ | 内容 |
| --- | --- | --- |
| 1 | ノイズコントロール | ノイズキャンセリング / 外音取り込み / オフ、外音レベル、Voice Focus |
| 2 | イコライザー | プリセット選択 |
| 3 | スピーク・トゥ・チャット | 有効無効、感度、終了時間 |
| 4 | 自声取り込み | 有効無効 |
| 5 | 接続 | コーデック、再生元、マルチポイント接続先 |

機器が非対応の機能はページごと表示しない。一時的に取得できなかった機能はページを残し、減光と1行の理由を示す。

イコライザーとBGMモードが競合し得る場合のみ、確認を挟む。

### 6.4 ノッチ左右のアクセサリ

`NotchAccessorySlot` は leading と trailing の2枠を持ち、表示要素を後から追加できる列挙型で指定する。初期は機種名とL/Rバッテリーを用意し、既定は両枠とも無効とする。

高さと文字サイズをメニューバーに揃える。セッションが `ready` または `suspended` でない間は表示しない。

ノッチの左右はアクティブアプリのメニューとステータス項目が占める領域と重なる。これは回避できないため、明示的に有効化した場合のみ表示する。有効時も `ignoresMouseEvents` は真のままとし、クリックは背後へ通す。

### 6.5 設定

ヘッダー右端から設定ページへ遷移する。項目はアクセサリの選択、ログイン時起動、状態変化時のポップ表示の有無、そして下記の音楽アプリ連携に限る。メニューバー項目は既定で表示せず、設定から有効にできる。内蔵ディスプレイがない構成では既定で表示する。

#### 音楽アプリ連携

権限を要求する経路がどこにもないと、未許可の状態から復帰できない。したがって設定に対応プレーヤーごとの項目を置く。

| 表示 | 操作 |
| --- | --- |
| 未導入 | なし |
| 未判定 | 「連携する」。ここで初めて `askUserIfNeeded` を真にして許可を求める |
| 許可 | 「連携中」。解除はシステム設定で行う旨を示す |
| 拒否 | システム設定のオートメーション設定を開く導線と、状態の再確認 |

権限の状態と表示の対応を次のとおり定める。

| 権限 | 曲名・再生状態 | ジャケット | 再生操作 |
| --- | --- | --- | --- |
| 許可 | 表示する | 表示する | 有効 |
| 未判定 | 表示しない | 表示しない | 無効 |
| 拒否 | 表示しない | 表示しない | 無効 |

分散通知は権限なしでも届くが、未許可のうちは表示に使わず、どのプレーヤーが動いているかの判定にのみ用いる。許可していないのに曲名が表示される挙動を避けるためである。

## 7. 配布・署名・権限

Phase 0で確定させる。TCCの許可は署名の同一性に紐づくため、後回しにすると許可の再取得が繰り返し発生する。

| 項目 | 方針 |
| --- | --- |
| bundle ID | 固定する。以後変更しない |
| App Sandbox | 使用しない。Classic BluetoothのRFCOMMを扱うため |
| Hardened Runtime | 有効にする |
| 署名 | 開発中は安定した自己署名証明書を用いる。ビルドのたびに変わるad-hoc署名は使わない |
| 配布 | 段階方針(3.1)。当面はローカルビルドのみ。GitHub Releasesでの第三者配布は将来の段階 |
| notarization | ローカル配布の間は行わない。GitHub Releases配布を始める段階で必須となる(Developer IDで署名し、`notarytool` へ提出して `stapler` で添付する) |
| `NSBluetoothAlwaysUsageDescription` | 必須 |
| `NSAppleEventsUsageDescription` | 必須 |
| `com.apple.security.automation.apple-events` | 必須 |
| `LSUIElement` | 有効。Dockに表示しない |
| ログイン時起動 | `SMAppService.mainApp` を用い、`enabled` / `requiresApproval` / `notRegistered` を区別して表示する |

| 権限 | 要否 |
| --- | --- |
| Bluetooth | 必須 |
| Apple Events | 再生表示と再生操作を使う場合のみ |
| アクセシビリティ | 不要 |
| 画面収録・入力監視 | 不要 |

## 8. テスト戦略

| 対象 | 方法 | 目標 |
| --- | --- | --- |
| TandemCore | 既存のfixtureテストを移植 | 80%以上 |
| TandemSession | 下記8.1 | 80%以上 |
| NowPlaying | 分散通知ペイロードのfixture、ソース選択規則、欠落フィールドの許容、権限状態ごとの分岐 | 80%以上 |
| NotchKit | 幾何算出（非ゼロ原点、左右非対称、無効な領域を含む）と、ホイールの累積・ラッチ・慣性抑止を純粋関数として検証 | 80%以上 |
| Perch | 実機による受入試験 | 対象外 |

IOBluetooth、CoreAudio、ScriptingBridgeへの依存はプロトコル境界の外側に閉じ込め、テストからは触れない。

### 8.1 TandemSessionの検証項目

- 分割frameと連結frameの解釈
- checksum不一致からの再同期
- 最大frame長超過、frame途中のstart byte、末尾escapeからの再同期
- 通知が集中した際に受信バッファが有界に保たれること
- 部分書き込みの継続とACKの優先送出
- 応答順序の逆転
- ACK欠落とACK timeout
- 応答timeoutと、その後に到着した遅延応答の破棄
- 途中切断、キュー破棄、timeoutが重なった場合もcontinuationがexactly-onceで再開されること
- 照合前および照合失敗時にSETが拒否されること
- 変更トランザクションの `done` / `failed` / 切断の各遷移
- 先行トランザクション確定時に `queuedLatest` の楽観表示が消えないこと
- 遅延GETが `confirmed` を過去値へ戻さないこと
- `connectionAttemptID` 不一致のオープン完了でチャネルが確実に閉じられること
- `sessionEpoch` による古い受信の無効化
- `policyGeneration` による古いタイマーの無効化
- `SessionPolicy` の全状態と全事象について、次状態とEffectの両方
- 機器Aから機器B、Aから候補外を経てA、Aから候補外を経てBへの既定出力変化
- ポリシーが発行したcloseの完了通知が `retryWaiting` / `contended` / `incompatible` を壊さないこと
- SET受理後に検証GETが必ず実行されること
- 検証の遅延適用、恒久的な不一致、SET直後の外部変更
- 要求キュー上限に達した際の破棄規則と、破棄要求の完了
- 要求1の完了、同じ照合キーでの要求2の送信、要求1の重複応答、要求2の正当な応答という順序で、誤帰属が起きないこと。検証GETと通常GETの双方で確認する
- writerを停止させた状態で通知を集中させ、ACKキューが上限で止まり `sessionFault` を経て再handshakeへ至ること
- ACKが連続する状況でも通常要求が送信されること
- `sessionFault` から回復GETを経て `ready` に戻るまでの順序と、回復バリア中にSETが拒否されること

clockを注入して決定的に実行する。

### 8.2 実機受入マトリクス

| 観点 | 内容 |
| --- | --- |
| 表示 | 内蔵のみ、外部ディスプレイ併用、外部のみ、フルスクリーンアプリ表示中、メニューバー自動非表示 |
| 入力 | closed時に背後のメニューとステータス項目が操作できること |
| 電源 | スリープと復帰、Bluetoothのオフとオン |
| 権限 | Apple Events未判定、許可、拒否、片方のみ許可 |
| 再生 | Spotifyのみ、Musicのみ、両方起動、両方再生、いずれも停止 |
| 機器 | 対応機器、非対応機器、同型2台、制御権が他端末にある状態 |
| 性能 | 1章の3シナリオを区間A・Bで自動計測し、実表示のp95を高速度撮影で補完 |

## 9. フェーズ

### Phase 0 — 土台

- `Package.swift`、`.gitignore`、`README.md`、`LICENSE`
- `Support/Info.plist`、`Support/Perch.entitlements`、`tools/package_app.sh`
- bundle ID、署名方式、Hardened Runtime、deployment targetの確定
- ScriptingBridge glueのSwiftPM組み込みの実証
- 移植対象一覧とライセンス確認結果の記録
- `TandemCore` の移植と、テスト39件の移植
- 完了条件: `swift test` が緑であり、署名済みの空アプリが起動してBluetooth権限を要求でき、ScriptingBridgeの呼び出しがビルドを通る

### Phase 1 — 常駐セッション

- `TandemSession` 一式
- 8.1の検証
- 検証用の最小CLIで実機のGET・NTFY・SETを確認する
- 完了条件: 3.8の同定が実機で機能し、出力先の切替に追従して接続と解放が行われ、通知でバッテリーが更新される

### Phase 2 — ノッチの器

- 着手前に5.4のウィンドウ属性を実機で確定させる
- `NotchKit` 一式と `NowPlaying`
- ダミーの機器状態で、開閉、縦ページャー、再生カラム、アクセサリを完成させる
- 完了条件: Bluetooth機器なしでUIの操作感を確認でき、8.2の表示と入力と権限の項目を通過する

### Phase 3 — 結合

- 5ページ全ての実装と、3.3の状態表示
- 完了条件: 8.2を全て通過し、1章の計測条件を満たす

### Phase 4 — 仕上げ

- 設定、状態変化時のポップ表示、ログイン時起動、`.app` の生成
- 完了条件: Finderから起動して常駐し、ログイン項目の各状態を正しく表示する

## 10. リスク

| リスク | 対策 |
| --- | --- |
| IOBluetoothのデリゲートがSwift 6の並行性検査と噛み合わない | 非Sendableな境界を `RFCOMMTransport` 1ファイルに閉じ込め、3.9の隔離に従う |
| IOBluetoothが特定のRunLoopを要求する | 専用スレッドでRunLoopを保持し、外部へはasyncの口だけ出す |
| CoreAudioのUIDから機器を同定できない | Phase 1で実機確認する。同定できない場合はユーザーへ選択を求める経路を必ず用意する |
| ScriptingBridge glueをSwiftPMへ組み込めない | Phase 0で実証し、不可なら `NSAppleScript` へ切り替える |
| 常駐がスマートフォン側の純正アプリを妨げる | 3.7の状態機械で保持を最小化し、`contended` から自動奪取しない |
| ノッチ左右のアクセサリがメニューと重なる | 既定で無効とし、有効時もクリックは背後へ通す |
| 分散通知の内容がプレーヤーの更新で変わる | 欠落フィールドを許容し、定期再同期とアプリ起動監視で補う |
| ホイールの慣性でページが飛ぶ | ジェスチャ単位のラッチを純粋関数として単体テストする |
| 署名の変化でTCC許可が失われる | Phase 0で署名identityを固定する |

## 11. 対象外

次は実装しない。

- 解析レポートの保存、実験的接続
- 任意のrawペイロード送信、FOTA、リセット、ペアリング解除、電源操作、音源切替
- 非公開APIによるシステム全体の再生情報取得
- ブラウザで再生される音声への対応
- Windows対応
- 申請から自動で許可制へ登録すること

未知機種の読み取り表示と、利用者の操作で始まる対応申請は対象内とする。3.4の照合は
SETに対する条件であり、GETと表示には課さない。誤った解釈でもACKは成功で返るため、
危険なのは書き込みだけである。読める範囲を閉じても安全は増えず、対応機種を広げる
手掛かりだけが失われる。

申請の内容はメモリ上にとどめ、ディスクへ保存しない。公開の場所へ出すかどうかは
その都度、利用者の操作で決まる。組み立てとURL化は `TandemCore` の純粋な変換として
実装し、送信は行わない。

許可制への登録は、実機で読み戻して意図どおりになることを確かめてから人手で行う。
申告されていることと操作できることは別であり、コードの検討だけでは判定できない。
起草とリリースは自動化してよいが、登録の判断は自動化しない。
