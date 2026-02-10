/**
 * ============================================================
 * Claude Code バージョンアップ監視 → Google Chat 通知スクリプト
 * ============================================================
 *
 * 【セットアップ手順】
 * 1. Google スプレッドシートを新規作成
 * 2. 拡張機能 → Apps Script を開く
 * 3. このコードを貼り付け
 * 4. スクリプトプロパティに以下を設定:
 *    - GCHAT_WEBHOOK_URL: Google Chat の Webhook URL
 *    - GITHUB_TOKEN: (任意) GitHub Personal Access Token
 * 5. 初回は手動で `initialize()` を実行
 * 6. `setupTrigger()` を実行してトリガー設定
 */

// ============================================================
// 定数
// ============================================================

const CONFIG = {
  NPM_PACKAGE: '@anthropic-ai/claude-code',
  NPM_REGISTRY_URL: 'https://registry.npmjs.org/@anthropic-ai%2fclaude-code',
  CHANGELOG_URL: 'https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md',
  GITHUB_RELEASES_URL: 'https://api.github.com/repos/anthropics/claude-code/releases',
  SHEET_NAME: 'バージョン履歴',
  MAX_CHANGELOG_LENGTH: 2000,
  NPM_PAGE_URL: 'https://www.npmjs.com/package/@anthropic-ai/claude-code',
  GITHUB_CHANGELOG_PAGE: 'https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md',
};

// ============================================================
// メイン処理
// ============================================================

/**
 * メイン: バージョンチェック → 差分検知 → 通知
 * トリガーから定期実行される
 */
function checkClaudeCodeUpdate() {
  try {
    // 1. npm から最新バージョン情報を取得
    const npmInfo = fetchLatestVersionFromNpm_();
    if (!npmInfo) {
      logError_('npm レジストリからバージョン情報を取得できませんでした');
      return;
    }

    Logger.log(`最新バージョン: ${npmInfo.version} (公開日: ${npmInfo.publishedAt})`);

    // 2. 前回記録したバージョンと比較
    const lastVersion = getLastKnownVersion_();
    Logger.log(`前回バージョン: ${lastVersion || '(初回)'}`);

    if (lastVersion === npmInfo.version) {
      Logger.log('バージョンに変更なし。終了します。');
      return;
    }

    // 3. 変更内容を取得
    const changes = fetchChanges_(npmInfo.version);

    // 4. Google Chat に通知
    sendNotification_(npmInfo, changes, lastVersion);

    // 5. スプレッドシートに記録
    recordVersion_(npmInfo.version, npmInfo.publishedAt, changes.summary);

    Logger.log(`通知完了: v${lastVersion || '(初回)'} → v${npmInfo.version}`);

  } catch (e) {
    logError_(`チェック処理でエラー: ${e.message}\n${e.stack}`);
    // エラー時もChat通知（オプション）
    try {
      sendErrorNotification_(e.message);
    } catch (_) {
      // エラー通知自体が失敗した場合は無視
    }
  }
}

// ============================================================
// npm Registry API
// ============================================================

/**
 * npm レジストリから最新バージョン情報を取得
 * @returns {{ version: string, publishedAt: string } | null}
 */
function fetchLatestVersionFromNpm_() {
  // dist-tags を含む軽量情報を取得
  const url = CONFIG.NPM_REGISTRY_URL + '/latest';

  const response = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    headers: { 'Accept': 'application/json' },
  });

  if (response.getResponseCode() !== 200) {
    Logger.log(`npm API エラー: ${response.getResponseCode()} ${response.getContentText().substring(0, 200)}`);
    return null;
  }

  const data = JSON.parse(response.getContentText());

  // 公開日時を取得するため、追加でメタデータを取得
  let publishedAt = '';
  try {
    publishedAt = fetchPublishDate_(data.version);
  } catch (e) {
    Logger.log(`公開日取得スキップ: ${e.message}`);
  }

  return {
    version: data.version,
    publishedAt: publishedAt,
  };
}

/**
 * 特定バージョンの公開日時を取得
 * フルメタデータは重いので、Abbreviated + Accept ヘッダーで軽量取得
 * @param {string} version
 * @returns {string} ISO 8601 日時文字列
 */
function fetchPublishDate_(version) {
  const url = CONFIG.NPM_REGISTRY_URL + '/' + version;
  const response = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    headers: { 'Accept': 'application/json' },
  });

  if (response.getResponseCode() !== 200) return '';

  // バージョン個別エンドポイントには直接的な公開日がないため
  // time フィールドがあればそれを使う
  // なければ空文字を返す
  try {
    const data = JSON.parse(response.getContentText());
    // npm の modified time を利用
    if (data._time) return data._time;
    return '';
  } catch (e) {
    return '';
  }
}

// ============================================================
// CHANGELOG 取得・パース
// ============================================================

/**
 * 変更内容を取得（CHANGELOG → GitHub Releases の順にフォールバック）
 * @param {string} version
 * @returns {{ raw: string, summary: string, source: string }}
 */
function fetchChanges_(version) {
  // 方法1: CHANGELOG.md から抽出
  try {
    const changelog = fetchChangelog_();
    const extracted = extractVersionChanges_(changelog, version);
    if (extracted) {
      return {
        raw: extracted,
        summary: truncateText_(extracted, CONFIG.MAX_CHANGELOG_LENGTH),
        source: 'CHANGELOG.md',
      };
    }
  } catch (e) {
    Logger.log(`CHANGELOG 取得失敗: ${e.message}`);
  }

  // 方法2: GitHub Releases API から取得
  try {
    const releaseNote = fetchGitHubRelease_(version);
    if (releaseNote) {
      return {
        raw: releaseNote,
        summary: truncateText_(releaseNote, CONFIG.MAX_CHANGELOG_LENGTH),
        source: 'GitHub Releases',
      };
    }
  } catch (e) {
    Logger.log(`GitHub Releases 取得失敗: ${e.message}`);
  }

  // フォールバック
  return {
    raw: '',
    summary: '変更内容を自動取得できませんでした。CHANGELOG を確認してください。',
    source: 'none',
  };
}

/**
 * GitHub から CHANGELOG.md を取得
 * @returns {string}
 */
function fetchChangelog_() {
  const headers = {};
  const token = getGitHubToken_();
  if (token) {
    headers['Authorization'] = `token ${token}`;
  }

  const response = UrlFetchApp.fetch(CONFIG.CHANGELOG_URL, {
    muteHttpExceptions: true,
    headers: headers,
  });

  if (response.getResponseCode() !== 200) {
    throw new Error(`CHANGELOG 取得エラー: HTTP ${response.getResponseCode()}`);
  }

  return response.getContentText();
}

/**
 * CHANGELOG.md から対象バージョンのセクションを抽出
 * @param {string} changelog
 * @param {string} version
 * @returns {string | null}
 */
function extractVersionChanges_(changelog, version) {
  const escapedVersion = version.replace(/\./g, '\\.');

  // パターン: ## x.x.x ... 次の ## まで
  const regex = new RegExp(
    `##\\s+${escapedVersion}[^\\n]*\\n([\\s\\S]*?)(?=\\n##\\s+\\d+\\.\\d+\\.\\d+|$)`,
    'i'
  );
  const match = changelog.match(regex);

  if (!match || !match[1].trim()) return null;

  return match[1].trim();
}

/**
 * GitHub Releases API から対象バージョンのリリースノートを取得
 * @param {string} version
 * @returns {string | null}
 */
function fetchGitHubRelease_(version) {
  const headers = {
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'Claude-Code-Version-Monitor-GAS',
  };
  const token = getGitHubToken_();
  if (token) {
    headers['Authorization'] = `token ${token}`;
  }

  // tag 名のパターンを複数試行
  const tagCandidates = [`v${version}`, version, `${version}`];

  for (const tag of tagCandidates) {
    const url = `${CONFIG.GITHUB_RELEASES_URL}/tags/${tag}`;
    const response = UrlFetchApp.fetch(url, {
      muteHttpExceptions: true,
      headers: headers,
    });

    if (response.getResponseCode() === 200) {
      const data = JSON.parse(response.getContentText());
      return data.body || null;
    }
  }

  // 最新リリースをフォールバック確認
  const url = `${CONFIG.GITHUB_RELEASES_URL}/latest`;
  const response = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    headers: headers,
  });

  if (response.getResponseCode() === 200) {
    const data = JSON.parse(response.getContentText());
    if (data.tag_name && (data.tag_name === `v${version}` || data.tag_name === version)) {
      return data.body || null;
    }
  }

  return null;
}

// ============================================================
// Google Chat 通知
// ============================================================

/**
 * Google Chat にバージョンアップ通知を送信
 * @param {{ version: string, publishedAt: string }} npmInfo
 * @param {{ summary: string, source: string }} changes
 * @param {string | null} previousVersion
 */
function sendNotification_(npmInfo, changes, previousVersion) {
  const webhookUrl = getWebhookUrl_();

  // 変更内容を Google Chat 向けにフォーマット
  const formattedChanges = formatChangesForChat_(changes.summary);

  // バージョン差分テキスト
  const versionText = previousVersion
    ? `v${previousVersion} → v${npmInfo.version}`
    : `v${npmInfo.version} (初回検知)`;

  // 公開日テキスト
  const dateText = npmInfo.publishedAt
    ? formatDate_(new Date(npmInfo.publishedAt))
    : formatDate_(new Date());

  const payload = {
    cardsV2: [{
      cardId: `claude-code-update-${npmInfo.version}`,
      card: {
        header: {
          title: '🔄 Claude Code アップデート',
          subtitle: versionText,
          imageUrl: 'https://avatars.githubusercontent.com/u/76263028',
          imageType: 'CIRCLE',
        },
        sections: [
          // 基本情報セクション
          {
            widgets: [{
              decoratedText: {
                topLabel: 'バージョン',
                text: `<b>${npmInfo.version}</b>`,
                startIcon: { knownIcon: 'BOOKMARK' },
              }
            }, {
              decoratedText: {
                topLabel: '検出日時',
                text: dateText,
                startIcon: { knownIcon: 'CLOCK' },
              }
            }]
          },
          // 変更内容セクション
          {
            header: '変更内容',
            collapsible: formattedChanges.length > 500,
            uncollapsibleWidgetsCount: 1,
            widgets: [{
              textParagraph: {
                text: formattedChanges || '<i>変更内容を取得できませんでした</i>',
              }
            }]
          },
          // リンクセクション
          {
            widgets: [{
              buttonList: {
                buttons: [
                  {
                    text: '📋 CHANGELOG',
                    onClick: { openLink: { url: CONFIG.GITHUB_CHANGELOG_PAGE } },
                  },
                  {
                    text: '📦 npm',
                    onClick: { openLink: { url: CONFIG.NPM_PAGE_URL } },
                  },
                ]
              }
            }]
          }
        ]
      }
    }]
  };

  const response = UrlFetchApp.fetch(webhookUrl, {
    method: 'post',
    contentType: 'application/json; charset=UTF-8',
    payload: JSON.stringify(payload),
    muteHttpExceptions: true,
  });

  if (response.getResponseCode() !== 200) {
    throw new Error(`Google Chat 通知エラー: HTTP ${response.getResponseCode()} - ${response.getContentText().substring(0, 200)}`);
  }

  Logger.log('Google Chat 通知送信完了');
}

/**
 * エラー通知を送信
 * @param {string} errorMessage
 */
function sendErrorNotification_(errorMessage) {
  const webhookUrl = getWebhookUrl_();
  if (!webhookUrl) return;

  const payload = {
    text: `⚠️ *Claude Code バージョン監視エラー*\n\n${errorMessage}\n\n_${formatDate_(new Date())}_`,
  };

  UrlFetchApp.fetch(webhookUrl, {
    method: 'post',
    contentType: 'application/json; charset=UTF-8',
    payload: JSON.stringify(payload),
    muteHttpExceptions: true,
  });
}

// ============================================================
// フォーマッター
// ============================================================

/**
 * Markdown 形式の変更内容を Google Chat 形式に変換
 * @param {string} text
 * @returns {string}
 */
function formatChangesForChat_(text) {
  if (!text) return '';

  let formatted = text
    // ### 見出し → 太字 + 改行
    .replace(/^###\s+(.+)$/gm, '\n<b>$1</b>')
    // ** 太字 ** → <b>
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    // - リスト → • 記号
    .replace(/^[-*]\s+/gm, '• ')
    // ` コード ` → <code>（Google Chat はfont タグで代替）
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    // 連続改行を整理
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return formatted;
}

/**
 * テキストを指定長に切り詰め
 * @param {string} text
 * @param {number} maxLength
 * @returns {string}
 */
function truncateText_(text, maxLength) {
  if (!text || text.length <= maxLength) return text;
  return text.substring(0, maxLength) + '\n\n<i>... 詳細は CHANGELOG を参照</i>';
}

/**
 * 日付をフォーマット (JST)
 * @param {Date} date
 * @returns {string}
 */
function formatDate_(date) {
  return Utilities.formatDate(date, 'Asia/Tokyo', 'yyyy/MM/dd HH:mm (JST)');
}

// ============================================================
// スプレッドシート操作
// ============================================================

/**
 * バージョン履歴シートを取得（なければ作成）
 * @returns {GoogleAppsScript.Spreadsheet.Sheet}
 */
function getOrCreateSheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = ss.getSheetByName(CONFIG.SHEET_NAME);

  if (!sheet) {
    sheet = ss.insertSheet(CONFIG.SHEET_NAME);
    // ヘッダー行を作成
    sheet.getRange(1, 1, 1, 5).setValues([[
      'バージョン', '検出日時', '公開日時', '通知済み', '変更概要'
    ]]);
    sheet.getRange(1, 1, 1, 5)
      .setFontWeight('bold')
      .setBackground('#4285F4')
      .setFontColor('#FFFFFF');
    sheet.setFrozenRows(1);

    // 列幅調整
    sheet.setColumnWidth(1, 120);  // バージョン
    sheet.setColumnWidth(2, 180);  // 検出日時
    sheet.setColumnWidth(3, 180);  // 公開日時
    sheet.setColumnWidth(4, 80);   // 通知済み
    sheet.setColumnWidth(5, 500);  // 変更概要
  }

  return sheet;
}

/**
 * 最後に記録したバージョンを取得
 * @returns {string | null}
 */
function getLastKnownVersion_() {
  const sheet = getOrCreateSheet_();
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return null;
  return String(sheet.getRange(lastRow, 1).getValue());
}

/**
 * 新しいバージョンを記録
 * @param {string} version
 * @param {string} publishedAt
 * @param {string} summary
 */
function recordVersion_(version, publishedAt, summary) {
  const sheet = getOrCreateSheet_();
  const now = new Date();
  const publishDate = publishedAt ? new Date(publishedAt) : '';

  sheet.appendRow([
    version,
    now,
    publishDate,
    true,
    summary.substring(0, 500),  // セルサイズ制限対策
  ]);

  Logger.log(`バージョン記録完了: ${version}`);
}

// ============================================================
// プロパティ取得ヘルパー
// ============================================================

/**
 * Google Chat Webhook URL を取得
 * @returns {string}
 */
function getWebhookUrl_() {
  const url = PropertiesService.getScriptProperties().getProperty('GCHAT_WEBHOOK_URL');
  if (!url) {
    throw new Error('スクリプトプロパティ GCHAT_WEBHOOK_URL が未設定です');
  }
  return url;
}

/**
 * GitHub Token を取得（任意）
 * @returns {string | null}
 */
function getGitHubToken_() {
  return PropertiesService.getScriptProperties().getProperty('GITHUB_TOKEN') || null;
}

// ============================================================
// ログ
// ============================================================

/**
 * エラーログを記録
 * @param {string} message
 */
function logError_(message) {
  Logger.log(`[ERROR] ${message}`);

  // スプレッドシートにエラーログも記録（オプション）
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let logSheet = ss.getSheetByName('エラーログ');
    if (!logSheet) {
      logSheet = ss.insertSheet('エラーログ');
      logSheet.getRange(1, 1, 1, 2).setValues([['日時', 'メッセージ']]);
      logSheet.getRange(1, 1, 1, 2).setFontWeight('bold');
    }
    logSheet.appendRow([new Date(), message]);
  } catch (_) {
    // ログ記録自体が失敗した場合は無視
  }
}

// ============================================================
// セットアップ・管理関数
// ============================================================

/**
 * 初回セットアップ: シート作成 + 現在のバージョンを記録
 * ★ 初回に1度だけ手動実行してください
 */
function initialize() {
  // シート作成
  const sheet = getOrCreateSheet_();

  // 現在のバージョンを取得して記録（初回は通知しない）
  const npmInfo = fetchLatestVersionFromNpm_();
  if (npmInfo) {
    recordVersion_(npmInfo.version, npmInfo.publishedAt, '初回セットアップ時の記録');
    Logger.log(`初期化完了: 現在のバージョン v${npmInfo.version} を記録しました`);
    Logger.log('次回のバージョンアップから通知されます。');
  } else {
    Logger.log('初期化エラー: npm からバージョン情報を取得できませんでした');
  }

  // Webhook URL の設定確認
  try {
    getWebhookUrl_();
    Logger.log('✅ GCHAT_WEBHOOK_URL: 設定済み');
  } catch (e) {
    Logger.log('❌ GCHAT_WEBHOOK_URL: 未設定 → スクリプトプロパティを設定してください');
  }

  // GitHub Token の設定確認
  const token = getGitHubToken_();
  Logger.log(token ? '✅ GITHUB_TOKEN: 設定済み' : 'ℹ️ GITHUB_TOKEN: 未設定（任意）');
}

/**
 * 定期実行トリガーを設定
 * ★ 1度だけ手動実行してください
 */
function setupTrigger() {
  // 既存の同名トリガーを削除
  const triggers = ScriptApp.getProjectTriggers();
  triggers.forEach(trigger => {
    if (trigger.getHandlerFunction() === 'checkClaudeCodeUpdate') {
      ScriptApp.deleteTrigger(trigger);
      Logger.log('既存トリガーを削除しました');
    }
  });

  // 新規トリガー: 毎日 9:00〜10:00（JST）に実行
  ScriptApp.newTrigger('checkClaudeCodeUpdate')
    .timeBased()
    .everyDays(1)
    .atHour(9)
    .inTimezone('Asia/Tokyo')
    .create();

  Logger.log('トリガーを設定しました: 毎日 9:00（JST）に実行');
}

/**
 * トリガーを6時間ごとに変更（頻繁にチェックしたい場合）
 */
function setupFrequentTrigger() {
  const triggers = ScriptApp.getProjectTriggers();
  triggers.forEach(trigger => {
    if (trigger.getHandlerFunction() === 'checkClaudeCodeUpdate') {
      ScriptApp.deleteTrigger(trigger);
    }
  });

  ScriptApp.newTrigger('checkClaudeCodeUpdate')
    .timeBased()
    .everyHours(6)
    .create();

  Logger.log('トリガーを設定しました: 6時間ごとに実行');
}

/**
 * テスト用: 強制的に通知を送信
 */
function testNotification() {
  const npmInfo = fetchLatestVersionFromNpm_();
  if (!npmInfo) {
    Logger.log('npm からバージョン情報を取得できませんでした');
    return;
  }

  const changes = fetchChanges_(npmInfo.version);
  sendNotification_(npmInfo, changes, '(テスト)');
  Logger.log(`テスト通知を送信しました: v${npmInfo.version}`);
}

/**
 * テスト用: npm API の疎通確認
 */
function testNpmApi() {
  const info = fetchLatestVersionFromNpm_();
  Logger.log(info ? `✅ npm API OK: v${info.version}` : '❌ npm API エラー');
}

/**
 * テスト用: CHANGELOG 取得確認
 */
function testChangelog() {
  const info = fetchLatestVersionFromNpm_();
  if (!info) {
    Logger.log('npm API エラー');
    return;
  }

  const changes = fetchChanges_(info.version);
  Logger.log(`ソース: ${changes.source}`);
  Logger.log(`内容:\n${changes.summary.substring(0, 500)}`);
}
