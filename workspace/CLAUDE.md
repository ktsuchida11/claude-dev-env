# CLAUDE.md - Claude Code セキュア開発環境

## 環境概要

このDev Container環境は、Claude Codeをセキュアに利用するための隔離された開発環境。
ホストPCのファイルシステム・ネットワークから構造的に分離されている。

## 環境の制約（重要）

### ファイルシステム

- **作業ディレクトリ**: `/workspace` — すべてのプロジェクトはここに配置する
- **書き込み可能**: `/workspace`、パッケージキャッシュ (`~/.npm`, `~/.cache`, `~/.m2/repository`, `~/.gradle`)、`/tmp`
- **読み取り不可**: `~/.ssh`, `~/.aws`, `~/.gnupg`, `.env`, `.env.*`
- **設定ファイル変更不可**: `settings.json`, `.claude.json`, `.mcp.json` は直接編集しないこと

### ネットワーク

- ファイアウォール（iptables）で外部通信を制限している
- **許可**: GitHub, npm, PyPI, Anthropic API, OpenAI API, Context7
- **ブロック**: 上記以外のすべての外部通信
- `curl`, `wget` は settings.json で deny 設定済み
- ローカルポートへのバインド（localhost）は許可。Unixソケットも制限なし

### コマンド制限

- `curl`, `wget`, `ssh`, `scp`, `nc` などネットワーク系コマンドは使用不可
- `sudo`, `su` は使用不可（非rootユーザー `node` で動作）
- `rm -rf /`, `rm -rf ~` など破壊的コマンドはHooksでもブロック
- `--dangerously-skip-permissions` は無効化済み

## 利用可能なツール

### 言語・ランタイム

| 言語                    | バージョン       | パッケージマネージャ | Linter   | Formatter   |
| ----------------------- | ---------------- | -------------------- | -------- | ----------- |
| TypeScript / JavaScript | Node.js 20       | npm                  | ESLint 9 | Prettier    |
| Python                  | 3.12             | uv                   | Ruff     | Ruff format |
| Java                    | JDK 21 (Temurin) | Maven / Gradle       | -        | -           |

### MCP サーバー（利用可能）

- **Context7** — ライブラリのドキュメント・コード例をリアルタイム検索
- **Playwright** — ローカル Chromium によるブラウザ自動化・スクリーンショット
- **Serena** — LSP ベースのセマンティックコード解析（定義ジャンプ・参照検索）
- **Sequential Thinking** — 複雑な設計・問題分解の段階的思考支援

### CLI ツール

- `gh` (GitHub CLI) — PR作成・Issue管理・リポジトリ操作
- `git` + `git-delta` — バージョン管理（差分表示が見やすい）
- `jq` — JSON処理
- `fzf` — ファジー検索

## 開発ワークフロー

### 新しいプロジェクトを始める

```bash
cd /workspace
mkdir my-project && cd my-project
git init
```

プロジェクト固有のCLAUDE.mdは `/workspace/my-project/CLAUDE.md` に作成する。
このファイル（環境レベル）の設定と、プロジェクトレベルのCLAUDE.mdは自動でマージされる。

### GitHub連携

```bash
gh auth status          # 認証確認（GITHUB_TOKEN で自動認証済み）
gh repo clone owner/repo  # リポジトリクローン
gh pr create            # PR作成
```

### LiteLLM経由で別モデルを使う

```bash
# デフォルト: Anthropic API 直接接続
claude

# OpenAI モデル（LiteLLM経由）
ANTHROPIC_MODEL=gpt-4o claude-litellm
```

## コーディング規約

### 共通

- コミットメッセージは日本語可。Conventional Commits 形式を推奨
- テストを書いてから実装する（TDD推奨）
- 1PRあたりの変更は小さく保つ（300行以内目安）
- PR作成前に lint + format + type check を実行する
- 作業を始める前に必ず作業計画を立て作業ごとに完了定義を行う
- 作業は必ずブランチを作成して対応する
- 作業タスクが大きい場合は分割してISSUEに登録して作業を分ける

### TypeScript

```bash
npm run lint        # ESLint
npm run format      # Prettier
npm run typecheck   # tsc --noEmit
```

### Python

```bash
uv run ruff check .        # Linter
uv run ruff format .       # Formatter
uv run mypy .              # 型チェック
uv run pytest              # テスト
```

## サプライチェーン攻撃対策

パッケージインストール時の多層防御（デフォルト有効）:

- **Layer 1**: `.npmrc`（ignore-scripts）、`.pip.conf`（レジストリ固定）、`.mvn-settings.xml`（Central固定）
- **Layer 2**: Pre-Install ガード — lockfileチェック、typosquatting検知（`supply-chain-guard.sh`）
- **Layer 3**: Post-Install 監査 — `npm audit` / `pip-audit` 自動実行（`supply-chain-audit.sh`）
- **Layer 0**: ファイアウォール（最終防衛線）

無効化: `ENABLE_SUPPLY_CHAIN_GUARD=false`

> `ignore-scripts=true` のため、ネイティブモジュールは `npm rebuild <package>` が必要な場合がある

## Hooks（自動実行）

- **PreToolUse (Bash)**: 危険コマンドの検出・ブロック（`.claude/hooks/block-dangerous.sh`）
- **PreToolUse (Bash)**: サプライチェーンガード（`.claude/hooks/supply-chain-guard.sh`）— パッケージインストール時のみ
- **PostToolUse (Edit)**: ファイル編集後に自動 lint + format（`.claude/hooks/lint-on-save.sh`）
- **PostToolUse (Bash)**: サプライチェーン監査（`.claude/hooks/supply-chain-audit.sh`）— パッケージインストール後のみ
- **Stop**: LangFuse トレーシング（`.claude/hooks/langfuse_hook.py`）— `TRACE_TO_LANGFUSE=true` 時のみ動作

## セキュリティテスト

セキュリティ対策の動作確認:

```bash
# 自動テスト（環境レベル: ファイアウォール、FS制限、設定整合性）
bash /workspace/.claude/tests/security-test.sh

# Hook 単体テスト（block-dangerous.sh, supply-chain-guard.sh）
bash /workspace/.claude/tests/hook-test.sh
```

手動テスト（Claude Code セッション内で確認が必要な項目）のチェックリスト:
`/workspace/.claude/tests/SECURITY-CHECKLIST.md`

## トラブルシューティング

- **MCP サーバーが動かない**: Claude Code内で `/mcp` を実行して4サーバーが表示されるか確認
- **外部通信がブロックされる**: ファイアウォールの許可リスト外。`ENABLE_FIREWALL=false` で一時無効化して切り分け
- **権限エラー**: `/workspace` 以外への書き込みはSandboxでブロックされる
- **設定がおかしい**: `/doctor` で環境診断、`/status` で設定確認
