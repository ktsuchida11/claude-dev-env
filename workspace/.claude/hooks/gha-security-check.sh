#!/usr/bin/env bash
# gha-security-check.sh — PostToolUse Hook for Edit/Write
# GitHub Actions ワークフローファイルのセキュリティリスクを検出する。
#
# 検出対象:
#   1. アクションのハッシュ未固定 (@v1, @main 等 → SHA 固定を推奨)
#   2. スクリプトインジェクション (${{ github.event.* }} を run: 内で使用)
#   3. pull_request_target + checkout (信頼されないコードの実行リスク)
#   4. 過剰な権限 (permissions: write-all, permissions 未設定)
#   5. persist-credentials 未設定 (actions/checkout のデフォルト true)
#   6. シークレット漏洩リスク (echo/printf で secrets.* を出力)
#   7. セルフホストランナーの使用 (runs-on: self-hosted)
#   8. workflow_dispatch inputs の未検証使用
#   9. GITHUB_TOKEN の過剰スコープ
#  10. サードパーティアクションの危険なパターン
#
# Exit 0 = 常に成功（ブロックはしない、警告のみ）

set -euo pipefail

# stdin から tool_input を読み取る
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# GitHub Actions ワークフローファイルかどうかを判定
# .github/workflows/*.yml or .github/workflows/*.yaml
IS_GHA=""
case "$FILE_PATH" in
  */.github/workflows/*.yml|*/.github/workflows/*.yaml)
    IS_GHA="true"
    ;;
esac

if [ -z "$IS_GHA" ]; then
  exit 0
fi

# ファイルが存在しない場合はスキップ
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# === ワークフローファイルの内容をチェック ===

CONTENT=$(cat "$FILE_PATH")
WARNINGS=""
CRITICALS=""
HEADER_SHOWN=""

show_header() {
  if [ -z "$HEADER_SHOWN" ]; then
    echo "" >&2
    echo "GitHub Actions Security Check" >&2
    echo "==========================================" >&2
    echo "  File: $FILE_PATH" >&2
    HEADER_SHOWN="true"
  fi
}

add_critical() {
  show_header
  echo "  [CRITICAL] $1" >&2
  CRITICALS="true"
}

add_warning() {
  show_header
  echo "  [WARN] $1" >&2
  WARNINGS="true"
}

add_info() {
  show_header
  echo "  [INFO] $1" >&2
}

# --- 1. アクションのハッシュ未固定チェック ---
# uses: actions/checkout@v4 → uses: actions/checkout@<sha> を推奨
# ローカルアクション (./) とリユーザブルワークフロー (.github/) は除外

check_unpinned_actions() {
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # uses: <owner>/<repo>@<ref> のパターンを検出
    if echo "$line" | grep -qE '^\s*-?\s*uses:\s'; then
      local action_ref
      action_ref=$(echo "$line" | sed -n 's/.*uses:[[:space:]]*//p' | tr -d '[:space:]')

      # ローカルアクション (./) はスキップ
      if echo "$action_ref" | grep -qE '^\./'; then
        continue
      fi

      # docker:// アクションはスキップ
      if echo "$action_ref" | grep -qE '^docker://'; then
        continue
      fi

      # @<ref> 部分を抽出
      local ref
      ref=$(echo "$action_ref" | grep -oE '@[^[:space:]]+$' | sed 's/@//' || true)

      if [ -z "$ref" ]; then
        add_warning "L${line_num}: アクションにバージョン指定がありません: $action_ref"
        add_info "       → @<commit-sha> で固定してください"
        continue
      fi

      # SHA (40文字の16進数) でない場合は警告
      if ! echo "$ref" | grep -qE '^[0-9a-f]{40}$'; then
        # v1, v2 等のタグやブランチ名
        local action_name
        action_name=$(echo "$action_ref" | sed 's/@.*//')

        # 公式 actions/* は INFO レベル、サードパーティは WARN
        if echo "$action_name" | grep -qE '^(actions|github)/'; then
          add_info "L${line_num}: 公式アクション未固定: $action_ref"
          add_info "       → SHA 固定を推奨 (例: ${action_name}@<commit-sha> # ${ref})"
        else
          add_warning "L${line_num}: サードパーティアクション未固定: $action_ref"
          add_info "       → サプライチェーン攻撃防止のため SHA 固定を強く推奨"
          add_info "       → gh api repos/${action_name}/commits/heads/${ref} --jq '.sha' で取得"
        fi
      fi
    fi
  done <<< "$CONTENT"
}

# --- 2. スクリプトインジェクションチェック ---
# run: ブロック内で ${{ github.event.* }} 等の未サニタイズ入力を検出

check_script_injection() {
  local line_num=0
  local in_run_block=""

  # 危険なコンテキスト変数（攻撃者が制御可能）
  local dangerous_contexts=(
    'github\.event\.issue\.title'
    'github\.event\.issue\.body'
    'github\.event\.pull_request\.title'
    'github\.event\.pull_request\.body'
    'github\.event\.pull_request\.head\.ref'
    'github\.event\.pull_request\.head\.label'
    'github\.event\.comment\.body'
    'github\.event\.review\.body'
    'github\.event\.review_comment\.body'
    'github\.event\.discussion\.title'
    'github\.event\.discussion\.body'
    'github\.event\.pages\.\*\.page_name'
    'github\.event\.commits\.\*\.message'
    'github\.event\.commits\.\*\.author\.name'
    'github\.event\.commits\.\*\.author\.email'
    'github\.event\.head_commit\.message'
    'github\.event\.head_commit\.author\.name'
    'github\.event\.head_commit\.author\.email'
    'github\.event\.workflow_dispatch\.inputs\.'
    'github\.head_ref'
  )

  # 全パターンを1つの正規表現に結合
  local pattern
  pattern=$(IFS='|'; echo "${dangerous_contexts[*]}")

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # run: ブロックの開始を検出（YAML リスト要素の "- run:" にも対応）
    if echo "$line" | grep -qE '^\s*(-\s*)?run:\s*[|>]?\s*$' || echo "$line" | grep -qE '^\s*(-\s*)?run:\s+\S'; then
      in_run_block="true"
    elif [ -n "$in_run_block" ] && echo "$line" | grep -qE '^\s*(-\s*)?[a-zA-Z_-]+:' && ! echo "$line" | grep -qE '^\s*run:'; then
      # 別のキーが出現したら run ブロック終了
      in_run_block=""
    fi

    # run ブロック内（run: の行自体も含む）で危険なコンテキスト変数を検出
    if [ -n "$in_run_block" ]; then
      if echo "$line" | grep -qE "\\\$\{\{.*($pattern)"; then
        local context_var
        context_var=$(echo "$line" | grep -oE "\\\$\{\{[^}]*($pattern)[^}]*\}\}" | head -1)
        add_critical "L${line_num}: スクリプトインジェクションの危険性"
        add_info "       → run: ブロック内で未サニタイズの入力を使用: $context_var"
        add_info "       → 環境変数経由で渡し、クォートしてください:"
        add_info "         env:"
        add_info "           TITLE: \${{ github.event.issue.title }}"
        add_info "         run: echo \"\$TITLE\""
      fi
    fi
  done <<< "$CONTENT"
}

# --- 3. pull_request_target + checkout チェック ---

check_prt_checkout() {
  if echo "$CONTENT" | grep -qE '^\s*on:.*pull_request_target' || \
     echo "$CONTENT" | grep -qE '^\s+pull_request_target:'; then

    if echo "$CONTENT" | grep -qE 'actions/checkout@'; then
      # PR の HEAD をチェックアウトしているか確認
      if echo "$CONTENT" | grep -qE 'ref:.*\$\{\{\s*github\.event\.pull_request\.head\.(sha|ref)' || \
         echo "$CONTENT" | grep -qE 'ref:.*\$\{\{\s*github\.head_ref'; then
        add_critical "pull_request_target で PR の HEAD をチェックアウトしています"
        add_info "       → 信頼されないコードがワークフローの権限で実行される危険性があります"
        add_info "       → pull_request_target は PR のラベル付け等の安全な操作にのみ使用してください"
        add_info "       → コードをビルド/テストする場合は pull_request イベントを使用してください"
      else
        add_warning "pull_request_target でリポジトリをチェックアウトしています"
        add_info "       → デフォルトブランチがチェックアウトされますが、"
        add_info "         後続のステップで PR の ref を参照していないか確認してください"
      fi
    fi
  fi
}

# --- 4. 過剰な権限チェック ---

check_permissions() {
  # write-all / read-all のチェック
  if echo "$CONTENT" | grep -qE '^\s*permissions:\s*write-all'; then
    add_critical "トップレベルで permissions: write-all が設定されています"
    add_info "       → 最小権限の原則に従い、必要な権限のみ設定してください"
    add_info "       → 例: permissions: { contents: read, pull-requests: write }"
  fi

  # permissions が未設定かチェック (トップレベル)
  if ! echo "$CONTENT" | grep -qE '^\s*permissions:'; then
    add_warning "permissions が未設定です（デフォルトは広い権限）"
    add_info "       → トップレベルに permissions を明示的に設定してください"
    add_info "       → 最小構成: permissions: { contents: read }"
  fi
}

# --- 5. persist-credentials チェック ---

check_persist_credentials() {
  # actions/checkout を使用している場合
  if echo "$CONTENT" | grep -qE 'actions/checkout@'; then
    # persist-credentials: false が明示されていない場合
    if ! echo "$CONTENT" | grep -qE 'persist-credentials:\s*false'; then
      add_info "actions/checkout で persist-credentials: false が未設定です"
      add_info "       → デフォルト (true) では GITHUB_TOKEN が .git/config に残ります"
      add_info "       → 後続ステップでトークン不要なら false を設定してください"
    fi
  fi
}

# --- 6. シークレット漏洩リスクチェック ---

check_secret_exposure() {
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # echo/printf で secrets.* を出力
    if echo "$line" | grep -qE '(echo|printf|cat|>>)\s.*\$\{\{\s*secrets\.'; then
      add_critical "L${line_num}: シークレットが標準出力に露出する可能性"
      add_info "       → echo/printf でシークレットを出力しないでください"
      add_info "       → ファイルに書き出す場合は ::add-mask:: で事前にマスクしてください"
    fi

    # シークレットをログに出力するパターン
    if echo "$line" | grep -qE 'curl.*(-H|--header).*\$\{\{\s*secrets\.'; then
      # これは正常なパターン（API呼び出し）なのでスキップ
      continue
    fi
  done <<< "$CONTENT"
}

# --- 7. セルフホストランナーチェック ---

check_self_hosted_runner() {
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if echo "$line" | grep -qE 'runs-on:.*self-hosted'; then
      add_warning "L${line_num}: セルフホストランナーが使用されています"
      add_info "       → セルフホストランナーはパブリックリポジトリでは危険です"
      add_info "       → 信頼されないPRからのワークフロー実行でホストが侵害される可能性"
      add_info "       → パブリックリポジトリでは GitHub ホストランナーを推奨します"
    fi
  done <<< "$CONTENT"
}

# --- 8. workflow_dispatch inputs の未検証使用チェック ---

check_workflow_dispatch_inputs() {
  if echo "$CONTENT" | grep -qE '^\s+workflow_dispatch:'; then
    local line_num=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))

      # run: ブロック内で inputs.* を直接使用
      if echo "$line" | grep -qE 'run:.*\$\{\{\s*(?:github\.event\.)?inputs\.'; then
        add_warning "L${line_num}: workflow_dispatch の入力値が run: 内で直接使用されています"
        add_info "       → 入力値は環境変数経由で渡し、クォートしてください"
      fi
    done <<< "$CONTENT"
  fi
}

# --- 9. 危険なサードパーティアクションパターン ---

check_dangerous_patterns() {
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # actions/github-script で直接 github.token を外部送信
    if echo "$line" | grep -qE 'actions/github-script@'; then
      # 後続行でfetchやcurl的な操作がないか（簡易チェック）
      :
    fi

    # GITHUB_TOKEN や secrets をコマンド引数に直接渡す
    if echo "$line" | grep -qE '\$\{\{\s*secrets\.[^}]+\}\}' && echo "$line" | grep -qE '(curl|wget|http)'; then
      # curl のヘッダーで使うのは正常だが、URL パラメータは危険
      if echo "$line" | grep -qE '\?(.*=)?\$\{\{\s*secrets\.'; then
        add_critical "L${line_num}: シークレットが URL パラメータに含まれています"
        add_info "       → URL パラメータのシークレットはログに記録される可能性があります"
        add_info "       → ヘッダー (-H Authorization) 経由で渡してください"
      fi
    fi

    # 環境変数の ACTIONS_RUNTIME_TOKEN や ACTIONS_ID_TOKEN_REQUEST_URL の使用
    if echo "$line" | grep -qE 'ACTIONS_RUNTIME_TOKEN|ACTIONS_ID_TOKEN_REQUEST_URL'; then
      add_warning "L${line_num}: GitHub Actions 内部トークンへの直接アクセス"
      add_info "       → これらのトークンは OIDC 認証等の正当な用途以外で使用しないでください"
    fi
  done <<< "$CONTENT"
}

# --- 10. その他のベストプラクティスチェック ---

check_best_practices() {
  # continue-on-error: true の広範な使用
  local coe_count
  coe_count=$(echo "$CONTENT" | grep -cE 'continue-on-error:\s*true' || true)
  if [ "$coe_count" -gt 2 ]; then
    add_warning "continue-on-error: true が ${coe_count} 箇所で使用されています"
    add_info "       → セキュリティチェックのステップでは continue-on-error を避けてください"
  fi

  # timeout-minutes 未設定
  if ! echo "$CONTENT" | grep -qE 'timeout-minutes:'; then
    add_info "timeout-minutes が未設定です（デフォルト: 360分）"
    add_info "       → ハングしたジョブのリソース消費を防ぐため設定を推奨"
  fi

  # concurrency 設定がない場合
  if echo "$CONTENT" | grep -qE '(pull_request|push):' && ! echo "$CONTENT" | grep -qE 'concurrency:'; then
    add_info "concurrency が未設定です"
    add_info "       → 同じ PR への重複実行を防ぐため concurrency の設定を推奨"
    add_info "       → 例: concurrency: { group: \${{ github.workflow }}-\${{ github.ref }}, cancel-in-progress: true }"
  fi
}

# === チェック実行 ===

check_unpinned_actions
check_script_injection
check_prt_checkout
check_permissions
check_persist_credentials
check_secret_exposure
check_self_hosted_runner
check_workflow_dispatch_inputs
check_dangerous_patterns
check_best_practices

# === サマリー ===

if [ -n "$HEADER_SHOWN" ]; then
  echo "==========================================" >&2
  if [ -n "$CRITICALS" ]; then
    echo "  CRITICAL な問題が検出されました。修正を強く推奨します。" >&2
  fi
  echo "  参考: https://docs.github.com/en/actions/security-for-github-actions" >&2
  echo "" >&2
fi

exit 0
