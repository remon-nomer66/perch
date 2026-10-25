# リリースチェックリスト

コードの外で必要な作業。公開前に上から順に確認する。

## 1. git履歴のPII除去(公開前に必須)

現在のツリーを直しても過去のコミットには残る。履歴側の対処が必要。

- 過去コミットに実名等の個人情報を含むファイル(作業用 `.ai` など)が残存している
- `git filter-repo` またはBFGで履歴を書き換えるか、履歴を持たない新リポジトリとして公開する
- 処理後、全履歴に対して実名・Bluetoothアドレス・ローカルパス・機器の個体名が無いことを確認する(`git log --all --stat`、各コミットへの `git grep`)

## 2. 解析レポート投稿先リポジトリの公開

- 解析レポートのissue投稿先リポジトリが**privateのままだと、アプリからの導線が全ユーザーで404になる**
- publicへ切り替えるか、投稿先を公開リポジトリへ変更してからリリースする

## 3. Developer IDと公証(GitHub Releases配布を始める段階で)

未公証のビルドを配布すると、ダウンロードした利用者には「"Perch" は開いていません / マルウェアが含まれていないことを検証できませんでした」が出る。**macOS 15 以降、右クリック →「開く」による解除は廃止された**ので、公証しない限り利用者はシステム設定から手動で許可するしかない。

### 一度だけの準備

- Apple Developer Programに加入し、**"Developer ID Application"** 証明書を作る(Xcode → Settings → Accounts → Manage Certificates → ＋)。`Apple Development` 証明書は開発用で、配布・公証には使えない
- 資格情報をKeychainへ保存する。app-specific passwordは対話で入力し、**コマンドライン引数にもシェル履歴にも残さない**:

  ```sh
  xcrun notarytool store-credentials <プロファイル名> \
      --apple-id <Apple ID> --team-id <Team ID>
  ```

- 秘密鍵(`.p12`)のエクスポートが要るのは別マシンやCIでビルドするときだけ。同じMacでビルドするならKeychainの鍵をそのまま使う

### 毎回のリリース

```sh
PERCH_SIGN_IDENTITY="Developer ID Application: ... (<Team ID>)" \
PERCH_NOTARY_PROFILE=<プロファイル名> \
tools/package_app.sh release

PERCH_SIGN_IDENTITY="Developer ID Application: ... (<Team ID>)" \
PERCH_NOTARY_PROFILE=<プロファイル名> \
tools/make_dmg.sh
```

**両方に通すこと。** Gatekeeperが判定するのは利用者がダウンロードした `.dmg` なので、`.app` だけ公証しても初回起動の警告は消えない。

### 秘密情報の扱い

- スクリプトが受け取るのは証明書の「名前」とKeychainプロファイルの「名札」だけで、どちらも単体では何もできない。**秘密鍵とApp Store Connectの資格情報はKeychainから出ない**
- `.p12` / `.p8` / `.cer` はリポジトリに入れない(`.gitignore` で予防済み)
- `notarytool` の出力にはApple IDとTeam IDが出る。**ログをそのままdocsやissueへ貼らない**
- 署名に埋め込まれ公開されるのはTeam IDと証明書の登録名(個人登録なら本名)。これは公証済みアプリでは避けられない。本名を出したくない場合は法人(Organization)としての登録が要る

### 検証

```sh
codesign --verify --strict --verbose=2 .build/Perch.app
spctl --assess --type execute -vv .build/Perch.app
spctl --assess --type open --context context:primary-signature -vv .build/Perch.dmg
xcrun stapler validate .build/Perch.dmg
```

- 資格情報が無い間は自己署名のローカルビルドのみ(docs/implementation-plan.md 3.1の段階方針)

## 4. バージョン番号の決定

- リリースの `CFBundleShortVersionString` / `CFBundleVersion` を決める
- タグ `vX.Y.Z` を打てばreleaseビルドが `git describe` とコミット数から自動で埋める。明示するなら `PERCH_VERSION` / `PERCH_BUILD` を指定する
