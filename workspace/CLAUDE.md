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

### ファイル削除のルール（重要）

**ファイル削除は必ずユーザーの確認を経て行うこと。** 確認プロンプトをバイパスする手段は一切使用禁止。

- **`rm` コマンド**: allow リストに含まれていないため、実行時にユーザーへの確認プロンプトが表示される。これが正しい動作。確認を得てから削除すること
- **`rm -rf /`, `rm -rf ~` 等**: 危険なターゲットは deny で完全ブロック
- **以下のバイパス手段は deny + Hooks で完全ブロック（確認プロンプトを回避できてしまうため）**:
  - `unlink` — rm の代替コマンド
  - `shred` — ファイル完全削除
  - `find -delete`, `find -exec rm` — find 経由の削除
  - `xargs rm`, `xargs shred` — パイプ経由の削除
  - `perl -e 'unlink ...'`, `python -c 'os.remove(...)'` — スクリプト言語経由の削除
  - `mv ... /dev/null` — 実質的な削除
- Hooks のバイパスを試みないこと

## 利用可能なツール

### 言語・ランタイム

| 言語                    | バージョン       | パッケージマネージャ | Linter   | Formatter   |
| ----------------------- | ---------------- | -------------------- | -------- | ----------- |
| TypeScript / JavaScript | Node.js 22       | npm                  | ESLint 9 | Prettier    |
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

- **Layer 1**: 設定ファイルによるネイティブ防御
  - `.npmrc` — `ignore-scripts=true`, `save-exact=true`, `min-release-age=7`
  - `uv.toml` — `exclude-newer`（RFC 3339 絶対日時、要定期更新）, レジストリ固定
  - `.pip.conf` — `uploaded-prior-to`（絶対日付）, レジストリ固定
  - `.mvn-settings.xml` — Maven Central固定
- **Layer 2**: Pre-Install ガード — lockfileチェック、typosquatting検知、クールダウン確認（`supply-chain-guard.sh`）
- **Layer 3**: Post-Install 監査 — `npm audit` / `pip-audit` 自動実行（`supply-chain-audit.sh`）
- **Layer 0**: ファイアウォール（最終防衛線）

### クールダウン設定（7日）

公開から7日未満のパッケージバージョンをブロック。2026年3月のaxios/LiteLLM攻撃はいずれも数時間で検知・削除されており、7日のクールダウンで防御可能。

| ツール | 設定ファイル | 設定キー | 形式 | 定期更新 |
| --- | --- | --- | --- | --- |
| npm v11.10.0+ | `.npmrc` | `min-release-age=7` | 日数（相対） | 不要 |
| uv v0.6.0+ | `uv.toml` | `exclude-newer = "<7日前の日時>"` | RFC 3339 絶対日時 | 要（`cooldown-update.sh`） |
| pip v26.0+ | `.pip.conf` | `uploaded-prior-to = 2026-04-06` | 絶対日付 | 要（`cooldown-update.sh`） |

緊急バイパス:

- npm: `npm install <pkg> --min-release-age=0`
- uv: `uv add <pkg> --exclude-newer "$(date -u +%Y-%m-%dT%H:%M:%SZ)"`
- pip: `pip install --uploaded-prior-to=$(date -Idate) <pkg>`

> **注意**: pip/uv は絶対日付のため `cooldown-update.sh` で定期更新が必要。npm のみ相対日数なので更新不要

無効化: `ENABLE_SUPPLY_CHAIN_GUARD=false`

> `ignore-scripts=true` のため、ネイティブモジュールは `npm rebuild <package>` が必要な場合がある

## Hooks（自動実行）

### 実行モデル

- **PreToolUse**: ツール実行**前**に起動。全フックが exit 0 を返した場合のみツール実行を許可。exit 2 でブロック
- **PostToolUse**: ツール実行**後**に起動。情報提供のみ（exit code に関わらずツール実行結果は変わらない）
- **Stop**: Claude Code セッション終了時に起動。バックグラウンド処理用

### フック一覧

| Hook | Type | Trigger | Exit Code | 失敗時 | 依存ツール |
|------|------|---------|-----------|--------|-----------|
| `block-dangerous.sh` | PreToolUse(Bash) | 全 Bash コマンド | 0=許可, 2=ブロック | ツール実行をブロック | jq |
| `supply-chain-guard.sh` | PreToolUse(Bash) | `npm install`, `pip install`, `uv add` 等 | 0=許可, 2=ブロック | ツール実行をブロック | jq, python3 |
| `dockerfile-cooldown-check.sh` | PostToolUse(Edit/Write) | `Dockerfile*` の編集・作成 | 常に 0 | 警告のみ | - |
| `gha-security-check.sh` | PostToolUse(Edit/Write) | `.github/workflows/*.yml` の編集・作成 | 常に 0 | 警告のみ | jq |
| `lint-on-save.sh` | PostToolUse(Edit) | `.py`, `.js`, `.ts`, `.jsx`, `.tsx` の編集 | 常に 0 | サイレント | ruff, eslint, prettier |
| `supply-chain-audit.sh` | PostToolUse(Bash) | パッケージインストールコマンド実行後 | 常に 0 | 警告のみ | npm, pip-audit |
| `langfuse_hook.py` | Stop | セッション終了 | 常に 0 | サイレント | python3, langfuse SDK |

### 各フックの詳細

- **block-dangerous.sh** — `rm -rf /`, `curl`, `wget`, `nc`, リバースシェル、base64 難読化、設定ファイル改竄、Sandbox バイパスなど 28 パターンを検出・ブロック
- **supply-chain-guard.sh** — 4 層チェック: (1) lockfile 存在確認、(2) typosquatting 検知（レーベンシュタイン距離）、(3) 悪意パターンブロック、(4) クールダウン設定確認。`ENABLE_SUPPLY_CHAIN_GUARD=false` で無効化可能
- **dockerfile-cooldown-check.sh** — Dockerfile 内の `npm install`, `pip install`, `uv pip install` にクールダウン設定が適用されているか警告
- **gha-security-check.sh** — スクリプトインジェクション、`pull_request_target` + HEAD checkout、シークレット漏洩、`write-all` 権限など 10 項目を検出
- **lint-on-save.sh** — Python: `ruff check --fix` + `ruff format`、JS/TS: `eslint --fix` + `prettier --write`（利用可能な場合のみ）
- **supply-chain-audit.sh** — `npm audit` / `pip-audit` を自動実行し、脆弱性件数をサマリ表示
- **langfuse_hook.py** — `TRACE_TO_LANGFUSE=true` 時のみ動作。会話トランスクリプトを LangFuse に送信。ファイルロックで排他制御

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
