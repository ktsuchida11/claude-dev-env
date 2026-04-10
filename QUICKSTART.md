# Quick Start Guide

Claude Code セキュア開発環境のセットアップガイド。
初めての方でも 5 分で環境を起動できます。

## 前提条件

| 必須 | バージョン | 確認コマンド |
|------|-----------|-------------|
| Docker Desktop | 4.x 以上 | `docker --version` |
| VS Code | 最新 | `code --version` |
| Dev Containers 拡張 | - | VS Code 拡張マーケットで「Dev Containers」をインストール |
| Claude Pro/Max アカウント<br>**または** Anthropic API Key | - | Claude OAuth の場合はアカウントのみでOK |

**推奨（オプション）:**
- GitHub Personal Access Token（`gh` CLI 連携用）

---

## Step 0: ホスト Mac のセキュリティ設定（推奨）

DevContainer を構築する Mac 自体のセキュリティも重要です。
1コマンドで Claude Code のグローバルセキュリティ設定 + サプライチェーン対策を適用できます。

```bash
bash mac_security_check/setup.sh
```

詳細は [`mac_security_check/COMPLETE-SETUP-GUIDE.md`](mac_security_check/COMPLETE-SETUP-GUIDE.md) を参照。

---

## Step 1: 環境準備

```bash
# リポジトリをクローン
git clone <repository-url>
cd claude-dev-env

# 環境変数ファイルをコピー
cp .env.example .env
```

`.env` を編集して以下を設定:

| 変数 | 必須 | 説明 |
|------|------|------|
| `GITHUB_TOKEN` | 推奨 | GitHub CLI (`gh`) で PR 作成・Issue 管理に使用 |
| `LITELLM_MASTER_KEY` | LiteLLM 利用時 | LiteLLM プロキシの認証キー（任意の文字列） |
| `OPENAI_API_KEY` | LiteLLM 利用時 | OpenAI モデルを使う場合 |
| `ANTHROPIC_API_KEY` | LiteLLM 利用時 | LiteLLM 経由で Anthropic を使う場合 |
| `ENABLE_FIREWALL` | - | `false` でファイアウォール無効化（デバッグ用） |

> Claude Pro/Max の OAuth 接続のみを使う場合、API Key の設定は不要です。
> コンテナ起動後に `claude` コマンドで OAuth ログインします。

---

## Step 2: 構成を選ぶ

```
Claude OAuth（Pro/Max）のみ使う？
│
├─ Yes → docker-compose-without-litellm.yml
│         （シンプル構成、API Key 不要）
│
└─ No（OpenAI 等も使いたい）
   │
   ├─ LangFuse でトレーシングする？
   │  │
   │  ├─ Yes → docker-compose.yml + docker-compose.langfuse.yml
   │  │         （LiteLLM + LangFuse 接続）
   │  │
   │  └─ No  → docker-compose.yml
   │            （LiteLLM のみ）
   └─
```

---

## Step 3: 起動

選んだ構成に応じてコマンドを実行:

```bash
# パターン A: Claude OAuth のみ（推奨・最もシンプル）
docker compose -f docker-compose-without-litellm.yml up -d

# パターン B: LiteLLM 付き
docker compose up -d

# パターン C: LiteLLM + LangFuse
docker compose -f docker-compose.yml -f docker-compose.langfuse.yml up -d
```

VS Code で **「Reopen in Container」** を選択（コマンドパレット: `Ctrl+Shift+P` → `Dev Containers: Reopen in Container`）。

---

## Step 4: 動作確認

コンテナ内のターミナルで:

```bash
# Claude Code の確認
claude --version

# OAuth ログイン（初回のみ）
claude

# セキュリティテスト（全 PASS を確認）
bash /workspace/.claude/tests/security-test.sh

# Hook テスト
bash /workspace/.claude/tests/hook-test.sh
```

---

## 最初のプロジェクトを作る

### Node.js プロジェクト

```bash
cd /workspace
mkdir my-app && cd my-app
npm init -y

# パッケージ追加（ignore-scripts=true が自動適用）
npm install express

# ネイティブモジュールが必要な場合
npm rebuild <package-name>
```

> `.npmrc` で `ignore-scripts=true` が設定されているため、`postinstall` スクリプトは実行されません。
> ネイティブアドオン（`bcrypt` 等）は `npm rebuild` が必要な場合があります。

### Python プロジェクト

```bash
cd /workspace
mkdir my-app && cd my-app
uv init
uv add fastapi uvicorn

# テスト実行
uv run pytest
```

> `uv.toml` の `exclude-newer` で 7 日以内の新規パッケージはブロックされます。
> 最新版が必要な場合: `uv add <pkg> --exclude-newer "$(date -u +%Y-%m-%dT%H:%M:%SZ)"`

### Java プロジェクト

```bash
cd /workspace

# Maven プロジェクト
mvn archetype:generate -DgroupId=com.example -DartifactId=my-app -DarchetypeArtifactId=maven-archetype-quickstart -DinteractiveMode=false
cd my-app
mvn compile

# または Gradle プロジェクト
gradle init --type java-application
```

> Maven は `~/.m2/settings.xml` → `/workspace/.mvn-settings.xml` のシンボリックリンクで Maven Central のみに固定されています。

### プロジェクト固有の CLAUDE.md

プロジェクトディレクトリに `CLAUDE.md` を作成すると、環境レベルの設定とマージされます:

```markdown
# CLAUDE.md - My App

## プロジェクト概要
Express + React のフルスタックアプリ

## 技術スタック
- Backend: Node.js 22 + Express
- Frontend: React 19 + TypeScript
- DB: PostgreSQL

## 開発コマンド
- `npm run dev` — 開発サーバー起動
- `npm test` — テスト実行
- `npm run lint` — ESLint
```

---

## GitHub 連携

```bash
# 認証確認（GITHUB_TOKEN が設定されていれば自動認証）
gh auth status

# リポジトリクローン
gh repo clone owner/repo

# PR 作成
gh pr create --title "feat: 新機能" --body "変更内容"
```

---

## トラブルシューティング

| 症状 | 原因 | 対処法 |
|------|------|--------|
| `claude` コマンドが見つからない | インストール未完了 | `bash /usr/local/bin/install-claude.sh` |
| MCP サーバーが動かない | 設定未反映 | Claude Code 内で `/mcp` を実行して確認 |
| 外部通信がブロックされる | ファイアウォール許可リスト外 | `.env` で `ENABLE_FIREWALL=false` に設定して再起動 |
| `npm install` でエラー | `ignore-scripts` の影響 | `npm rebuild <package>` を試す |
| pip パッケージが見つからない | クールダウン日付が古い | `bash /workspace/cooldown_management/cooldown-update.sh` |
| 権限エラー | `/workspace` 以外への書き込み | Sandbox で制限されている。`/workspace` 内で作業する |
| LiteLLM に接続できない | サービス未起動 | `docker compose ps` で litellm の状態を確認 |
| Docker ビルドが遅い | キャッシュ無効化 | `docker compose build --no-cache` で完全再ビルド |

---

## 詳細ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [README.md](README.md) | 環境の詳細な設計と構成 |
| [sandbox-security-guide.md](sandbox-security-guide.md) | 4 層セキュリティアーキテクチャ解説 |
| [workspace/CLAUDE.md](workspace/CLAUDE.md) | DevContainer 内での Claude Code 利用ガイド |
| [mac_security_check/COMPLETE-SETUP-GUIDE.md](mac_security_check/COMPLETE-SETUP-GUIDE.md) | ホスト Mac のセキュリティチェック詳細 |
