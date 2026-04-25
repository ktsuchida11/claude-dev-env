#!/usr/bin/env bash
# dockerfile-cooldown-check.sh — Pre/PostToolUse Hook for Edit/Write
# Dockerfile の編集・作成時にクールダウン設定の有無をチェックする。
#
# 検出対象:
#   - npm install / npm ci に --ignore-scripts / min-release-age がないケース
#   - pip install に --uploaded-prior-to がないケース
#   - uv pip install / uv add に --exclude-newer がないケース
#
# モード:
#   --pre 引数あり (PreToolUse 用): tool_input から「変更後の内容」を再構築してチェック。
#     ENABLE_DOCKERFILE_COOLDOWN_BLOCK=true のときに警告があれば exit 2 でブロック、
#     それ以外（デフォルト）はサイレント exit 0（PostToolUse 側で警告される）
#   --pre 引数なし (PostToolUse 用): 従来どおりディスクのファイルを読んで警告のみ
#
# 無効化: ENABLE_SUPPLY_CHAIN_GUARD=false
# Pre ブロック有効化: ENABLE_DOCKERFILE_COOLDOWN_BLOCK=true（デフォルト false = 警告のみ）

set -euo pipefail

# ON/OFF 制御
if [ "${ENABLE_SUPPLY_CHAIN_GUARD:-true}" = "false" ]; then
  exit 0
fi

# --- モード判定 ---
HOOK_MODE="post"
if [ "${1:-}" = "--pre" ]; then
  HOOK_MODE="pre"
  # Pre モードはオプトイン: ENABLE_DOCKERFILE_COOLDOWN_BLOCK=true のときだけ動作。
  # それ以外はサイレント exit 0（警告は PostToolUse が出力する。二重表示を避ける）
  if [ "${ENABLE_DOCKERFILE_COOLDOWN_BLOCK:-false}" != "true" ]; then
    exit 0
  fi
fi

# stdin から tool_input を読み取る
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Dockerfile かどうかを判定（Dockerfile, Dockerfile.*, *.dockerfile）
BASENAME=$(basename "$FILE_PATH")
IS_DOCKERFILE=""
case "$BASENAME" in
  Dockerfile|Dockerfile.*|*.dockerfile|*.Dockerfile)
    IS_DOCKERFILE="true"
    ;;
esac

if [ -z "$IS_DOCKERFILE" ]; then
  exit 0
fi

# Pre モード: tool_input から「変更後の内容」を再構築する
# Post モード: ディスク上のファイルを読む（従来動作）
if [ "$HOOK_MODE" = "pre" ]; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  case "$TOOL_NAME" in
    Write)
      # 新規 / 上書き: tool_input.content がそのまま反映される内容
      RAW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
      ;;
    Edit)
      # 部分置換: 現状ファイル + old_string→new_string の置換結果
      OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
      NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
      REPLACE_ALL=$(echo "$INPUT" | jq -r '.tool_input.replace_all // false' 2>/dev/null)
      if [ ! -f "$FILE_PATH" ]; then
        # 編集対象が存在しない（理論的には Edit では起きないが念のため）
        exit 0
      fi
      RAW_CONTENT=$(python3 - "$FILE_PATH" "$OLD_STR" "$NEW_STR" "$REPLACE_ALL" << 'PYEOF'
import sys
path, old, new, replace_all = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, 'r') as f:
    text = f.read()
if replace_all == "true":
    text = text.replace(old, new)
else:
    text = text.replace(old, new, 1)
sys.stdout.write(text)
PYEOF
)
      ;;
    *)
      # 想定外のツール: スキップ
      exit 0
      ;;
  esac
  if [ -z "$RAW_CONTENT" ]; then
    exit 0
  fi
else
  # Post モード: ファイルが存在しない場合はスキップ
  if [ ! -f "$FILE_PATH" ]; then
    exit 0
  fi
fi

# === Dockerfile の内容をチェック ===

WARNINGS=""
WARN_LEVEL_HIT=""  # [WARN] エントリのみ block 対象。[INFO] は警告のみ。
HEADER_SHOWN=""

show_header() {
  if [ -z "$HEADER_SHOWN" ]; then
    echo "" >&2
    echo "Dockerfile Cooldown Check" >&2
    echo "==========================================" >&2
    echo "  File: $FILE_PATH" >&2
    HEADER_SHOWN="true"
  fi
}

add_warning() {
  show_header
  echo "  $1" >&2
  WARNINGS="true"
  case "$1" in
    *"[WARN]"*)
      WARN_LEVEL_HIT="true"
      ;;
  esac
}

# RUN 命令を抽出（複数行の継続 \ を結合）
# sed: 行末の \ を除去して次行と結合
if [ "$HOOK_MODE" = "pre" ]; then
  DOCKERFILE_CONTENT=$(printf '%s' "$RAW_CONTENT" | sed ':a;/\\$/N;s/\\\n//;ta')
else
  DOCKERFILE_CONTENT=$(sed ':a;/\\$/N;s/\\\n//;ta' "$FILE_PATH" 2>/dev/null || cat "$FILE_PATH")
fi

# --- npm install / npm ci チェック ---
npm_lines=$(echo "$DOCKERFILE_CONTENT" | grep -n 'npm\s\+\(install\|ci\|i\)\b' 2>/dev/null || true)

if [ -n "$npm_lines" ]; then
  while IFS= read -r line; do
    line_num=$(echo "$line" | cut -d: -f1)
    line_content=$(echo "$line" | cut -d: -f2-)

    # --ignore-scripts チェック
    if ! echo "$line_content" | grep -q '\-\-ignore-scripts'; then
      # npm config set ignore-scripts が事前に設定されているか確認
      if ! echo "$DOCKERFILE_CONTENT" | grep -q 'npm config set.*ignore-scripts'; then
        add_warning "[WARN] L${line_num}: npm install に --ignore-scripts がありません"
        add_warning "       → postinstall スクリプトによる攻撃を防止するため追加を推奨"
      fi
    fi

    # min-release-age チェック（npm config set で事前設定されていればOK）
    if ! echo "$line_content" | grep -q '\-\-min-release-age'; then
      if ! echo "$DOCKERFILE_CONTENT" | grep -q 'npm config set.*min-release-age'; then
        add_warning "[WARN] L${line_num}: npm にクールダウン設定がありません"
        add_warning "       → 事前に npm config set -g min-release-age 7 を追加するか"
        add_warning "         コマンドに --min-release-age=7 を付与してください"
      fi
    fi
  done <<< "$npm_lines"
fi

# --- pip install チェック ---
pip_lines=$(echo "$DOCKERFILE_CONTENT" | grep -n 'pip3\?\s\+install\b' 2>/dev/null || true)

if [ -n "$pip_lines" ]; then
  while IFS= read -r line; do
    line_num=$(echo "$line" | cut -d: -f1)
    line_content=$(echo "$line" | cut -d: -f2-)

    # pip 自体のアップグレード（pip install --upgrade pip）はスキップ
    if echo "$line_content" | grep -qE '\-\-upgrade\s+pip\b'; then
      continue
    fi

    # uv のインストール（pip install uv）もブートストラップなのでスキップ
    if echo "$line_content" | grep -qE 'install.*\buv\b' && ! echo "$line_content" | grep -qE 'install.*\buv\b.*\S+'; then
      continue
    fi

    # --uploaded-prior-to チェック
    if ! echo "$line_content" | grep -q '\-\-uploaded-prior-to'; then
      add_warning "[WARN] L${line_num}: pip install に --uploaded-prior-to がありません"
      add_warning "       → COOLDOWN_DATE=\$(date -u -d '7 days ago' +%Y-%m-%d) を計算し"
      add_warning "         --uploaded-prior-to=\$COOLDOWN_DATE を付与してください"
    fi

    # --only-binary チェック（setup.py 実行防止）
    if ! echo "$line_content" | grep -q '\-\-only-binary'; then
      add_warning "[INFO] L${line_num}: --only-binary :all: の付与を推奨します"
      add_warning "       → setup.py の実行を防止し、wheel のみインストールします"
    fi
  done <<< "$pip_lines"
fi

# --- uv pip install / uv add チェック ---
uv_lines=$(echo "$DOCKERFILE_CONTENT" | grep -n 'uv\s\+\(pip\s\+install\|add\|sync\)\b' 2>/dev/null || true)

if [ -n "$uv_lines" ]; then
  while IFS= read -r line; do
    line_num=$(echo "$line" | cut -d: -f1)
    line_content=$(echo "$line" | cut -d: -f2-)

    # --exclude-newer チェック
    if ! echo "$line_content" | grep -q '\-\-exclude-newer'; then
      # uv.toml が COPY されているか確認
      if ! echo "$DOCKERFILE_CONTENT" | grep -q 'COPY.*uv\.toml'; then
        add_warning "[WARN] L${line_num}: uv コマンドに --exclude-newer がありません"
        add_warning "       → --exclude-newer \"<7日前の日時>\" を付与するか"
        add_warning "         uv.toml を COPY して exclude-newer を設定してください"
      fi
    fi
  done <<< "$uv_lines"
fi

# --- pip のバージョンアップグレードチェック ---
if [ -n "$pip_lines" ]; then
  if ! echo "$DOCKERFILE_CONTENT" | grep -qE 'pip.*install.*--upgrade\s+pip|pip.*install.*pip\s*>'; then
    add_warning "[INFO] pip のバージョンアップグレードがありません"
    add_warning "       → pip v26.0+ が --uploaded-prior-to に必要です"
    add_warning "         RUN pip install --upgrade pip を追加してください"
  fi
fi

# --- npm のバージョンアップグレードチェック ---
if [ -n "$npm_lines" ]; then
  if ! echo "$DOCKERFILE_CONTENT" | grep -qE 'npm install -g npm@'; then
    add_warning "[INFO] npm のバージョンアップグレードがありません"
    add_warning "       → npm v11.10.0+ が min-release-age に必要です"
    add_warning "         RUN npm install -g npm@latest を追加してください"
  fi
fi

# === サマリー / 判定 ===
if [ -n "$HEADER_SHOWN" ]; then
  echo "==========================================" >&2
  if [ -n "$WARNINGS" ]; then
    echo "  参考: DevContainer の Dockerfile を確認してください:" >&2
    echo "    .devcontainer/Dockerfile" >&2
  fi
  echo "" >&2
fi

# Pre モード + ブロック有効 + WARN レベル警告ありなら exit 2
# （INFO レベル：npm/pip 自体のアップグレード推奨等はブロックしない）
if [ "$HOOK_MODE" = "pre" ] && [ -n "$WARN_LEVEL_HIT" ] && [ "${ENABLE_DOCKERFILE_COOLDOWN_BLOCK:-false}" = "true" ]; then
  echo "{\"decision\": \"block\", \"reason\": \"Blocked: Dockerfile lacks cooldown settings (npm min-release-age / pip --uploaded-prior-to / uv --exclude-newer). Add cooldown directives or set ENABLE_DOCKERFILE_COOLDOWN_BLOCK=false to skip.\"}" >&2
  exit 2
fi

exit 0
