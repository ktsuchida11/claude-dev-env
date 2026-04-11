#!/usr/bin/env bash
# env-plaintext-guard.sh — PostToolUse Hook for Bash (git commit)
# git commit に平文の .env ファイルが含まれていないか検査する
# Exit 0 = always (PostToolUse は情報提供のみ)
#
# Trigger: git commit コマンドの実行後

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
    exit 0
fi

# git commit 以外は無視
if ! echo "$COMMAND" | grep -qE '^\s*git\s+commit'; then
    exit 0
fi

# ステージされたファイルを取得
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
if [ -z "$STAGED" ]; then
    exit 0
fi

WARNINGS=""

while IFS= read -r file; do
    # .env ファイル（.env, .env.local, .env.development 等）をチェック
    # .env.enc, .env.example は除外
    if echo "$file" | grep -qE '(^|/)\.env(\.[a-zA-Z]+)?$' && \
       ! echo "$file" | grep -qE '\.(enc|example|sample)$'; then

        # ファイルが存在し、暗号化されていない場合
        if [ -f "$file" ]; then
            if ! head -5 "$file" | grep -qE 'sops_|ENC\[AES|DOTENV_PUBLIC_KEY'; then
                WARNINGS="${WARNINGS}  - ${file} (平文のシークレットが含まれている可能性があります)\n"
            fi
        fi
    fi

    # .env.keys は絶対にコミットしてはいけない
    if echo "$file" | grep -qE '(^|/)\.env\.keys$'; then
        WARNINGS="${WARNINGS}  - ${file} (復号用秘密鍵！コミット厳禁)\n"
    fi

    # age 秘密鍵ファイル
    if echo "$file" | grep -qE 'age.*\.key$|keys\.txt$'; then
        WARNINGS="${WARNINGS}  - ${file} (age 秘密鍵！コミット厳禁)\n"
    fi

done <<< "$STAGED"

if [ -n "$WARNINGS" ]; then
    echo ""
    echo "WARNING: 以下のファイルにシークレットが含まれている可能性があります:"
    echo -e "$WARNINGS"
    echo "対処:"
    echo "  - .env は .env.enc（暗号化済み）を代わりにコミットしてください"
    echo "  - bash scripts/setup-env-encryption.sh encrypt で暗号化できます"
    echo "  - git reset HEAD <file> でステージングから除外してください"
    echo ""
fi

exit 0
