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
MAX_CHANGES_LENGTH=1500

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
# CHANGELOG から対象バージョンの変更内容を抽出
# ------------------------------------------------------------
fetch_changelog() {
  local version="$1"
  local changelog

  changelog=$(curl -sf "$CHANGELOG_URL" 2>/dev/null) || {
    echo "変更内容を取得できませんでした。"
    return
  }

  # バージョンセクションを抽出
  # パターン: ## x.x.x ... 次の ## まで
  local escaped_version
  escaped_version=$(echo "$version" | sed 's/\./\\./g')

  local changes
  changes=$(echo "$changelog" | sed -n "/^## ${escaped_version}/,/^## [0-9]/p" | sed '1d;$d')

  if [[ -z "$changes" ]]; then
    echo "CHANGELOG に v${version} の記載がありません。"
    return
  fi

  # 長すぎる場合は切り詰め
  if [[ ${#changes} -gt $MAX_CHANGES_LENGTH ]]; then
    changes="${changes:0:$MAX_CHANGES_LENGTH}

... (詳細は CHANGELOG を参照)"
  fi

  echo "$changes"
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
  local now
  now=$(TZ=Asia/Tokyo date '+%Y/%m/%d %H:%M (JST)')

  # バージョン差分テキスト
  local version_text
  if [[ -n "$old_version" ]]; then
    version_text="v${old_version} → v${new_version}"
  else
    version_text="v${new_version} (初回検知)"
  fi

  # 変更内容を Google Chat 形式に変換 & JSON エスケープ
  local formatted_changes
  formatted_changes=$(format_for_chat "$changes")

  # JSON ペイロードを jq で安全に構築
  local payload
  payload=$(jq -n \
    --arg card_id "claude-code-update-${new_version}" \
    --arg version_text "$version_text" \
    --arg version "$new_version" \
    --arg date_text "$now" \
    --arg changes "$formatted_changes" \
    --arg changelog_url "$CHANGELOG_PAGE" \
    --arg npm_url "$NPM_PAGE" \
    '{
      cardsV2: [{
        cardId: $card_id,
        card: {
          header: {
            title: "🔄 Claude Code アップデート",
            subtitle: $version_text,
            imageUrl: "https://avatars.githubusercontent.com/u/76263028",
            imageType: "CIRCLE"
          },
          sections: [
            {
              widgets: [
                {
                  decoratedText: {
                    topLabel: "バージョン",
                    text: ("<b>" + $version + "</b>"),
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
              header: "変更内容",
              collapsible: (($changes | length) > 500),
              uncollapsibleWidgetsCount: 1,
              widgets: [{
                textParagraph: {
                  text: (if $changes == "" then "<i>変更内容を取得できませんでした</i>" else $changes end)
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

  # 送信
  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "$payload" \
    "$GCHAT_WEBHOOK_URL")

  if [[ "$http_code" == "200" ]]; then
    echo "✅ Google Chat 通知送信完了"
  else
    echo "::error::Google Chat 通知エラー: HTTP ${http_code}"
    exit 1
  fi
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

  # 3. 変更内容を取得
  local changes
  changes=$(fetch_changelog "$latest_version")
  echo "   変更内容取得完了 (${#changes} chars)"

  # 4. Google Chat に通知
  send_notification "$latest_version" "$last_version" "$changes"

  # 5. バージョンファイルを更新
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

### 変更内容
\`\`\`
${changes:0:2000}
\`\`\`
EOF
  fi
}

main "$@"
