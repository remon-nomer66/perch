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

- Apple Developer Programに加入し、"Developer ID Application" 証明書を取得する
- `xcrun notarytool store-credentials <プロファイル名>` で資格情報をKeychainへ保存する
- 以下で署名・公証・stapleまで実行される:

  ```sh
  PERCH_SIGN_IDENTITY="Developer ID Application: ..." \
  PERCH_NOTARY_PROFILE=<プロファイル名> \
  tools/package_app.sh release
  ```

- 資格情報が無い間は自己署名のローカルビルドのみ(docs/implementation-plan.md 3.1の段階方針)

## 4. バージョン番号の決定

- リリースの `CFBundleShortVersionString` / `CFBundleVersion` を決める
- タグ `vX.Y.Z` を打てばreleaseビルドが `git describe` とコミット数から自動で埋める。明示するなら `PERCH_VERSION` / `PERCH_BUILD` を指定する
