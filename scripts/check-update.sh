#!/usr/bin/env bash
# ============================================================
# Claude Code バージョンアップ検知 → Google Chat 通知スクリプト
# GitHub Actions から実行される
# ============================================================
set -euo pipefail

# ------------------------------------------------------------
# 定数
# ------------------------------------------------------------
NPM_PACKAGE="@anthropic-ai/claude-code"
NPM_REGISTRY_URL="https://registry.npmjs.org/@anthropic-ai%2fclaude-code"
CHANGELOG_URL="https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
CHANGELOG_PAGE="https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
NPM_PAGE="https://www.npmjs.com/package/@anthropic-ai/claude-code"
VERSION_FILE="last-version.txt"
MAX_CHANGES_LENGTH=4000
GEMINI_API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

# ------------------------------------------------------------
# npm から最新バージョンを取得
# ------------------------------------------------------------
fetch_latest_version() {
  local response
  response=$(curl -sf "${NPM_REGISTRY_URL}/latest" 2>/dev/null) || {
    echo "::error::npm レジストリからバージョン情報を取得できませんでした"
    exit 1
  }

  echo "$response" | jq -r '.version'
}

# ------------------------------------------------------------
# 前回バージョンを取得
# ------------------------------------------------------------
get_last_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE" | tr -d '[:space:]'
  else
    echo ""
  fi
}

# ------------------------------------------------------------
# CHANGELOG から last_version より新しいバージョンの変更内容を抽出
# 引数: $1=latest_version, $2=last_version（空の場合は latest のみ）
# ------------------------------------------------------------
fetch_changelog() {
  local latest_version="$1"
  local last_version="${2:-}"
  local changelog

  changelog=$(curl -sf "$CHANGELOG_URL" 2>/dev/null) || {
    echo "::warning::CHANGELOG の取得に失敗しました。次回実行時に再取得します。"
    return 1
  }

  local changes

  if [[ -n "$last_version" ]]; then
    # last_version のセクション手前までを抽出（last_version 自身は含めない）
    local escaped_last
    escaped_last=$(echo "$last_version" | sed 's/\./\\./g')
    # 先頭から ## {last_version} の直前行までを取得し、その中の ## セクションのみ残す
    changes=$(echo "$changelog" | sed -n "1,/^## ${escaped_last}/p" | sed '$d' | sed -n '/^## [0-9]/,$p')
  else
    # 初回: latest_version のセクションのみ抽出
    local escaped_latest
    escaped_latest=$(echo "$latest_version" | sed 's/\./\\./g')
    changes=$(echo "$changelog" | sed -n "/^## ${escaped_latest}/,/^## [0-9]/p" | sed '$d')
  fi

  if [[ -z "$changes" ]]; then
    echo "::notice::CHANGELOG に v${latest_version} の記載がまだありません。次回実行時に再取得します。"
    return 1
  fi

  # 長すぎる場合は切り詰め（バージョン境界で切る）
  if [[ ${#changes} -gt $MAX_CHANGES_LENGTH ]]; then
    changes="${changes:0:$MAX_CHANGES_LENGTH}

... (詳細は CHANGELOG を参照)"
  fi

  echo "$changes"
}

# ------------------------------------------------------------
# Gemini API で変更内容を日本語要約
# ------------------------------------------------------------
summarize_with_gemini() {
  local changes="$1"

  # API キーが未設定の場合はスキップ
  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "（Gemini API キーが未設定のため要約をスキップしました）"
    return
  fi

  # プロンプト構築
  local prompt
  prompt="あなたはソフトウェアのリリースノート翻訳者です。
以下は Claude Code の CHANGELOG（英語）です。
バージョンごとに日本語で簡潔に要約してください。

出力フォーマット（厳守）:

━━━━━━━━━━━━━━━
📦 vX.X.X
━━━━━━━━━━━━━━━

【✨ Added】
• 項目1
• 項目2

【💡 Improved】
• 項目1

【🐛 Fixed】
• 項目1
• 項目2

ルール:
- 入力には \"## x.x.x\" 形式のバージョン見出しが含まれる
- バージョンが1つだけの場合は ━ 線とバージョン見出し（📦 vX.X.X）を省略し、カテゴリ見出しから始める
- バージョンが複数の場合は上記フォーマットで出力する（━ 線は半角15文字分）
- カテゴリ順: ✨ Added → 💡 Improved → 🐛 Fixed → その他（該当なしは省略）
- カテゴリ見出しの前に空行を1つ入れること
- [VSCode] 等のプレフィックスがある項目はカテゴリ名に含める（例: 【✨ [VSCode] Added】）
- 各項目は \"• \" で始め、1行で簡潔に
- 技術用語はそのまま英語で残してOK
- Added は全項目を漏れなく出力。それ以外のカテゴリは最大5項目まで（省略時は「他 N 件」と末尾に記載）
- 前置きや挨拶は不要。フォーマットのみ出力

CHANGELOG:
${changes}"

  # Gemini API 呼び出し
  local response
  response=$(curl -sf -X POST \
    "${GEMINI_API_URL}?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg prompt "$prompt" '{
      contents: [{ parts: [{ text: $prompt }] }],
      generationConfig: {
        temperature: 0.3,
        maxOutputTokens: 4096
      }
    }')" 2>/dev/null) || {
    echo "（Gemini API の呼び出しに失敗しました）"
    return
  }

  # レスポンスからテキストを抽出
  local summary
  summary=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)

  if [[ -z "$summary" ]]; then
    # エラー詳細をログに出力
    local error_msg
    error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$error_msg" ]]; then
      echo "::warning::Gemini API エラー: ${error_msg}"
    fi
    echo "（要約の生成に失敗しました）"
    return
  fi

  echo "$summary"
}

# ------------------------------------------------------------
# Markdown を Google Chat 形式に変換
# ------------------------------------------------------------
format_for_chat() {
  local text="$1"

  echo "$text" \
    | sed 's/^### \(.*\)$/<b>\1<\/b>/g' \
    | sed 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' \
    | sed 's/^[-*] /• /g' \
    | sed 's/`\([^`]*\)`/<code>\1<\/code>/g'
}

# ------------------------------------------------------------
# Google Chat にカードメッセージを送信
# ------------------------------------------------------------
send_notification() {
  local new_version="$1"
  local old_version="$2"
  local changes="$3"
  local summary="$4"
  local now
  now=$(TZ=Asia/Tokyo date '+%Y/%m/%d %H:%M (JST)')

  # バージョン差分テキスト
  local version_text
  if [[ -n "$old_version" ]]; then
    version_text="v${old_version} → v${new_version}"
  else
    version_text="v${new_version} (初回検知)"
  fi

  # CHANGELOG 内のバージョン数をカウント
  local version_count
  version_count=$(echo "$changes" | grep -c '^## [0-9]' || true)
  # バージョン表示テキスト（複数バージョンの場合は件数を付加）
  local version_display
  if [[ "$version_count" -gt 1 ]]; then
    version_display="<b>${new_version}</b>（${version_count} バージョン分）"
  else
    version_display="<b>${new_version}</b>"
  fi

  # 要約を Google Chat 形式に変換
  local formatted_summary
  formatted_summary=$(format_for_chat "$summary")

  # JSON ペイロードを jq で安全に構築
  local payload
  payload=$(jq -n \
    --arg card_id "claude-code-update-${new_version}" \
    --arg version_text "$version_text" \
    --arg version "$version_display" \
    --arg date_text "$now" \
    --arg summary "$formatted_summary" \
    --arg changelog_url "$CHANGELOG_PAGE" \
    --arg npm_url "$NPM_PAGE" \
    '{
      cardsV2: [{
        cardId: $card_id,
        card: {
          header: {
            title: "🔄 Claude Code アップデート",
            subtitle: $version_text,
            imageUrl: "https://cdn.stickermule.com/artworks/be75b541-e429-4b61-a058-6a04bc35f712/large.png",
            imageType: "CIRCLE"
          },
          sections: [
            {
              widgets: [
                {
                  decoratedText: {
                    topLabel: "バージョン",
                    text: $version,
                    startIcon: { knownIcon: "BOOKMARK" }
                  }
                },
                {
                  decoratedText: {
                    topLabel: "検出日時",
                    text: $date_text,
                    startIcon: { knownIcon: "CLOCK" }
                  }
                }
              ]
            },
            {
              widgets: [{
                textParagraph: {
                  text: (if $summary == "" then "<i>変更内容を取得できませんでした</i>" else $summary end)
                }
              }]
            },
            {
              widgets: [{
                buttonList: {
                  buttons: [
                    {
                      text: "📋 CHANGELOG",
                      onClick: { openLink: { url: $changelog_url } }
                    },
                    {
                      text: "📦 npm",
                      onClick: { openLink: { url: $npm_url } }
                    }
                  ]
                }
              }]
            }
          ]
        }
      }]
    }')

  # Webhook URL の確認
  if [[ -z "${GCHAT_WEBHOOK_URL:-}" ]]; then
    echo "::error::GCHAT_WEBHOOK_URL が設定されていません"
    exit 1
  fi

  # スレッド返信の設定
  local webhook_url="$GCHAT_WEBHOOK_URL"
  if [[ -n "${GCHAT_THREAD_NAME:-}" ]]; then
    # 既存スレッドへの返信モード
    webhook_url="${webhook_url}&messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"
    # ペイロードに thread.name を追加
    payload=$(echo "$payload" | jq --arg thread_name "$GCHAT_THREAD_NAME" '.thread = { name: $thread_name }')
    echo "   スレッド返信モード: ${GCHAT_THREAD_NAME}"
  fi

  # 送信
  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "$payload" \
    "$webhook_url")

  if [[ "$http_code" == "200" ]]; then
    echo "✅ Google Chat 通知送信完了"
  else
    echo "::error::Google Chat 通知エラー: HTTP ${http_code}"
    exit 1
  fi
}

# ------------------------------------------------------------
# .env ファイルの読み込み（ローカル実行用）
# ------------------------------------------------------------
load_env() {
  local script_dir
  script_dir=$(cd "$(dirname "$0")/.." && pwd)
  local env_file="${script_dir}/.env"

  if [[ -f "$env_file" ]]; then
    # コメント行と空行を除外し、export して読み込む
    while IFS= read -r line; do
      # 空行とコメント行をスキップ
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      export "$line"
    done < "$env_file"
    echo "   .env ファイルを読み込みました: ${env_file}"
  fi
}

# ------------------------------------------------------------
# テストモード: 指定バージョン範囲で通知をテスト送信
# usage: check-update.sh --test <old_version> <new_version>
# バージョンファイルは更新しない
# ------------------------------------------------------------
run_test() {
  local old_version="$1"
  local new_version="$2"

  echo "🧪 テストモード: v${old_version} → v${new_version}"
  echo "   ※ バージョンファイルは更新されません"

  # .env から環境変数を読み込む
  load_env

  # 変更内容を取得
  local changes
  if ! changes=$(fetch_changelog "$new_version" "$old_version"); then
    echo "❌ CHANGELOG の取得に失敗しました"
    exit 1
  fi
  echo "   変更内容取得完了 (${#changes} chars)"

  # Gemini で日本語要約を生成
  echo "🤖 日本語要約を生成中..."
  local summary
  summary=$(summarize_with_gemini "$changes")
  echo "   要約生成完了 (${#summary} chars)"

  # Google Chat に通知
  send_notification "$new_version" "$old_version" "$changes" "$summary"
}

# ------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------
main() {
  echo "📦 Claude Code バージョンチェック開始..."

  # 1. 最新バージョン取得
  local latest_version
  latest_version=$(fetch_latest_version)
  echo "   最新バージョン: v${latest_version}"

  # 2. 前回バージョンと比較
  local last_version
  last_version=$(get_last_version)
  echo "   前回バージョン: ${last_version:-"(初回)"}"

  if [[ "$last_version" == "$latest_version" ]]; then
    echo "✅ バージョンに変更なし。終了します。"
    exit 0
  fi

  echo "🆕 新バージョン検知: v${last_version:-"?"} → v${latest_version}"

  # 3. 変更内容を取得（CHANGELOG 未更新の場合は次回に回す）
  local changes
  if ! changes=$(fetch_changelog "$latest_version" "$last_version"); then
    echo "⏭️  CHANGELOG 未取得のためスキップ。次回実行時に再チェックします。"
    exit 0
  fi
  echo "   変更内容取得完了 (${#changes} chars)"

  # 4. Gemini で日本語要約を生成
  echo "🤖 日本語要約を生成中..."
  local summary
  summary=$(summarize_with_gemini "$changes")
  echo "   要約生成完了 (${#summary} chars)"

  # 5. Google Chat に通知
  send_notification "$latest_version" "$last_version" "$changes" "$summary"

  # 6. バージョンファイルを更新
  echo -n "$latest_version" > "$VERSION_FILE"
  echo "📝 バージョンファイル更新: v${latest_version}"

  # GitHub Actions のサマリー出力
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat >> "$GITHUB_STEP_SUMMARY" << EOF
## 🔄 Claude Code アップデート検知

| 項目 | 値 |
|------|---|
| **前バージョン** | v${last_version:-"(初回)"} |
| **新バージョン** | v${latest_version} |
| **検出日時** | $(TZ=Asia/Tokyo date '+%Y/%m/%d %H:%M JST') |

### 要約（日本語）
${summary}

### 変更内容（CHANGELOG）
\`\`\`
${changes:0:2000}
\`\`\`
EOF
  fi
}

# エントリーポイント: --test モードの判定
if [[ "${1:-}" == "--test" ]]; then
  if [[ $# -lt 3 ]]; then
    echo "usage: $0 --test <old_version> <new_version>"
    echo "例:    $0 --test 2.1.41 2.1.44"
    exit 1
  fi
  run_test "$2" "$3"
else
  main "$@"
fi
