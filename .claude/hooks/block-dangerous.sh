#!/usr/bin/env bash
# block-dangerous.sh — PreToolUse Hook for Bash commands
#
# settings.json の deny ルールを補完する追加の防御レイヤー。
# deny ルールはパターンマッチベースのため、パイプやサブシェルで
# バイパスされる可能性がある。このスクリプトで追加チェックを行う。
#
# auto モード（Claude Code 2.1.177+ のデフォルト）では、sandbox 自動承認
# （autoAllowBashIfSandboxed）や allow ルールにより大半の Bash コマンドが
# LLM 分類器に届かず自動承認される。permissions.ask も sandboxed Bash では
# スキップされるため、「確認が必要な操作」は本フックの ask ゲートが
# 唯一の決定的な確認強制手段になる。
#
# 出力形式: hookSpecificOutput.permissionDecision を stdout に出す（正式スキーマ）。
#   - deny: ツール実行をブロック
#   - ask : ユーザー確認プロンプトを強制（auto モード・sandbox 自動承認でも有効）
# 旧形式の `{"decision":"block"}` + exit 2 は PreToolUse では deprecated。

set -euo pipefail

# --- 出力ヘルパ ---
# stdout に正式スキーマの JSON を出力する。JSON が判断を伝えるため exit 0。
deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}
ask() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# stdin から tool_input を読み取る
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ============================================================
# deny ゲート（ブロック）— ask ゲートより先に評価する
# ============================================================

# --- 破壊的コマンドのパターン検出 ---

# rm -rf with dangerous targets (/, ~, $HOME, ..) — 完全ブロック
# /workspace/... 等の安全なパスへの rm は後段の ask ゲートで確認を挟む
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)*(\/(\s|$)|~|(\$HOME|\$\{HOME\})|\.\.)'; then
  deny "Blocked: rm with dangerous target path (/, ~, \$HOME, ..)"
fi

# --- 以下はユーザー確認プロンプトをバイパスできる手段のため全面ブロック ---

# unlink（rm の代替コマンド、確認プロンプトを回避できる）
if echo "$COMMAND" | grep -qE '\bunlink\s'; then
  deny "Blocked: unlink bypasses user confirmation. Use rm instead (requires user approval)."
fi

# curl/wget through pipes or subshells (bypass attempt)
if echo "$COMMAND" | grep -qE '\b(curl|wget)\s'; then
  deny "Blocked: curl/wget is not allowed in this environment"
fi

# Network tools through pipes
# \b 必須: nc に境界が無いと "uv sync " "rsync " 等の "nc " 部分文字列に誤マッチする
if echo "$COMMAND" | grep -qE '\b(nc|ncat|telnet|socat)\s'; then
  deny "Blocked: network tools are not allowed"
fi

# Reverse shell patterns
if echo "$COMMAND" | grep -qE '(bash|sh|zsh)\s+-i.*>/dev/tcp'; then
  deny "Blocked: reverse shell pattern detected"
fi

# Base64 decode piped to shell (common obfuscation)
if echo "$COMMAND" | grep -qE 'base64.*-d.*\|\s*(bash|sh|zsh|python|node)'; then
  deny "Blocked: base64 decode to shell execution"
fi

# sudo の全面ブロック（settings.json の deny ルールの二重化）
# sudoers は firewall 初期化のため node に iptables/init-firewall.sh を NOPASSWD 許可しているが、
# firewall 初期化は postStartCommand が行うため Claude が sudo を使う正当な場面は無い
if echo "$COMMAND" | grep -qE '(^|[|;&[:space:]])sudo([[:space:]]|$)'; then
  deny "Blocked: sudo is not allowed. Firewall initialization is handled by postStartCommand."
fi

# 機密ファイルアクセス（コマンド非依存）
# auto モードでは Bash(head *) 等の allow ルールが分類器を素通りするため、
# cat 限定ではなく「引数に機密パスが現れたら」ブロックする。
# .env.example / .env.enc / .env.sample は許可（雛形・暗号化済みファイル）
SCRUBBED=$(echo "$COMMAND" | sed -E 's/\.env\.(example|enc|sample)/__SAFE_ENV__/g')
if echo "$SCRUBBED" | grep -qE '(^|[[:space:]"'"'"'=/])\.env([./"'"'"'[:space:]]|$)|credentials|\.ssh/|\.aws/|\.gnupg/|id_rsa|id_ed25519|\.pem\b|age[^[:space:]]*\.key|/run/secrets'; then
  deny "Blocked: access to sensitive files (.env, credentials, SSH/age/AWS keys) is not allowed"
fi

# Environment variable exfiltration
if echo "$COMMAND" | grep -qE '(printenv|env)\s*\|.*(curl|wget|nc|python|node)'; then
  deny "Blocked: environment variable exfiltration attempt"
fi

# gh CLI の危険サブコマンド
# - gh api: 認証済みトークンによる任意 HTTP（repo 横断書込の濫用経路）
# - gh auth token: トークン平文出力（ログ・他プロセスへの漏洩）
# - gh auth login/logout/refresh: 認証状態の操作
# - gh secret / variable: repo secret/variable の読取・変更
# - gh workflow run/enable/disable: CI 任意起動・状態変更（CI 経由 RCE）
# - gh ssh-key / gpg-key: 永続化鍵の追加
if echo "$COMMAND" | grep -qE '\bgh\s+(api|secret|variable|ssh-key|gpg-key)\b|\bgh\s+auth\s+(token|login|logout|refresh)\b|\bgh\s+workflow\s+(run|enable|disable)\b'; then
  deny "Blocked: dangerous gh subcommand (api / auth token / secret / variable / workflow run / ssh-key / gpg-key)"
fi

# chmod: world-writable / setuid (u+s, 4xxx) / setgid (g+s, 2xxx) / sticky+SUID+SGID (6xxx) / -R 再帰
# シンボリック (+s) も数値 (4755 等) も両対応。setuid バイナリ作成は権限昇格の直接経路
if echo "$COMMAND" | grep -qE 'chmod\s+([ug]?\+s|777|666|-R\s+(777|666)|[2467][0-7]{3})(\s|$)'; then
  deny "Blocked: chmod with overly permissive or setuid/setgid mode is not allowed"
fi

# find -delete / find -exec rm（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'find\s.*(-delete|-exec\s*(rm|shred))'; then
  deny "Blocked: find -delete/-exec rm bypasses user confirmation. Use rm instead."
fi

# xargs rm / shred（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'xargs\s+(rm|shred)'; then
  deny "Blocked: xargs rm/shred bypasses user confirmation. Use rm instead."
fi

# perl/python ワンライナーによるファイル削除（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'perl\s+-e\s.*unlink|python3?\s+-c\s.*os\.(remove|unlink)'; then
  deny "Blocked: file deletion via scripting language bypasses user confirmation. Use rm instead."
fi

# mv で /dev/null に移動（実質削除、確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE 'mv\s+.*\s+/dev/null'; then
  deny "Blocked: mv to /dev/null bypasses user confirmation. Use rm instead."
fi

# shred 単体（確認プロンプトをバイパスできる）
if echo "$COMMAND" | grep -qE '\bshred\s'; then
  deny "Blocked: shred bypasses user confirmation. Use rm instead."
fi

# --- 設定ファイル・hooks の保護 ---

# リダイレクト / tee による settings ファイルへの書き込み
# リダイレクト先そのものが settings ファイルの場合のみブロック
# （`cat settings.json 2>&1` のような読み取りは誤検知しない）
if echo "$COMMAND" | grep -qE '(>>?[[:space:]]*|(^|[[:space:]]|[|;&])tee[[:space:]]+(-\S+[[:space:]]+)*)[^|;&[:space:]]*(settings\.json|\.claude\.json|\.mcp\.json)'; then
  deny "Blocked: modification of Claude Code settings files"
fi

# sed -i / jq による settings ファイル変更（リダイレクト以外のバイパス防止）
if echo "$COMMAND" | grep -qE '(sed\s+-i|jq\s+.*>)\s*.*(settings\.json|\.claude\.json|\.mcp\.json)'; then
  deny "Blocked: in-place modification of Claude Code settings files"
fi

# cp / mv / install / rsync / ln / tar による設定・hooks・skills の上書き
# auto モードでは Bash(cp *) / Bash(mv *) の allow ルールが分類器を素通りするため必須。
# sandbox denyWrite が第1層、本ゲートが第2層（sandbox 外実行や設定ミスへの保険）
if echo "$COMMAND" | grep -qE '\b(cp|mv|install|rsync|ln|tar)\b.*(settings\.json|settings\.local\.json|\.claude\.json|\.mcp\.json|\.claude/hooks|\.claude/skills)'; then
  deny "Blocked: overwriting Claude Code settings/hooks/skills via cp/mv/install/rsync/ln/tar"
fi

# --- git 経由の危険操作 ---

# git config / -c 経由の任意コード実行
# core.pager / core.fsmonitor / core.editor / core.sshCommand / core.askpass や
# `!` 付き alias は git 実行時に任意コマンドを起動できる
if echo "$COMMAND" | grep -qiE '\bgit\b.*(-c[[:space:]]+(core\.(pager|fsmonitor|editor|sshcommand|askpass)|alias\.)|[[:space:]]config[[:space:]].*(core\.(pager|fsmonitor|editor|sshcommand|askpass)|alias\.[^[:space:]]*[[:space:]]+.*!))'; then
  deny "Blocked: git config keys that enable arbitrary command execution (core.pager/fsmonitor/editor/sshCommand/askpass, shell alias)"
fi

# force push（--force-with-lease のみ ask、それ以外の強制 push は deny）
if echo "$COMMAND" | grep -qE '\bgit\b[^|;&]*\bpush\b'; then
  if echo "$COMMAND" | grep -qE -- '--force-with-lease'; then
    ask "git push --force-with-lease detected. Confirm before rewriting remote history."
  elif echo "$COMMAND" | grep -qE -- '--force\b|(^|[[:space:]])-f\b|\bpush\b[^|;&]*[[:space:]]\+[[:alnum:]]'; then
    deny "Blocked: git push --force / +refspec rewrites remote history. Use --force-with-lease with user confirmation if truly needed."
  fi
fi

# サンドボックス無効化の試行検出
if echo "$COMMAND" | grep -qiE 'sandbox.*enabled.*false|"enabled"\s*:\s*false.*sandbox|dangerouslyDisableSandbox'; then
  deny "Blocked: attempt to disable sandbox"
fi

# ============================================================
# ask ゲート（ユーザー確認の強制）— deny を全て通過した後に評価
# auto モードの sandbox 自動承認では確認プロンプトが出ないため、
# 「削除はユーザー確認必須」ポリシーを hook で復活させる
# ============================================================

# 素の rm / rmdir（危険ターゲットは上の deny で除外済み）
if echo "$COMMAND" | grep -qE '(^|[|;&[:space:]])(rm|rmdir)([[:space:]]|$)'; then
  ask "File deletion requires user confirmation (environment policy). Confirm this rm/rmdir operation."
fi

# git の破壊的操作（作業内容の不可逆な破棄）
if echo "$COMMAND" | grep -qE '\bgit\b[^|;&]*(\bclean\b[^|;&]*-[[:alnum:]]*f|\breset\b[^|;&]*--hard|\bcheckout\b[^|;&]*[[:space:]]--([[:space:]]|$))'; then
  ask "Destructive git operation (clean -f / reset --hard / checkout --) discards work irreversibly. Confirm before proceeding."
fi

# docker ボリューム・データ破棄
if echo "$COMMAND" | grep -qE 'docker[[:space:]]+compose\b[^|;&]*\bdown\b[^|;&]*(-v\b|--volumes\b)|docker[[:space:]]+volume[[:space:]]+(rm|prune)'; then
  ask "Docker volume destruction deletes persistent data. Confirm before proceeding."
fi

# ============================================================
# python / node 経由の egress 検出（情報提供レベル）
# ============================================================
# 主防御は init-firewall.sh の egress 許可リスト。
# このチェックは「気づき」を提供するもので、firewall を回避することは不可能。
# 開発で正当に使う場面（Anthropic API、PyPI アクセス等）が多いため警告のみが既定。
# 強制ブロックしたい場合は STRICT_EGRESS_BLOCK=true を設定する。
EGRESS_HIT=""
EGRESS_REASON=""

if echo "$COMMAND" | grep -qE '\b(python|python3)\s+-c\b.*\b(urllib|httplib|http\.client|requests|socket|aiohttp|urllib3|httpx)\b'; then
  EGRESS_HIT="true"
  EGRESS_REASON="Python ネットワークモジュール (urllib/http.client/requests/socket/aiohttp/urllib3/httpx) の直接実行を検出"
fi

if echo "$COMMAND" | grep -qE "\bnode\s+-[ep]\b.*(require\(['\"](https?|net|http2)['\"]\)|\bfetch\s*\()"; then
  EGRESS_HIT="true"
  EGRESS_REASON="Node 標準モジュール (http/https/net/http2/fetch) の直接実行を検出"
fi

if [ -n "$EGRESS_HIT" ]; then
  if [ "${STRICT_EGRESS_BLOCK:-false}" = "true" ]; then
    deny "Blocked (STRICT_EGRESS_BLOCK=true): ${EGRESS_REASON}. Set STRICT_EGRESS_BLOCK=false to allow with warning only."
  else
    echo "[block-dangerous] WARN: ${EGRESS_REASON}. firewall が許可ドメインのみ通すので主防御は維持されますが、意図した処理か確認してください。STRICT_EGRESS_BLOCK=true でブロック動作に切替可能。" >&2
  fi
fi

# All checks passed
exit 0
