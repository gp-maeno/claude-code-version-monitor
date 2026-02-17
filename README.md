# Claude Code Version Monitor for Google Chat

Claude Code（`@anthropic-ai/claude-code`）のバージョンアップを GitHub Actions で自動検知し、Google Chat スペースに日本語で通知します。

## 機能

- 📦 **npm Registry 監視** — 最新バージョンを1時間ごとにチェック（JST 7:00〜20:00）
- 📋 **CHANGELOG 自動取得** — GitHub の CHANGELOG.md からリリースノートを抽出
- 🤖 **日本語要約** — Gemini API で変更内容を日本語に自動要約
- 💬 **Google Chat 通知** — Webhook 経由でカード形式のリッチ通知を送信
- 🧵 **スレッド返信** — 指定したコメントのスレッドに通知を集約
- 📊 **履歴管理** — バージョン変更を Git コミットとして自動記録
- 🔧 **手動実行対応** — `workflow_dispatch` でいつでも手動チェック可能

## 通知イメージ

カード形式で以下の情報を表示:
- バージョン番号（前バージョン → 新バージョン）
- 検出日時（JST）
- 変更内容（CHANGELOG を Gemini で日本語要約）
- CHANGELOG / npm へのリンクボタン

## セットアップ

### 1. Google Chat Webhook の作成

1. 通知先の Google Chat スペースを開く
2. スペース名をクリック → **「アプリとインテグレーション」**
3. **「Webhook を追加」** → 名前を入力（例: `Claude Code 更新通知`）
4. 生成された **Webhook URL をコピー**

### 2. スレッド返信先の取得（任意）

特定のコメントのスレッドに通知を集約したい場合:

1. Google Chat で対象コメントにカーソルを合わせる
2. **「︙」→「リンクをコピー」**
3. URL 形式: `https://chat.google.com/room/{spaceId}/{threadId}/{messageId}`
4. これを `spaces/{spaceId}/threads/{threadId}` の形式に変換

例: `https://chat.google.com/room/AAAAxxxxx/BBBByyyyy/BBBByyyyy`
→ `spaces/AAAAxxxxx/threads/BBBByyyyy`

### 3. Gemini API キーの取得

1. https://aistudio.google.com/apikey にアクセス（Google アカウントでログイン）
2. **「API キーを作成」** をクリック
3. 生成されたキー（`AIzaSy...`）をコピー

> 無料枠で利用可能です。クレジットカード不要。

### 4. GitHub Secrets の設定

リポジトリの **Settings** → **Secrets and variables** → **Actions** → **「New repository secret」** で以下を追加:

| Name | Value | 必須 |
|------|-------|:----:|
| `GCHAT_WEBHOOK_URL` | Google Chat の Webhook URL | ✅ |
| `GEMINI_API_KEY` | Gemini API キー（`AIzaSy...`） | ✅ |
| `GCHAT_THREAD_NAME` | スレッド名（`spaces/xxx/threads/yyy`） | 任意 |

> `GCHAT_THREAD_NAME` を省略した場合、スペースに直接投稿されます。

### 5. 動作確認（手動実行）

1. リポジトリの **Actions** タブを開く
2. 左メニューから **「Claude Code Version Monitor」** を選択
3. **「Run workflow」** → **「Run workflow」** をクリック
4. Google Chat に通知が届けば成功

## ローカルでのテスト実行

実際の Google Chat Webhook に通知を送って動作確認できます。バージョンファイルは更新されないため、繰り返しテスト可能です。

### 1. 環境変数の設定

```bash
cp .env.example .env
```

`.env` を編集して実際の値を入力:

```
GCHAT_WEBHOOK_URL=https://chat.googleapis.com/v1/spaces/XXXXX/messages?key=XXXXX&token=XXXXX
GEMINI_API_KEY=AIzaSy...
```

> `.env` は `.gitignore` に含まれているため Git にコミットされません。

### 2. テスト通知の送信

```bash
# 単一バージョンの通知テスト（2.1.43 → 2.1.44）
bash scripts/check-update.sh --test 2.1.43 2.1.44

# 複数バージョンをまとめた通知テスト（2.1.41 → 2.1.44）
bash scripts/check-update.sh --test 2.1.41 2.1.44
```

`--test` モードでは:
- 指定したバージョン範囲の CHANGELOG を取得
- Gemini で日本語要約を生成
- Google Chat に通知を送信
- `last-version.txt` は**更新しない**（何度でもテスト可能）

## ファイル構成

```
├── .github/
│   └── workflows/
│       └── check-update.yml   # GitHub Actions ワークフロー
├── scripts/
│   └── check-update.sh        # メインスクリプト（--test モード対応）
├── .env.example                # 環境変数テンプレート
├── .env                        # 環境変数（※ .gitignore 対象）
├── last-version.txt            # 最後に検知したバージョン（自動更新）
├── README.md
└── LICENSE
```

## カスタマイズ

### チェック頻度の変更

`.github/workflows/check-update.yml` の cron 式を編集:

```yaml
schedule:
  # JST 07:00〜20:00 に1時間ごと（現在の設定）
  - cron: '0 22-23,0-11 * * *'

  # 毎日 09:00 JST のみ
  # - cron: '0 0 * * *'

  # 平日のみ JST 09:00〜19:00
  # - cron: '0 0-10 * * 1-5'
```

### 要約モデルの変更

`scripts/check-update.sh` の `GEMINI_API_URL` を編集:

```bash
# Gemini 2.5 Flash（デフォルト・高速・無料枠あり）
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

# Gemini 2.5 Flash Lite（より軽量）
# GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent"
```

### 通知メッセージの変更

`scripts/check-update.sh` の `send_notification()` 関数内のカードレイアウトを編集してください。

## 技術情報

| 項目 | 値 |
|------|---|
| バージョン取得元 | npm Registry API (`registry.npmjs.org`) |
| 変更内容取得元 | GitHub `anthropics/claude-code` CHANGELOG.md |
| 日本語要約 | Gemini 2.5 Flash API（無料枠） |
| 通知形式 | Google Chat Incoming Webhook（cardsV2） |
| スレッド返信 | `messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD` |
| 実行スケジュール | JST 07:00〜20:00（1時間ごと・計14回/日） |
| 実行環境 | GitHub Actions（`ubuntu-latest`） |
| バージョン記録 | `last-version.txt`（Git 自動コミット） |

## 注意事項

- Claude Code はほぼ毎日リリースされます
- マイナーパッチは CHANGELOG に記載されない場合があります
- npm インストール方式は非推奨化が進行中のため、将来的にバージョン取得方法の見直しが必要になる可能性があります
- Gemini API の無料枠には日次のリクエスト制限があります（1日14回の利用では問題になりません）

## ライセンス

MIT
