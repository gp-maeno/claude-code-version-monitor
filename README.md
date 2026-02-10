# Claude Code Version Monitor for Google Chat

Claude Code（`@anthropic-ai/claude-code`）のバージョンアップを GitHub Actions で自動検知し、Google Chat スペースに日本語で通知します。

## 機能

- 📦 **npm Registry 監視** — 最新バージョンを毎日定時チェック
- 📋 **CHANGELOG 自動取得** — GitHub の CHANGELOG.md からリリースノートを抽出
- 💬 **Google Chat 通知** — Webhook 経由でカード形式のリッチ通知を送信
- 📊 **履歴管理** — バージョン変更を Git コミットとして自動記録
- 🔧 **手動実行対応** — `workflow_dispatch` でいつでも手動チェック可能

## 通知イメージ

カード形式で以下の情報を表示:
- バージョン番号（前バージョン → 新バージョン）
- 変更内容（CHANGELOG から自動抽出）
- CHANGELOG / npm へのリンクボタン

## セットアップ

### 1. Google Chat Webhook の作成

1. 通知先の Google Chat スペースを開く
2. スペース名をクリック → **「アプリとインテグレーション」**
3. **「Webhook を追加」** → 名前を入力（例: `Claude Code 更新通知`）
4. 生成された **Webhook URL をコピー**

### 2. GitHub Secrets の設定

1. このリポジトリの **Settings** → **Secrets and variables** → **Actions**
2. **「New repository secret」** をクリック
3. 以下を追加:

| Name | Value |
|------|-------|
| `GCHAT_WEBHOOK_URL` | Google Chat の Webhook URL |

### 3. 動作確認（手動実行）

1. リポジトリの **Actions** タブを開く
2. 左メニューから **「Claude Code Version Monitor」** を選択
3. **「Run workflow」** → **「Run workflow」** をクリック
4. Google Chat に通知が届けば成功

> 初回実行時は `last-version.txt` に現在のバージョンが記録済みのため、バージョン変更がなければ通知は送信されません。テストしたい場合は `last-version.txt` の内容を古いバージョン（例: `0.0.0`）に書き換えてコミットしてください。

## ファイル構成

```
├── .github/
│   └── workflows/
│       └── check-update.yml   # GitHub Actions ワークフロー
├── scripts/
│   └── check-update.sh        # メインスクリプト
├── last-version.txt            # 最後に検知したバージョン（自動更新）
├── README.md
└── LICENSE
```

## カスタマイズ

### チェック頻度の変更

`.github/workflows/check-update.yml` の cron 式を編集:

```yaml
schedule:
  # 毎日 09:00 JST (00:00 UTC)
  - cron: '0 0 * * *'

  # 6時間ごと
  # - cron: '0 */6 * * *'

  # 平日のみ 09:00 JST
  # - cron: '0 0 * * 1-5'
```

### 通知メッセージの変更

`scripts/check-update.sh` の `send_notification()` 関数内のカードレイアウトを編集してください。

## 技術情報

| 項目 | 値 |
|------|---|
| バージョン取得元 | npm Registry API (`registry.npmjs.org`) |
| 変更内容取得元 | GitHub `anthropics/claude-code` CHANGELOG.md |
| 通知形式 | Google Chat Incoming Webhook（cardsV2） |
| 実行環境 | GitHub Actions（`ubuntu-latest`） |
| バージョン記録 | `last-version.txt`（Git 自動コミット） |

## 注意事項

- Claude Code はほぼ毎日リリースされるため、1日1回のチェックで十分です
- マイナーパッチは CHANGELOG に記載されない場合があります
- npm インストール方式は非推奨化が進行中のため、将来的にバージョン取得方法の見直しが必要になる可能性があります

## ライセンス

MIT
