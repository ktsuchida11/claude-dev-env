# Quick Start Guide

Claude Code セキュア開発環境のセットアップガイド。
TypeScript / Python / Java の開発に対応した、セキュリティ強化済みの DevContainer 環境です。
初めての方でも 5 分で環境を起動できます。

**対応プラットフォーム:** macOS / Amazon Linux 2023 / WSL2

## 前提条件

| 必須 | バージョン | 確認コマンド |
|------|-----------|-------------|
| Docker Desktop | 4.x 以上 | `docker --version` |
| VS Code | 最新 | `code --version` |
| Dev Containers 拡張 | - | VS Code 拡張マーケットで「Dev Containers」をインストール |
| Claude Pro/Max アカウント<br>**または** Anthropic API Key | - | Claude OAuth の場合はアカウントのみでOK |
| jq | 1.6 以上 | `jq --version` |

> **jq のインストール:**
> - macOS: `brew install jq`
> - Amazon Linux 2023: `sudo dnf install -y jq`
> - Ubuntu/WSL2: `sudo apt install jq`
>
> Hooks（`block-dangerous.sh` 等）の動作に必要です。

**ホストでサプライチェーン対策（Step 2）も行う場合の前提:**

| ツール | 前提バージョン | 確認コマンド | インストール |
|--------|---------------|-------------|-------------|
| npm | 11.10.0 以上 | `npm --version` | `npm install -g npm@latest` |
| pip | 26.0 以上 | `pip --version` | `pip install --upgrade pip` |
| uv | 0.9.17 以上 | `uv --version` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

> バージョンが古い場合、クールダウン設定（`min-release-age`, `exclude-newer`, `uploaded-prior-to`）が利用できません。
> 詳細は [`cooldown_management/local-cooldown-setup.sh`](cooldown_management/local-cooldown-setup.sh) を参照。

<details>
<summary>Amazon Linux 2023 追加前提条件（クリックで展開）</summary>

| ツール | 用途 | インストール |
|--------|------|-------------|
| AWS CLI v2 | Secrets Manager 連携 | [公式ガイド](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| python3 | サプライチェーンガード | `sudo dnf install -y python3` |
| git | バージョン管理 | `sudo dnf install -y git` |

> **秘密鍵管理:** AL2023 では AWS Secrets Manager を使用（IAM ロールで制御）。
> 詳細は [`linux_security_check/LINUX-SETUP-GUIDE.md`](linux_security_check/LINUX-SETUP-GUIDE.md) を参照。

</details>

**推奨（オプション）:**
- GitHub Personal Access Token（`gh` CLI 連携用）

---

## Step 1: リポジトリ取得

```bash
# リポジトリをクローン
git clone <repository-url>
cd claude-dev-env
```

---

## Step 2: ホストセキュリティ設定（推奨）

DevContainer を構築するホスト自体のセキュリティも重要です。
1コマンドで Claude Code のグローバルセキュリティ設定 + サプライチェーン対策を適用できます。
OS は自動検出されます。

```bash
# macOS / Linux 共通（OS 自動検出）
bash host_security/setup.sh

# 全自動（確認なし）
bash host_security/setup.sh --yes

# Linux で IOC フィードをスキップする場合（ネットワーク制限環境）
bash host_security/setup.sh --skip-ioc
```

> npm / pip / uv のバージョンが前提条件を満たしているか事前に確認してください。
> - macOS: [`mac_security_check/COMPLETE-SETUP-GUIDE.md`](mac_security_check/COMPLETE-SETUP-GUIDE.md)
> - Linux: [`linux_security_check/LINUX-SETUP-GUIDE.md`](linux_security_check/LINUX-SETUP-GUIDE.md)

---

## Step 3: 環境変数の設定

```bash
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

### .env の暗号化（推奨）

API Key などの機密情報を平文で保存するのはリスクがあります。
SOPS + age で暗号化し、秘密鍵は安全なストレージに格納することで、
リポジトリ経由の漏洩とファイルシステム上の平文露出を同時に防ぎます。

| プラットフォーム | 秘密鍵の格納先 | 特徴 |
|----------------|--------------|------|
| macOS | OS Keychain | ユーザーパスワードで保護 |
| Amazon Linux 2023 | **AWS Secrets Manager（推奨）** | IAM ロールで細粒度制御、CloudTrail で監査可能 |
| WSL2 / Ubuntu | secret-tool (libsecret) | D-Bus ベースのキーリング |
| フォールバック | `~/.config/age/key.txt` (権限 600) | 上記が利用できない場合の最終手段 |

> **Linux (AL2023) の場合:** AWS Secrets Manager の利用を推奨します。
> IAM ロールで特定のシークレットのみ読み取り可能に制限でき、
> アクセスログも CloudTrail で自動記録されるため、macOS Keychain と同等以上のセキュリティです。
> 詳細は [`linux_security_check/LINUX-SETUP-GUIDE.md`](linux_security_check/LINUX-SETUP-GUIDE.md#aws-secrets-manager推奨) を参照。

```bash
# 前提: sops と age のインストール
brew install sops age                   # macOS
# AL2023: GitHub Releases からダウンロード（LINUX-SETUP-GUIDE.md 参照）
# Ubuntu: sudo apt install age（sops は GitHub Releases から）

# 初回セットアップ（鍵生成 → Keychain/Secrets Manager 格納 → .env 暗号化）
bash scripts/setup-env-encryption.sh
```

暗号化後は `.env.enc`（暗号化済み）を git にコミットし、平文の `.env` は削除します。
DevContainer 起動時に Keychain の秘密鍵で自動復号されます。

詳細は [`SECURITY-GUIDE.md` の .env 暗号化セクション](SECURITY-GUIDE.md#env-暗号化多層防御) を参照。

---

## Step 4: 構成を選ぶ

```
LangFuse でトレーシングする？（Claude Code のやりとりを記録・分析）
│
├─ Yes
│  │
│  ├─ OpenAI 等も使う？
│  │  │
│  │  ├─ Yes → docker-compose.yml + docker-compose.langfuse.yml
│  │  │         （LiteLLM + LangFuse）
│  │  │
│  │  └─ No  → docker-compose-without-litellm.yml + docker-compose.langfuse.yml
│  │            （Claude OAuth + LangFuse）
│  └─
│
└─ No
   │
   ├─ OpenAI 等も使う？
   │  │
   │  ├─ Yes → docker-compose.yml
   │  │         （LiteLLM のみ）
   │  │
   │  └─ No  → docker-compose-without-litellm.yml
   │            （最もシンプル、API Key 不要）
   └─
```

> **LangFuse**: Claude Code とのやりとり（プロンプト・レスポンス）をトレースし、
> コスト・品質の分析に活用できます。Claude OAuth のみの構成でも利用可能です。

---

## Step 5: 起動

選んだ構成に応じてコマンドを実行:

```bash
# .env 暗号化を使う場合（推奨）— Keychain から鍵を取得して起動
bash scripts/start-devcontainer.sh                    # LiteLLM 付き
bash scripts/start-devcontainer.sh --without-litellm  # Claude OAuth のみ

# 直接起動する場合
# パターン A: Claude OAuth のみ（最もシンプル）
docker compose -f docker-compose-without-litellm.yml up -d

# パターン B: LiteLLM 付き
docker compose up -d

# パターン C: LiteLLM + LangFuse
docker compose -f docker-compose.yml -f docker-compose.langfuse.yml up -d

# パターン D: Claude OAuth + LangFuse（LiteLLM なし）
docker compose -f docker-compose-without-litellm.yml -f docker-compose.langfuse.yml up -d
```

VS Code で **「Reopen in Container」** を選択（コマンドパレット: `Ctrl+Shift+P` → `Dev Containers: Reopen in Container`）。

---

## Step 6: 動作確認

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

### テストで FAIL が出た場合

<details>
<summary>よくある FAIL と対処法（クリックで展開）</summary>

| FAIL メッセージ | 原因 | 対処法 |
|----------------|------|--------|
| `iptables OUTPUT デフォルトポリシーが DROP/REJECT でない` | ファイアウォール初期化失敗 | `sudo /usr/local/bin/init-firewall.sh` を手動実行。`ENABLE_FIREWALL=false` なら SKIP になるのが正常 |
| `ipset allowed-domains が空` | DNS 解決に失敗 | コンテナのネットワーク接続を確認。`docker compose restart` で再試行 |
| `外部通信ブロック: example.com に接続できてしまった` | ファイアウォールルール未適用 | `sudo iptables -L OUTPUT -n` で現在のルールを確認。`NET_ADMIN` capability が `docker-compose.yml` にあるか確認 |
| `/workspace への書き込み: 拒否された` | ボリューム権限不一致 | `docker compose down -v && docker compose up -d` でボリューム再作成 |
| `settings.json 保護: sandbox.denyWrite に含まれていない` | settings.json の構造不正 | `jq . /workspace/.claude/settings.json` で JSON バリデーション |
| `.npmrc: ignore-scripts が設定されていない` | .npmrc 未配置 | `/workspace/.npmrc` が存在するか確認。なければ Dockerfile のビルドをやり直す |
| `.pip.conf: index-url が正しくない` | .pip.conf 未配置またはシンボリックリンク切れ | `ls -la ~/.config/pip/pip.conf` でリンク先を確認 |
| `--dangerously-skip-permissions: 無効化されていない` | settings.json の設定不足 | `disableBypassPermissionsMode` が `"disable"` に設定されているか確認 |
| `Hook ファイルが見つからない` | Hooks 未コピー | `/workspace/.claude/hooks/` にファイルがあるか確認。`ls /workspace/.claude/hooks/` |

テストの詳細は [`workspace/CLAUDE.md`](workspace/CLAUDE.md) のセキュリティテストセクションを参照。

</details>

---

## 最初のプロジェクトを作る

### Node.js プロジェクト

```bash
cd /workspace
mkdir my-app && cd my-app
npm init -y

# パッケージ追加（サプライチェーン対策が自動適用）
npm install express

# ネイティブモジュールが必要な場合
npm rebuild <package-name>
```

> **サプライチェーン対策（`.npmrc` で自動適用）:**
> - `ignore-scripts=true` — `postinstall` 等のスクリプトを無効化。ネイティブアドオン（`bcrypt` 等）は `npm rebuild <package>` が必要
> - `min-release-age=7` — 公開から 7 日未満のパッケージバージョンをブロック（npm 11.10.0+）。緊急時は `npm install <pkg> --min-release-age=0` でバイパス
> - `save-exact=true` — バージョンを固定（`^` なし）
> - `audit=true` — インストール時に脆弱性チェック

### Python プロジェクト

```bash
cd /workspace
mkdir my-app && cd my-app
uv init
uv add fastapi uvicorn

# テスト実行
uv run pytest
```

> **サプライチェーン対策（自動適用）:**
> - `uv.toml` の `exclude-newer = "7 days"` — 公開 7 日以内の新規パッケージをブロック（uv 0.9.17+）。緊急時: `uv add <pkg> --exclude-newer "0 days"`
> - `.pip.conf` の `uploaded-prior-to` — pip 向けの同等設定（絶対日付のため `cooldown-update.sh` で定期更新が必要）
> - レジストリは PyPI に固定済み（`no-extra-index-url = true`）

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
- Backend: Node.js 24 + Express
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
| [SECURITY-GUIDE.md](SECURITY-GUIDE.md) | 4 層セキュリティアーキテクチャ解説 |
| [workspace/CLAUDE.md](workspace/CLAUDE.md) | DevContainer 内での Claude Code 利用ガイド |
| [mac_security_check/COMPLETE-SETUP-GUIDE.md](mac_security_check/COMPLETE-SETUP-GUIDE.md) | ホスト Mac のセキュリティチェック詳細 |
| [linux_security_check/LINUX-SETUP-GUIDE.md](linux_security_check/LINUX-SETUP-GUIDE.md) | Linux (AL2023/WSL2) セキュリティ設定ガイド |
