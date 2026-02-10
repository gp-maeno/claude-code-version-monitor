# Claude Code バージョン監視 GAS セットアップ手順

## 前提条件

- Google Workspace（Business / Enterprise）アカウント
- Google Chat のスペースに Webhook 追加権限があること

---

## STEP 1: Google Chat Webhook の作成

1. 通知先の **Google Chat スペース** を開く
2. スペース名（上部）をクリック → **「アプリとインテグレーション」**
3. **「Webhook を追加」** をクリック
4. 以下を入力:
   - **名前:** `Claude Code 更新通知`
   - **アバターURL（任意）:** `https://avatars.githubusercontent.com/u/76263028`
5. **「保存」** をクリック
6. 表示された **Webhook URL をコピー** して控えておく

> ⚠️ URL は外部に漏らさないよう注意してください

---

## STEP 2: スプレッドシート + GAS の作成

1. [Google スプレッドシート](https://sheets.new) を新規作成
2. 名前を「Claude Code バージョン監視」等に変更
3. メニュー → **拡張機能** → **Apps Script** を開く
4. デフォルトの `Code.gs` の中身を全て削除
5. `main.gs` の内容を全て貼り付けて保存（Ctrl+S）

---

## STEP 3: スクリプトプロパティの設定

1. Apps Script エディタの左メニュー → ⚙️ **プロジェクトの設定**
2. 下部の **「スクリプト プロパティ」** セクション
3. **「スクリプト プロパティを追加」** で以下を設定:

| プロパティ名 | 値 | 必須 |
|------------|---|------|
| `GCHAT_WEBHOOK_URL` | STEP 1 でコピーした URL | ✅ |
| `GITHUB_TOKEN` | GitHub Personal Access Token | 任意 |

### GitHub Token について（任意）

設定すると GitHub API のレート制限が緩和されます（60回/時 → 5,000回/時）。
通常の1日1回チェックでは不要ですが、設定しておくと安心です。

- https://github.com/settings/tokens → **Generate new token (classic)**
- スコープ: `public_repo` のみでOK

---

## STEP 4: 初回セットアップ

1. Apps Script エディタで関数セレクタから **`initialize`** を選択
2. **▶ 実行** をクリック
3. 初回は権限の承認ダイアログが表示される:
   - 「権限を確認」をクリック
   - Google アカウントを選択
   - 「詳細」→「〇〇（安全ではないページ）に移動」
   - 「許可」をクリック
4. 実行ログに以下が表示されれば成功:
   ```
   初期化完了: 現在のバージョン v2.x.xx を記録しました
   ✅ GCHAT_WEBHOOK_URL: 設定済み
   ```

> 初回の `initialize` は通知を送信しません。現在のバージョンを基準点として記録するだけです。

---

## STEP 5: トリガー設定（定期実行）

1. 関数セレクタから **`setupTrigger`** を選択して **▶ 実行**
2. ログに「トリガーを設定しました: 毎日 9:00（JST）に実行」と表示されればOK

### トリガー頻度の変更

- **6時間ごと** にチェックしたい場合: `setupFrequentTrigger` を実行
- **毎日9時** に戻す場合: `setupTrigger` を再実行

---

## STEP 6: 動作テスト

1. 関数セレクタから **`testNotification`** を選択して **▶ 実行**
2. Google Chat スペースにカード形式の通知が届けばOK

### その他のテスト関数

| 関数名 | 用途 |
|-------|------|
| `testNpmApi` | npm API の疎通確認 |
| `testChangelog` | CHANGELOG 取得・パースの確認 |
| `testNotification` | 通知メッセージの送信テスト |

---

## 運用後の確認

### スプレッドシートの確認

- **「バージョン履歴」シート**: 検知したバージョンの履歴
- **「エラーログ」シート**: エラー発生時に自動作成

### トリガーの確認

Apps Script エディタ → 左メニュー ⏰ **「トリガー」** で実行履歴を確認可能

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| 通知が来ない | `testNotification` でテスト。Webhook URL が正しいか確認 |
| 「権限がありません」エラー | `initialize` を再実行して権限を再承認 |
| npm API エラー | `testNpmApi` で確認。一時的な障害の可能性あり |
| CHANGELOG が取得できない | マイナーパッチは CHANGELOG 未記載の場合あり（正常動作） |
| トリガーが動かない | Apps Script のトリガー画面で実行状況を確認 |
