# Claude Code Version Monitor for Google Chat

Claude Code（`@anthropic-ai/claude-code`）のバージョンアップを自動検知し、Google Chat スペースに日本語で通知する Google Apps Script（GAS）です。

## 機能

- 📦 **npm Registry 監視** — `@anthropic-ai/claude-code` の最新バージョンを定期チェック
- 📋 **CHANGELOG 自動取得** — GitHub の CHANGELOG.md からリリースノートを抽出
- 💬 **Google Chat 通知** — Webhook 経由でカード形式のリッチ通知を送信
- 📊 **履歴管理** — スプレッドシートにバージョン履歴を自動記録
- ⚠️ **エラー通知** — 異常発生時にもChat通知 + ログシートに記録

## 通知イメージ

カード形式で以下の情報を表示:
- バージョン番号（前バージョン → 新バージョン）
- 変更内容（CHANGELOG から自動抽出）
- CHANGELOG / npm へのリンクボタン

## セットアップ

詳細な手順は [SETUP.md](./SETUP.md) を参照してください。

### クイックスタート

1. Google Chat スペースで Webhook を作成
2. Google スプレッドシートを作成 → Apps Script を開く
3. `src/main.gs` のコードを貼り付け
4. スクリプトプロパティに `GCHAT_WEBHOOK_URL` を設定
5. `initialize()` を実行（初回の基準バージョン記録）
6. `setupTrigger()` を実行（毎日9時 JST の定期実行設定）

### スクリプトプロパティ

| プロパティ名 | 必須 | 説明 |
|------------|------|------|
| `GCHAT_WEBHOOK_URL` | ✅ | Google Chat Webhook URL |
| `GITHUB_TOKEN` | 任意 | GitHub PAT（API レート制限緩和用） |

## ファイル構成

```
├── README.md          # このファイル
├── SETUP.md           # 詳細セットアップ手順
└── src/
    └── main.gs        # GAS メインスクリプト
```

## カスタマイズ

### チェック頻度の変更

- 毎日1回（デフォルト）: `setupTrigger()` を実行
- 6時間ごと: `setupFrequentTrigger()` を実行

### テスト用関数

| 関数名 | 用途 |
|-------|------|
| `testNpmApi()` | npm API 疎通確認 |
| `testChangelog()` | CHANGELOG 取得・パース確認 |
| `testNotification()` | 通知メッセージ送信テスト |

## 技術情報

- **バージョン取得元**: npm Registry API (`registry.npmjs.org`)
- **変更内容取得元**: GitHub CHANGELOG.md → GitHub Releases API（フォールバック）
- **通知形式**: Google Chat Incoming Webhook（cardsV2）
- **実行環境**: Google Apps Script（時間ベーストリガー）

## 注意事項

- Claude Code はほぼ毎日リリースされるため、1日1回のチェックで十分です
- マイナーパッチは CHANGELOG に記載されない場合があります
- npm インストール方式は非推奨化が進行中のため、将来的にバージョン取得方法の見直しが必要になる可能性があります

## ライセンス

MIT
