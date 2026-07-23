# RFCOMMトランスポートの申し送り

`Sources/TandemSession/RFCOMMTransport.swift` を書く際に踏みうる箇所を、先行実装の
記録から集めたもの。2026-07-22時点。

**ほとんどはこの環境で未検証である。** 出所は他プロジェクトのコード内コメント、
配布されているパッチ、Appleのフォーラム投稿であり、追試していない。確度を項目ごとに
記す。実装の前に4のプローブで潰すのが早い。

対象環境は **macOS 26 世代** である。macOS 26に固有として報告されている項目は、
仮定ではなく直接あてはまる。

---

## 1. RFCOMMチャンネル番号は機種ごとに違う

**確度: 高い。多機種へ広げるなら必須。**

チャンネル番号を定数で持つと、その番号を使う機種でしか開けない。実測値が
`AndreasOlofsson/mdr-protocol` に残っている。

| 機種 | チャンネル |
| --- | --- |
| WF-1000XM3 | 9 |
| WH-1000XM3 | 15 |

番号はSDPのサービスレコードから取る。同時に、どちらのUUIDで見つかったかで
プロトコル世代も決まる。

| 世代 | Service UUID |
| --- | --- |
| v2（XM4以降、LinkBuds、CH720N、ULT WEAR など） | `956C7B26-D49A-4BA8-B03F-B17D393CB6E2` |
| v1（XM3以前） | `96CC203E-5068-46AD-B32D-E316F5E069BA` |

```swift
// v2を先に試し、無ければv1へ落とす
let record = device.getServiceRecordForUUID(uuid)
var channelID: BluetoothRFCOMMChannelID = 0
record?.getRFCOMMChannelID(&channelID)
```

## 2. `performSDPQuery(_:uuids:)` はVentura以降サイレント失敗する

**確度: 中。1でSDPを使い始めたときに関係する。**

完了コールバックが永久に来ない。`uuids` 引数を取らない `performSDPQuery(_:)` を使う。
Big Sur 11.3では動き、Ventura 13.1以降で再現するという報告がある。

- Apple Developer Forums thread 722228（再現コードと回避策）
- `GalaxyBudsClient` の `Bluetooth.mm` に同じ回避が実装され、コメントで理由が書かれている

## 3. macOS 26では `openRFCOMMChannelAsync` の完了コールバックが発火しない

**確度: 中。ただし対象環境はmacOS 26世代なので、外れていなければ必ず当たる。**

`jagvaandanzan/sonyxmctl` が `patches/macos26-rfcomm.patch` として回避を配布している。
READMEの記述は次のとおり。

> on macOS 26 the async variant's completion callback never fires (bluetoothd never
> receives the open request); the sync variant works.

`openRFCOMMChannelSync` へ替えると、今度は**成功しても `kIOReturnError` を返す**。
`GalaxyBudsClient` のコメント。

> For unknown reasons, status is always kIOReturnError even if connection was
> successful... we work it around by using openRFCOMMChannelSync then relying on
> RFCOMM channel to open after at most 1.5s

したがって戻り値では判断せず、`isOpen` を見て開通を判定することになる。

## 4. macOS 26の `bluetoothd` はLaunchServices経由で起動したアプリしか許可しない

**確度: 中。3と同じ出所。**

`sonyxmctl` のREADMEより。

> bluetoothd only allows classic RFCOMM connections from LaunchServices-launched apps.

ターミナルから直接起動したバイナリは `kIOReturnError`（`handleSetPeerState, invalid
peer`）で失敗する。回避は `.app` にして `open` で起動すること。

**`swift run` やテストのプロセスからは通らない可能性がある。** 実機を使う確認は
`tools/package_app.sh` が作る `.app` を `open` で起動して行う必要がある。これは
デバッグの取り回しに影響するため、早めに確かめておきたい。

## 5. ベースバンド接続を先に張る必要がある

**確度: 中。**

`GalaxyBudsClient` のコメント。

> The openRFCOMMChannel... API probably should do this for us, but for now we have to
> do it manually

`device.isConnected()` が偽のときに失敗として返すのではなく、`device.openConnection()`
で接続してからRFCOMMを開く余地がある。ただし本アプリは3.7の接続ポリシーで保持を
最小化する方針なので、どこまで能動的に繋ぎにいくかは設計判断になる。

## 6. 確認済みで、対処が要らないもの

- `NSBluetoothAlwaysUsageDescription` は `Support/Info.plist` に記載済み。
  これが無い場合、CoreBluetoothと違って**クラッシュせず `pairedDevices()` が空配列を
  返すだけ**になるため、デバッグで最も紛れやすい。記載を消さないこと
- 専用スレッドで `RunLoop` を保持する構成は、10のリスク表の「IOBluetoothが特定の
  RunLoopを要求する」への対処と一致している

## 7. 制御接続は1本しか張れない

Sonyのファームウェアは制御用の接続を1つしか受け付けない。スマートフォンの純正アプリや
他のクライアントが繋いでいる間は開けない。3.7の `contended` はこの事情に対応する。

A2DP/HFPで音声が流れている機器に対してRFCOMMチャンネルを追加で開くこと自体は、
L2CAP/RFCOMMの多重化として正常な使い方である。

---

## プローブで先に潰す

実装を進める前に、上の3・4・5がこの環境で起きるかを確かめると手戻りが減る。
確かめたい問いは4つ。

1. `openRFCOMMChannelAsync` の完了コールバックは来るか。来ないなら `Sync` + `isOpen`
   のポーリングへ替える
2. ターミナルから起動したプロセスでRFCOMMは開けるか。開けないなら実機確認は
   `.app` を `open` で起動する手順に固定する
3. `device.isConnected()` が偽のとき、`openConnection()` を挟めば開くか
4. SDPから取れるチャンネル番号は、テスト機でいくつか。定数と一致するか

`sound-connect-pc` に動作する実装があるため、挙動の比較対象として使える。

## 出典

| 内容 | 出所 |
| --- | --- |
| チャンネル番号の実測値、Service UUID | `AndreasOlofsson/mdr-protocol` |
| macOS 26のasync不発、LaunchServices制約 | `jagvaandanzan/sonyxmctl`（README、`patches/macos26-rfcomm.patch`） |
| Syncの戻り値、`openConnection` の先行、SDPの回避 | `timschneeb/GalaxyBudsClient` の `Bluetooth.mm` 内コメント |
| SDPのVentura以降の退行 | Apple Developer Forums thread 722228 |
| v1/v2のUUID | `andreabedini/soundconnectd` `docs/protocol/00-transport.md` |

いずれもコードは取り込んでいない。事実の参照のみである。ライセンス上の扱いは
`THIRD_PARTY_NOTICES.md` を参照。
