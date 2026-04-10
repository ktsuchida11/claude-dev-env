# Claude Code セキュア開発環境（DevContainer）

Claude Code を Docker コンテナ内で安全に利用するための開発環境。デフォルトは Claude 認証（OAuth）による直接接続で、LiteLLM プロキシ経由で OpenAI 等の別プロバイダーにも切り替え可能。GitHub によるソースコード管理を統合。

> **すぐに始めたい方は [QUICKSTART.md](QUICKSTART.md) を参照してください。**

## コンセプト

この環境は以下の 2 つの観点でセキュリティ対策を行います:

1. **ホスト Mac の保護** — DevContainer を構築する環境自体のセキュリティ（`mac_security_check/`）
2. **DevContainer 内の保護** — コンテナ内で Claude Code を安全に利用するための多層防御

```
ホスト Mac                          DevContainer
┌─────────────────────┐            ┌──────────────────────────┐
│ mac_security_check/  │            │ L7: コンテナ隔離          │
│  ・グローバル deny    │  docker    │ L6: bypass 無効化        │
│  ・クールダウン設定   │  compose   │ L5: Sandbox + Permission │
│  ・IOC 定期チェック   │ ─────────▶ │ L4: Post-install 監査    │
│  ・脅威インテリジェンス│            │ L3: パッケージマネージャ設定│
│                     │            │ L2: Pre-install ガード    │
│ cooldown_management/ │            │ L1: 危険コマンドブロック   │
│  ・日付自動更新      │            │ L0: ファイアウォール       │
└─────────────────────┘            └──────────────────────────┘
```

## なぜ Dev Container 構成なのか

### Claude Code を LiteLLM 経由で使う際の課題

Claude Code は本来 Anthropic の API に直接接続して動作する。LiteLLM プロキシを間に挟んで OpenAI 等の別プロバイダーを使う場合、以下の課題がある:

1. **ファイルアクセスの制御が困難**: Claude Code はファイル操作やコマンド実行などの強力な権限を持つ。ホスト環境で直接実行すると、`~/.ssh`、`~/.aws`、他のリポジトリなどホスト上の機密ファイルにアクセスできてしまう
2. **ネットワークの制御が困難**: 同様に、ホスト環境では意図しない外部通信が発生した場合に検知・制御が難しい
3. **API キーの管理リスク**: `OPENAI_API_KEY` などの機密情報をローカル環境に直接置くと、他のプロセスやツールからアクセスされる可能性がある
4. **環境の再現性**: LiteLLM のバージョン、Node.js のバージョン、Claude Code のバージョンなど、チームで揃える必要のある依存関係が多い

### Dev Container が解決すること

- **ファイルシステムの隔離**: Claude Code がアクセスできるファイルをコンテナ内（`/workspace`）に限定し、ホスト上の機密ファイルや他のリポジトリへのアクセスを防ぐ
- **API キーの隔離**: API キーはコンテナ内にのみ存在し、ホスト環境から分離される
- **ネットワーク制御**: ファイアウォール (`init-firewall.sh`) で外部通信先を明示的にホワイトリスト管理できる
- **再現可能な環境**: Dockerfile と docker-compose.yml で環境が完全に定義され、チームの誰でも同じ環境を再現できる
- **VS Code との統合**: Dev Containers 拡張により、VS Code のエディタ機能（拡張、設定、デバッガ）をコンテナ内で透過的に利用できる

## ファイアウォール (init-firewall.sh) の役割

### なぜファイアウォールが必要か

Claude Code はファイル操作やシェルコマンドの実行など強力な権限を持つ。本環境では `--dangerously-skip-permissions` モードは `disableBypassPermissionsMode: "disable"` で無効化済みだが、Sandbox の `autoAllowBashIfSandboxed: true` により隔離環境内では自動承認される。以下のリスクに対する多層防御の一環としてファイアウォールが機能する:

- 悪意のあるプロンプト注入により、意図しないコマンドが実行される可能性
- コード生成時に予期しない外部サービスへのデータ送信が行われる可能性

ファイアウォールはこれらのリスクに対する**OSレベルの防御ライン**として機能する。

### 仕組み

`init-firewall.sh` は `iptables`/`ip6tables` と `ipset`（IPv4 + IPv6 dual-stack）を使い、dev コンテナからの外部通信を以下のドメインのみに制限する:

| 許可ドメイン | 用途 |
| --- | --- |
| `registry.npmjs.org`, `cdn.npmjs.org` | npm パッケージのインストール |
| `registry.yarnpkg.com` | Yarn パッケージのインストール |
| `api.github.com` + GitHub IP レンジ | git 操作、GitHub CLI |
| `raw.githubusercontent.com`, `codeload.githubusercontent.com`, `objects.githubusercontent.com`, `user-images.githubusercontent.com` | GitHub コンテンツ取得 |
| `api.anthropic.com`, `claude.ai` | Claude Code の API 通信・OAuth 認証 |
| `api.openai.com`, `openaipublic.blob.core.windows.net` | OpenAI API (Embedding 等) |
| Google CDN CIDR レンジ (142.250.0.0/15 等) + IPv6 | Google サービス全般（IP ローテーション対策） |
| `context7.com`, `mcp.context7.com`, `api.context7.com` | Context7 MCP サーバー |
| `repo1.maven.org` | Maven Central (Java 依存関係) |
| `plugins.gradle.org`, `services.gradle.org` | Gradle プラグイン・ディストリビューション |
| `pypi.org`, `files.pythonhosted.org` | PyPI (Python パッケージ) |
| `marketplace.visualstudio.com`, `vscode.blob.core.windows.net`, `update.code.visualstudio.com` | VS Code 拡張のインストール・更新 |
| `cloud.langfuse.com`, `us.cloud.langfuse.com` | LangFuse トレーシング（オプション） |
| Docker 内部ネットワーク (ホストネットワーク + 172.16.0.0/12) | litellm コンテナ等との通信 |

上記以外の外部通信は **すべてブロック** される。これにより、万が一不正なコマンドが実行されても、データが外部に送信されることを防ぐ。

> **テレメトリについて**: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` を設定済みのため、sentry.io / statsig.com 等のテレメトリ通信は発生せず、ファイアウォールの許可リストにも含めていない。

### LiteLLM との関係

ファイアウォールは Docker 内部ネットワークの通信は許可するため、dev コンテナから litellm コンテナ (`http://litellm:4000`) への通信は正常に動作する。外部の LLM API への通信は litellm コンテナが担当するため、dev コンテナのファイアウォールの影響を受けない。

```text
dev コンテナ                        litellm コンテナ
┌──────────────────────┐           ┌──────────────────────┐
│ ファイアウォール有効    │           │ ファイアウォールなし    │
│                      │           │                      │
│ claude (デフォルト) ──────────────────────────────────▶ Anthropic API
│                      │           │                 (OAuth 直接接続)
│ claude-litellm ──────────────▶ LiteLLM Proxy ──▶ OpenAI API
│                      │  Docker   │
│ 外部通信: ブロック     │  内部NW   │
└──────────────────────┘           └──────────────────────┘
```

> **注意**: ファイアウォールの実行には `NET_ADMIN` ケーパビリティが必要です。`docker-compose.yml` で `cap_add: [NET_ADMIN, NET_RAW]` を設定しています。

### ファイアウォールの無効化

環境変数 `ENABLE_FIREWALL=false` を設定すると、ファイアウォールを無効化できる。以下のケースで利用する:

- **プロキシ環境での切り分け**: プロキシ環境で通信エラーが発生した場合に、ファイアウォールが原因かプロキシ設定が原因かを切り分ける
- **許可リスト外のサービス利用**: ファイアウォールの許可ドメイン以外の外部サービスに一時的にアクセスが必要な場合

`.env` に以下を追加:

```env
ENABLE_FIREWALL=false
```

または、コンテナ起動時に一時的に無効化:

```bash
ENABLE_FIREWALL=false docker compose up -d
```

> **注意**: ファイアウォールを無効化すると、dev コンテナから任意の外部通信が可能になる。切り分け完了後は `ENABLE_FIREWALL=true`（デフォルト）に戻すことを推奨する。

## 参照元・ベース構成

Dev Container の構成は Anthropic 公式リポジトリをベースにしています。

| リソース | URL |
| --- | --- |
| Claude Code DevContainer (公式) | <https://github.com/anthropics/claude-code/tree/main/.devcontainer> |
| Claude Code DevContainer ドキュメント | <https://docs.anthropic.com/en/docs/claude-code/devcontainer> |
| DevContainer Feature (既存コンテナへの追加用) | <https://github.com/anthropics/devcontainer-features> |
| LiteLLM ドキュメント | <https://docs.litellm.ai/> |

## プロジェクト構成

```text
claude-dev-env/
├── .devcontainer/                     # DevContainer ビルド設定
│   ├── Dockerfile                     # 開発コンテナ (Node 22 + JDK 21 + Python + Claude Code + MCP)
│   ├── devcontainer.json              # VS Code Dev Containers 設定
│   ├── init-firewall.sh               # 外部通信制限 (iptables + ipset, IPv4/IPv6 dual-stack)
│   ├── install-claude.sh              # Claude Code CLI インストール
│   ├── mcp-servers.json               # MCP サーバー設定テンプレート
│   └── setup-mcp.sh                   # MCP 設定マージスクリプト（冪等）
├── litellm/                           # LiteLLM プロキシ（オプション）
│   ├── Dockerfile
│   └── config.yaml                    # モデル設定 (OpenAI / Anthropic)
├── mac_security_check/                # ホスト Mac セキュリティツール群
│   ├── setup.sh                       # 統合セットアップ（1コマンドで全設定）
│   ├── global-claude-setup.sh         # Claude Code グローバル deny ルール適用
│   ├── claude-code-security-audit.sh  # Claude Code 設定の監査・レポート
│   ├── mac-supply-chain-check-v2.sh   # 週次サプライチェーンチェック（8項目）
│   ├── mac-supply-chain-check-v3-additions.sh  # 追加チェック（9項目）
│   ├── threat-intel-updater.sh        # IOC データベース日次更新
│   ├── block-sensitive-files.py       # 機密ファイルアクセスブロック Hook
│   ├── com.zui.security-check.plist   # launchd: 週次チェック（月曜 9:00）
│   ├── com.zui.threat-intel-update.plist  # launchd: 日次 IOC 更新（毎日 7:00）
│   └── COMPLETE-SETUP-GUIDE.md        # 詳細セットアップガイド
├── cooldown_management/               # クールダウン日付管理
│   ├── cooldown-update.sh             # pip.conf / uv.toml の絶対日付を自動更新
│   └── local-cooldown-setup.sh        # ローカル PC 用クールダウン初期設定
├── scripts/                           # 開発・運用ツール
│   └── sync-hooks.sh                  # workspace/.claude/ → .claude/ の同期
├── workspace/                         # コンテナ内 /workspace にマウント
│   ├── .claude/                       # Claude Code コンテナ内設定
│   │   ├── settings.json              # 権限・Sandbox・Hook 設定
│   │   ├── hooks/                     # セキュリティ Hook スクリプト群
│   │   └── tests/                     # セキュリティ自動テスト
│   ├── .npmrc                         # npm サプライチェーン設定
│   ├── .pip.conf                      # pip クールダウン設定
│   ├── .mvn-settings.xml              # Maven Central 固定
│   ├── uv.toml                        # uv クールダウン設定
│   ├── CLAUDE.md                      # コンテナ内 Claude Code 利用ガイド
│   └── mcp.json                       # MCP サーバー定義
├── docker-compose.yml                 # メイン構成 (dev + litellm)
├── docker-compose-without-litellm.yml # Claude OAuth のみ構成
├── docker-compose.langfuse.yml        # LangFuse 接続オーバーライド
├── QUICKSTART.md                      # クイックスタートガイド
├── sandbox-security-guide.md          # セキュリティアーキテクチャ解説
├── .env.example                       # 環境変数テンプレート
└── .gitignore
```

> **注意**: `workspace/` 内のプロジェクトコードは git 管理対象外です。プロジェクトは独自の git リポジトリで管理してください。
> セキュリティ設定ファイル（`.claude/`, `.npmrc`, `.pip.conf` 等）のみ追跡しています。

## コンテナ構成

| コマンド | 起動するサービス |
| --- | --- |
| `docker compose up -d` | dev, litellm |
| `docker compose -f docker-compose-without-litellm.yml up -d` | dev のみ（LiteLLM なし、Claude OAuth 直接接続のみ） |
| `docker compose -f docker-compose.yml -f docker-compose.langfuse.yml up -d` | dev, litellm（+ LangFuse ネットワーク接続） |

> **LangFuse 接続の簡略化**: `.env` に `COMPOSE_FILE=docker-compose.yml:docker-compose.langfuse.yml` を設定すれば、`docker compose up -d` だけで LangFuse ネットワークにも接続される。LangFuse が未起動の場合はこの行をコメントアウトすること。
>
> **LiteLLM なし構成**: Claude OAuth 認証（Pro/Max サブスクリプション）のみで利用する場合、`docker-compose-without-litellm.yml` を使えば LiteLLM コンテナなしで起動できる。

### dev コンテナ（開発用）

| 項目 | 内容 |
| --- | --- |
| ベースイメージ | `node:22` |
| シェル | zsh (Powerlevel10k テーマ) |
| Claude Code | `@anthropic-ai/claude-code@latest` |
| 開発ツール | git, vim, nano, jq, fzf, ripgrep, gh (GitHub CLI), git-delta |
| Docker | Docker CLI + Docker Compose plugin（ホストの Docker ソケットをマウント） |
| データベース | postgresql-client |
| Python | Python 3.12, uv, langfuse, pip-audit |
| Java | Eclipse Temurin JDK 21, Maven 3.9, Gradle 8.12（`ENABLE_JAVA=false` で無効化可） |
| MCP サーバー | Context7 (ドキュメント検索), Playwright (ブラウザ自動化), Serena (セマンティックコード解析), Sequential Thinking (段階的思考) |
| 言語サーバー | typescript-language-server, pyright, jdtls (Serena 用) |
| ユーザー | `node` (非 root) |
| ファイアウォール | 外部通信を許可ドメインのみに制限 (npm, GitHub, Anthropic API, VS Code 等) |

VS Code 拡張（自動インストール）:

- `anthropic.claude-code` - Claude Code
- `dbaeumer.vscode-eslint` - ESLint
- `esbenp.prettier-vscode` - Prettier
- `eamodio.gitlens` - GitLens
- `ms-python.python` - Python
- `ms-python.debugpy` - Python デバッガ
- `ms-vscode.js-debug` - JavaScript デバッガ
- `vscjava.vscode-java-pack` - Java Extension Pack (Language Support, Debugger, Test Runner, Maven, Gradle)
- `vmware.vscode-spring-boot` - Spring Boot Tools
- `vmware.vscode-boot-dev-pack` - Spring Boot Extension Pack

### litellm コンテナ（LLM プロキシ）

| 項目 | 内容 |
| --- | --- |
| ベースイメージ | `ghcr.io/berriai/litellm:main-latest` |
| ポート | 4000 |
| 役割 | `claude-litellm` エイリアスで利用。OpenAI / Anthropic API への変換プロキシ |

### ネットワークフロー

```text
VS Code (ホスト)
    │
    │ Remote - Containers 接続
    ▼
dev コンテナ (Claude Code + gh CLI)
    │
    ├── claude (デフォルト)
    │   └──▶ Anthropic API (直接接続 / OAuth 認証)
    │
    ├── claude-litellm (エイリアス)
    │   └──▶ litellm コンテナ (:4000) ──▶ OpenAI API (gpt-4o 等)
    │
    └── GitHub (gh CLI / git push)
```

## セットアップ

### 前提条件

#### システム要件

| 項目 | 要件 |
| --- | --- |
| **OS** | macOS 12+, Windows 10/11 (WSL2), Linux (x86_64) |
| **Docker Desktop** | v4.20 以上推奨 |
| **メモリ** | 8GB 以上推奨（Docker Desktop に 4GB 以上を割り当て） |
| **ディスク** | 空き容量 10GB 以上（ビルド後イメージ: 約 3–5GB） |

> **Java 無効化でビルドを高速化**: Java を使わないプロジェクトでは `.env` に `ENABLE_JAVA=false` を設定すると、JDK・Maven・Gradle のインストールがスキップされ、ビルド時間とイメージサイズを大幅に削減できます。

#### ソフトウェア

- **Docker Desktop** — [ダウンロード](https://www.docker.com/products/docker-desktop/)
- **VS Code** + [Dev Containers 拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

> Windows をお使いの場合は「[Windows 環境での利用](#windows-環境での利用)」セクションも参照してください。

### 1. 環境変数の設定

```bash
cp .env.example .env
```

`.env` を編集して設定（`.env.example` にコメント付きの全項目あり）:

```env
LITELLM_MASTER_KEY=sk-any-string-you-choose

# LiteLLM 経由で OpenAI モデルを使う場合のみ必要
OPENAI_API_KEY=sk-your-openai-api-key

# GitHub Personal Access Token（gh CLI 用）
# GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
```

> `LITELLM_MASTER_KEY` は LiteLLM プロキシ自体へのアクセスを保護する鍵です。外部サービスのキーではなく、自分で自由に決める文字列です。Claude 認証（OAuth）で直接接続する場合、`OPENAI_API_KEY` の設定は不要です。

### 2. コンテナのビルドと起動

```bash
cd claude_dev_env/

# ビルド & 起動
docker compose up -d --build

# 2回目以降: 起動のみ
docker compose up -d

# 起動確認
docker compose ps
```

起動が正常に完了すると、以下のような出力になります:

```
NAME                  IMAGE                         STATUS                    PORTS
claude-dev-env-dev-1      claude-dev-env-dev        Up 2 minutes (healthy)
claude-dev-env-litellm-1  claude-dev-env-litellm    Up 2 minutes (healthy)    0.0.0.0:4000->4000/tcp
```

> **確認ポイント**: 両コンテナの STATUS が `(healthy)` になっていることを確認してください。`(health: starting)` の場合はしばらく待ってから再度確認してください。LiteLLM なしの構成（`docker-compose-without-litellm.yml`）を使う場合は `dev` コンテナのみ表示されます。

### 3. 開発環境への接続

#### 方法 A: VS Code から接続（推奨）

1. コンテナが起動していることを確認（`docker compose ps` で `dev` が `running`）
2. VS Code で `claude_dev_env/` フォルダを開く
3. 左下の `><` アイコンをクリック、または `Cmd+Shift+P` → `Dev Containers: Reopen in Container`
4. VS Code がコンテナ内にリモート接続される
5. ターミナルで `claude /login` を実行し、ブラウザで Claude 認証を完了する（初回のみ）
6. ターミナルで `claude` コマンドが使える

> **注意**: `Dev Containers: Reopen in Container` が表示されない場合は、[Dev Containers 拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)がインストールされているか、Docker Desktop が起動しているかを確認してください。

#### 方法 B: コマンドラインから接続

```bash
# dev コンテナに入る
docker compose exec -it dev zsh

# MCP サーバーの設定（初回 or settings.json がない場合）
/usr/local/bin/setup-mcp.sh

# Claude にログイン（初回のみ）
claude /login

# Claude Code を使う
claude "Hello!"
```

> **注意**: `docker compose up` で直接起動した場合、`devcontainer.json` の `postStartCommand` は実行されません。MCP サーバーの設定が `/home/node/.claude/.claude.json` にない場合は、手動で `setup-mcp.sh` を実行してください。VS Code の Dev Containers 経由で接続した場合は自動で実行されます。

### 4. 停止

```bash
docker compose down
```

## モデル切り替え

### デフォルト: Claude 認証（OAuth）で直接接続

初回起動時に `claude login` で認証してください（Pro/Max サブスクリプションで利用可能）。
API キー不要・追加料金なしで Claude が使えます。

```bash
# Claude 認証で直接接続（デフォルト）
claude

# モデルを指定
ANTHROPIC_MODEL=claude-sonnet-4-6 claude
ANTHROPIC_MODEL=claude-opus-4-6 claude
```

### LiteLLM 経由: OpenAI モデルを使う

`claude-litellm` エイリアスで LiteLLM プロキシ経由の OpenAI モデルが使えます。
`.env` に `OPENAI_API_KEY` の設定が必要です。

```bash
# GPT-4o（LiteLLM 経由）
ANTHROPIC_MODEL=gpt-4o claude-litellm

# GPT-4o-mini（LiteLLM 経由）
ANTHROPIC_MODEL=gpt-4o-mini claude-litellm

# Anthropic モデル（LiteLLM 経由、API キー認証）
ANTHROPIC_MODEL=claude-sonnet claude-litellm
ANTHROPIC_MODEL=claude-opus claude-litellm
```

> LiteLLM の `config.yaml` で OpenAI (`gpt-4o`, `gpt-4o-mini`) と Anthropic (`claude-sonnet`, `claude-opus`) の両方が設定済み。Anthropic モデルを LiteLLM 経由で使う場合は `.env` に `ANTHROPIC_API_KEY` の設定が必要。

## GitHub の設定

### GitHub Personal Access Token

1. <https://github.com/settings/tokens> にアクセス
2. 「Generate new token (classic)」または「Fine-grained tokens」で新しいトークンを作成
3. 必要なスコープ: `repo`, `read:org`
4. `.env` にトークンを設定:

   ```env
   GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
   ```

5. コンテナを再起動して環境変数を反映:

   ```bash
   docker compose up -d
   ```

### gh CLI の使用

dev コンテナ内で `gh` コマンドが利用可能:

```bash
# 認証（GITHUB_TOKEN が設定されていれば自動認証）
gh auth status

# リポジトリのクローン
gh repo clone owner/repo

# Pull Request の作成
gh pr create --title "Feature: add login" --body "ログイン機能を追加"

# Issue の作成
gh issue create --title "Bug: fix crash" --label bug
```

## DevContainer の開発環境

### Claude Code の設定

| 項目 | 内容 |
| --- | --- |
| 認証方式 | OAuth（`claude /login` でブラウザ認証、Pro/Max サブスクリプション利用） |
| デフォルト接続 | Anthropic API 直接接続（LiteLLM を経由しない） |
| LiteLLM 経由 | `claude-litellm` エイリアスで OpenAI モデル利用時のみ |
| MCP サーバー | Context7, Playwright, Serena, Sequential Thinking（自動設定） |
| 権限制御 | サンドボックス `/workspace` 書き込みのみ |

### 対応プログラミング言語

| 言語 | ランタイム / SDK | Linter | Formatter | 型チェック | 言語サーバー (Serena) |
| --- | --- | --- | --- | --- | --- |
| TypeScript / JavaScript | Node.js 22 | ESLint 9 | Prettier | TypeScript (strict) | typescript-language-server |
| Python | Python 3.12 + uv | Ruff | Ruff format | MyPy | Pyright |
| Java | Eclipse Temurin JDK 21, Maven 3.9, Gradle 8.12 | - | - | - | jdtls (Eclipse JDT Language Server) |

> Java 環境は `ENABLE_JAVA=false` で無効化可能。Java を使わないプロジェクトではビルド時間を短縮できる。

### VS Code 拡張（自動インストール）

| カテゴリ | 拡張 |
| --- | --- |
| AI | Claude Code |
| JavaScript / TypeScript | ESLint, Prettier |
| Python | Python, debugpy |
| Java / Spring Boot | Java Extension Pack, Spring Boot Tools, Spring Boot Extension Pack |
| Git | GitLens |
| デバッグ | JavaScript Debugger |

## Claude Code コマンドチートシート

コンテナ内の Claude Code セッションで使えるコマンド・ショートカット一覧。

### スラッシュコマンド

#### セッション管理

| コマンド | 説明 | 使い方 |
| --- | --- | --- |
| `/compact` | コンテキストを圧縮・整理 | `/compact` または `/compact [焦点]` |
| `/plan` | 実装前に計画を立てる（実行なし） | `/plan [タスク内容]` |
| `/rewind` | コードと会話を過去の状態に戻す | `/rewind` または `Esc`×2 |
| `/branch` | セッションを分岐（独立実行） | `/branch` |
| `/fork` | `/branch` と同じ機能 | `/fork` |
| `/export` | 会話を Markdown として保存 | `/export` |

#### コード品質

| コマンド | 説明 | 使い方 |
| --- | --- | --- |
| `/review` | バグ・エラー・エッジケースを検出 | `/review` または `/review PR番号` |
| `/simplify` | コードを自動最適化（3エージェント並列） | `/simplify` または `/simplify [焦点]` |
| `/diff` | 変更内容をインタラクティブに表示 | `/diff` |

#### 自動化

| コマンド | 説明 | 使い方 |
| --- | --- | --- |
| `/batch` | 複数ファイルへの並列変更 | `/batch [変更内容]` |
| `/loop` | 定期的なタスクを自動実行 | `/loop [時間間隔] [タスク]` |

#### その他

| コマンド | 説明 | 使い方 |
| --- | --- | --- |
| `/btw` | メインタスクと並列で質問（コンテキスト汚染なし） | `/btw [質問内容]` |
| `/rc` | スマートフォンからの遠隔操作 | `/rc` または `/remote-control` |
| `/usage` | プラン利用上限とレート制限を確認 | `/usage` |
| `/cost` | 現セッションのトークン数と費用 | `/cost` |
| `/stats` | 日別使用パターン・セッション履歴 | `/stats` |
| `/skills` | 利用可能なスキル一覧を表示 | `/skills` |
| `/help` | 使用可能なコマンド全一覧を表示 | `/help` |

### キーボードショートカット

| ショートカット | 動作 |
| --- | --- |
| `Ctrl+V` | スクリーンショットを直接ペースト |
| `Ctrl+J` / `Option+Enter`（Mac） | 改行（Enter 送信回避） |
| `Ctrl+R` | 過去のプロンプト履歴を検索 |
| `Ctrl+U` | 入力中の行を全消去 |
| `Shift+Tab` | プランモードのトグル |
| `Esc`×2 | `/rewind` メニューを表示 |

### この環境固有のコマンド

| コマンド | 説明 |
| --- | --- |
| `claude` | Claude Code 起動（Anthropic API 直接接続） |
| `claude-litellm` | LiteLLM 経由で別モデルを利用 |
| `bash /workspace/.claude/tests/security-test.sh` | セキュリティ自動テスト実行 |
| `bash /workspace/.claude/tests/hook-test.sh` | Hook 単体テスト実行 |

## ワークスペース (`workspace/`)

`workspace/` ディレクトリはコンテナ内の `/workspace` にマウントされる作業領域。本リポジトリの git 管理対象外のため、プロジェクトごとに独自のリポジトリで管理する。

### セキュリティ設定ファイル

`workspace/` 直下に以下のファイルが git 管理対象として配置されている:

| ファイル | 用途 |
| --- | --- |
| `CLAUDE.md` | Claude Code の環境レベル設定（制約、ツール、ワークフロー） |
| `.claude/settings.json` | Claude Code の権限・サンドボックス設定 |
| `.claude/hooks/` | PreToolUse / PostToolUse / Stop フック（危険コマンドブロック、サプライチェーンガード、LangFuse トレーシング等） |
| `.claude/tests/` | セキュリティ自動テスト、Hook 単体テスト、手動チェックリスト |
| `.npmrc` | npm サプライチェーン対策（ignore-scripts、save-exact、min-release-age=7、レジストリ固定） |
| `uv.toml` | uv サプライチェーン対策（exclude-newer、レジストリ固定） |
| `.pip.conf` | pip サプライチェーン対策（uploaded-prior-to、PyPI のみに固定） |
| `.mvn-settings.xml` | Maven サプライチェーン対策（Maven Central のみ） |

### プロジェクトの配置

```bash
# dev コンテナ内で
cd /workspace
gh repo clone owner/my-project
cd my-project
```

プロジェクト固有の `CLAUDE.md` は各プロジェクトディレクトリに作成する。環境レベル（`/workspace/CLAUDE.md`）とプロジェクトレベルの設定は自動でマージされる。

### Docker-in-Docker

dev コンテナからホストの Docker ソケットがマウントされているため、コンテナ内で `docker` / `docker compose` コマンドが利用可能。workspace 内のプロジェクトが独自の `docker-compose.yml` を持つ場合、コンテナ内から直接起動できる。

## サプライチェーン攻撃対策

パッケージマネージャ（npm / pip / Maven）を通じた[サプライチェーン攻撃](https://en.wikipedia.org/wiki/Supply_chain_attack)に対する多層防御を実装している。

### 3層防御アーキテクチャ

```text
┌─────────────────────────────────────────────────┐
│  Layer 1: パッケージマネージャ設定（常時・透明）    │
│  .npmrc / uv.toml / .pip.conf / .mvn-settings   │
│  → クールダウン, ignore-scripts, レジストリ固定    │
├─────────────────────────────────────────────────┤
│  Layer 2: Pre-Install ガード（Hook）              │
│  supply-chain-guard.sh                          │
│  → lockfile, typosquatting, クールダウン確認      │
├─────────────────────────────────────────────────┤
│  Layer 3: Post-Install 監査（Hook）               │
│  supply-chain-audit.sh                          │
│  → npm audit / pip-audit 自動実行                │
├─────────────────────────────────────────────────┤
│  Layer 0: ファイアウォール（既存・最終防衛線）       │
│  → レジストリ以外への外部通信をブロック             │
└─────────────────────────────────────────────────┘
```

### Layer 1: パッケージマネージャ設定

標準的な設定ファイルによる常時保護。Claude Code 以外（手動操作、CI）でも有効。

| ファイル | 対象 | 主な設定 |
| --- | --- | --- |
| `.npmrc` | npm | `ignore-scripts=true`, `save-exact=true`, `min-release-age=7`, レジストリ固定 |
| `uv.toml` | uv | `exclude-newer = "<7日前の日時>"`（RFC 3339 絶対日時）, レジストリ固定 |
| `.pip.conf` | pip | `uploaded-prior-to`（絶対日付）, レジストリ固定 |
| `.mvn-settings.xml` | Maven | Maven Central のみにミラー固定 |

#### クールダウン設定（7日）

公開から7日未満のパッケージバージョンをブロックする。2026年3月の axios/LiteLLM 攻撃はいずれも数時間以内に検知・削除されており、7日のクールダウンで防御可能。

| ツール | 設定キー | 形式 | 緊急バイパス |
| --- | --- | --- | --- |
| npm v11.10.0+ | `min-release-age=7` | 日数（相対） | `--min-release-age=0` |
| uv v0.6.0+ | `exclude-newer = "<7日前の日時>"` | RFC 3339 絶対日時（要定期更新） | `--exclude-newer "$(date -u +%Y-%m-%dT%H:%M:%SZ)"` |
| pip v26.0+ | `uploaded-prior-to = 2026-04-06` | 絶対日付（要定期更新） | `--uploaded-prior-to=$(date -Idate)` |

> **pip/uv は絶対日付**のため定期的な更新が必要（`cooldown-update.sh`）。npm のみ相対日数なので更新不要。

> **ignore-scripts について**: `ignore-scripts=true` により、`postinstall` 等のライフサイクルスクリプトが実行されない。一部のパッケージ（`node-gyp` を使うネイティブモジュール等）はインストール後にビルドが必要なため、その場合は `npm rebuild <package>` を個別に実行する。

### Layer 2: Pre-Install ガード

Claude Code の PreToolUse Hook により、`npm install` / `pip install` / `uv add` の実行前に以下をチェック:

- **Lockfile チェック**: `package-lock.json` / `uv.lock` の存在確認
- **Typosquatting 検知**: 人気パッケージ名との類似度をレーベンシュタイン距離で計算し、疑わしいパッケージ名をブロック
- **悪意あるパッケージパターン**: 疑わしい名前パターンのブロック
- **クールダウン確認**: 各ツールのクールダウン設定が有効か確認し、バイパス（`--min-release-age=0` 等）を検知して警告

### Layer 3: Post-Install 監査

インストール完了後に自動で脆弱性スキャンを実行し、結果を表示:

- **npm**: `npm audit` で既知の脆弱性を検出
- **Python**: `pip-audit` で既知の脆弱性を検出

### ローカルPC（ホスト）のクールダウン設定

DevContainer 内だけでなく、ビルドを行うローカルPC自体にもクールダウンを適用することを推奨する。

```bash
# 設定状況の確認
bash local-cooldown-setup.sh --check

# 対話モードで設定（確認あり）
bash local-cooldown-setup.sh

# 自動適用（確認なし）
bash local-cooldown-setup.sh --yes

# クールダウン期間をカスタマイズ
bash local-cooldown-setup.sh --days 3
```

設定対象:

| 設定ファイル | パス（macOS） | パス（Linux） |
| --- | --- | --- |
| npm | `~/.npmrc` | `~/.npmrc` |
| uv | `~/.config/uv/uv.toml` | `~/.config/uv/uv.toml` |
| pip | `~/Library/Application Support/pip/pip.conf` | `~/.config/pip/pip.conf` |

#### クールダウン日付の定期更新

pip (`uploaded-prior-to`) と uv (`exclude-newer`) は**絶対日付**のため、定期的な更新が必要。**週1回以上**の更新を推奨する（14日以上更新しないとクールダウン期間が実質的に拡大し、最新の正規パッケージもインストールできなくなる）。

```bash
# 日付の鮮度チェック（14日超過で STALE 警告）
bash cooldown_management/cooldown-update.sh --check

# 手動更新（デフォルト: 7日前の日付に設定）
bash cooldown_management/cooldown-update.sh

# クールダウン期間を変更（例: 3日前）
bash cooldown_management/cooldown-update.sh 3

# cron で毎週月曜9時に自動更新
(crontab -l 2>/dev/null; echo "0 9 * * 1 bash $(pwd)/cooldown_management/cooldown-update.sh") | crontab -
```

> **注意**: npm は相対日数 (`min-release-age`) のため更新不要。

### サプライチェーンガードの無効化

`.env` に以下を追加すると、Layer 2 / Layer 3 のフック処理を無効化できる（Layer 1 のパッケージマネージャ設定は維持される）:

```env
ENABLE_SUPPLY_CHAIN_GUARD=false
```

## セキュリティテスト

本環境のセキュリティ対策が正しく機能しているかを検証するためのテストを用意している。

### 自動テスト（コンテナ内で実行）

```bash
# 環境レベルのセキュリティテスト
# ファイアウォール、ファイルシステム制限、ユーザー権限、パッケージマネージャ設定、settings.json 整合性
bash /workspace/.claude/tests/security-test.sh

# Hook 単体テスト
# block-dangerous.sh（危険コマンド検出）、supply-chain-guard.sh（typosquatting 等）
bash /workspace/.claude/tests/hook-test.sh
```

### 手動テスト（Claude Code セッション内）

Claude Code の permissions/sandbox レイヤーは、実際の Claude Code セッション内でのみ検証可能。チェックリストに沿って確認する:

```bash
cat /workspace/.claude/tests/SECURITY-CHECKLIST.md
```

主な手動テスト項目:

- **コマンド拒否**: `curl`, `wget`, `ssh`, `sudo` 等が permissions.deny で拒否されるか
- **ファイル読み取り拒否**: `.env`, `~/.ssh/*`, `/etc/shadow` 等が読めないか
- **ファイル書き込み拒否**: `/etc`, `settings.json` への書き込みが sandbox でブロックされるか
- **サプライチェーンガード**: typosquatting パッケージ (`expresss`, `reqeusts`) がブロックされるか
- **--dangerously-skip-permissions**: 無効化されているか

### セキュリティ関連ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [sandbox-security-guide.md](sandbox-security-guide.md) | セキュリティ設計ポイント（4層防御の設計思想・脅威モデル・Prompt Injection 対策） |
| [SECURITY-CHECKLIST.md](workspace/.claude/tests/SECURITY-CHECKLIST.md) | テストチェックリスト（8層防御カバレッジ一覧・自動/手動テスト手順） |

### テスト実行タイミング

- コンテナ初回ビルド後
- セキュリティ設定の変更後
- 定期確認（月1回目安）

## LangFuse トレーシング（オプション）

Claude Code の会話履歴・ツール使用を [LangFuse](https://langfuse.com/) に送信してモニタリングできる。Stop hook により各レスポンス完了後にトランスクリプトを解析し、ターンごとの構造化トレースを生成する。

### 有効化

1. `.env` に以下を追加:

```bash
TRACE_TO_LANGFUSE=true
CC_LANGFUSE_PUBLIC_KEY=pk-lf-xxxxxxxxxxxxxxxxxxxx
CC_LANGFUSE_SECRET_KEY=sk-lf-xxxxxxxxxxxxxxxxxxxx
# EU: https://cloud.langfuse.com / US: https://us.cloud.langfuse.com
CC_LANGFUSE_BASE_URL=https://cloud.langfuse.com
```

1. コンテナを再起動（`docker compose restart dev`）

### アプリ側の LangFuse と併用する場合

workspace 内のアプリ（Python/Node.js 等）が LangFuse を使う場合、環境変数が競合しないよう **2系統の変数**を用意している:

| 変数プレフィックス | 用途 | 例 |
| --- | --- | --- |
| `CC_LANGFUSE_*` | Claude Code Hook 専用 | `CC_LANGFUSE_PUBLIC_KEY`, `CC_LANGFUSE_BASE_URL` |
| `LANGFUSE_*` | アプリ用（標準変数） | `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_HOST` |

```bash
# .env の設定例（Claude Code → クラウド、アプリ → セルフホスト）
TRACE_TO_LANGFUSE=true
CC_LANGFUSE_PUBLIC_KEY=pk-lf-cloudkey
CC_LANGFUSE_SECRET_KEY=sk-lf-cloudkey
CC_LANGFUSE_BASE_URL=https://cloud.langfuse.com

# アプリ用の LANGFUSE_* はここ（claude-dev-env の .env）ではなく、
# アプリ側の .env で設定すること（docker-compose 経由で空文字が注入され上書きされるため）。
# アプリ側 .env の例:
#   LANGFUSE_PUBLIC_KEY=pk-lf-selfhostkey
#   LANGFUSE_SECRET_KEY=sk-lf-selfhostkey
#   LANGFUSE_HOST=http://langfuse-web:3000
```

> `CC_LANGFUSE_*` が未設定の場合は `LANGFUSE_*` にフォールバックする。アプリが LangFuse を使わない場合は `LANGFUSE_*` だけ設定すれば動作する。
>
> **注意**: アプリ用の `LANGFUSE_*` を claude-dev-env の `.env` に設定すると、コンテナ環境変数として注入され、アプリ側の `.env` の値を上書きしてしまう（pydantic-settings 等は環境変数を優先するため）。アプリ側の `.env` で管理すること。

### トレーシングの無効化

`.env` の `TRACE_TO_LANGFUSE` を削除またはコメントアウトするだけで無効化される（デフォルト: 無効）。フックスクリプト自体は残るが、環境変数未設定時は即座に終了するためオーバーヘッドはない。

### セルフホスト LangFuse を使う場合

ホスト側で LangFuse を `docker compose` で起動している場合:

#### Claude Code トレーシング（CC_LANGFUSE_*）

クラウド LangFuse を使う場合はそのまま `CC_LANGFUSE_BASE_URL=https://cloud.langfuse.com` を設定。
セルフホスト LangFuse を使う場合:

1. `CC_LANGFUSE_BASE_URL=http://host.docker.internal:3000` を設定
2. `FIREWALL_ALLOWED_PORTS` に LangFuse のポートを追加（例: `443,80,3000`）

#### アプリからの接続（LANGFUSE_*）

dev コンテナ内のアプリからセルフホスト LangFuse に接続するには、Docker ネットワーク経由で直接通信する:

1. `.env` に `COMPOSE_FILE=docker-compose.yml:docker-compose.langfuse.yml` を設定
2. コンテナを再起動（`docker compose up -d`）
3. アプリの `.env` で `LANGFUSE_HOST=http://langfuse-web:3000` を設定

> `host.docker.internal` 経由の HTTP 通信は Docker Desktop for Mac の制約で不安定なため、Docker ネットワーク経由の直接接続を推奨。`docker-compose.langfuse.yml` は dev コンテナを `langfuse_default` ネットワークに参加させ、LangFuse のサービス名（`langfuse-web`）で DNS 解決を可能にする。

### デバッグ

```bash
# デバッグログを有効化
CC_LANGFUSE_DEBUG=true

# ログ確認（コンテナ内）
cat ~/.claude/state/langfuse_hook.log
```

## MCP サーバー

dev コンテナには以下の MCP (Model Context Protocol) サーバーがプリインストールされており、コンテナ起動時に自動設定される。

| サーバー | 用途 | ファイアウォール対応 |
| --- | --- | --- |
| **Context7** | ライブラリのドキュメント・コード例をリアルタイム検索 | 対応 |
| **Playwright** | ローカル Chromium によるブラウザ自動化・テスト | 対応 |
| **Serena** | LSP ベースのセマンティックコード解析・編集 | 対応 |
| **Sequential Thinking** | 複雑な問題の段階的思考・設計支援 | 対応 |

### 設定の仕組み

- テンプレート: `.devcontainer/mcp-servers.json`
- マージスクリプト: `.devcontainer/setup-mcp.sh`
- コンテナ起動時に `postStartCommand` で `/home/node/.claude/.claude.json` にマージ
- 既存のユーザー設定がある場合、ユーザーの `mcpServers` エントリが優先される（冪等）

### 確認方法

```bash
# MCP サーバーの動作確認
uvx --from git+https://github.com/oraios/serena serena --help
npx @playwright/mcp --help

# 言語サーバーの確認
typescript-language-server --version
pyright --version

# Chromium の確認
npx playwright install --dry-run

# settings.json に MCP 設定が入っているか確認
cat /home/node/.claude/.claude.json

# Claude Code 内で /mcp コマンドを実行 → 4 サーバーが表示されることを確認
```

### 使用例

Claude Code 内で以下のように MCP ツールを活用できる:

- **Context7**: 「React の useEffect について最新のドキュメントを調べて」
- **Playwright**: 「`http://localhost:3000` のページをスクリーンショットして」
- **Serena**: 「このプロジェクトの UserService クラスの参照箇所を探して」
- **Sequential Thinking**: 「このアプリの認証フローを段階的に設計して」

### Context7 とファイアウォール

Context7 が通信する `context7.com`、`mcp.context7.com`、`api.context7.com` はファイアウォールの許可ドメインに登録済みのため、ファイアウォール有効時でも正常に動作する。

## 既知の制約

- Claude Code は Anthropic Messages API 形式で通信し、LiteLLM がプロバイダー固有の形式に変換する。ツール使用等の高度な機能は完全互換ではない場合がある
- モデルの自己申告名は正確ではない（GPT-4o でも「Claude」と名乗る場合がある。Claude Code のシステムプロンプトの影響）
- ファイアウォールスクリプト (`init-firewall.sh`) の実行には `NET_ADMIN` ケーパビリティが必要
- Docker Desktop for Mac で `host.docker.internal` 経由の HTTP 通信が不安定（TCP 接続は成功するが HTTP レスポンスがタイムアウトする場合がある）。ホスト側サービスへの接続は Docker ネットワーク経由（`docker-compose.langfuse.yml` 等）を推奨

## Windows 環境での利用

### Windows の前提条件

- **Docker Desktop for Windows**（WSL2 バックエンド必須）
- WSL2 がインストール・有効化されていること

### WSL2 設定

1. Docker Desktop → **Settings** → **General** → **Use the WSL 2 based engine** を有効化
2. Docker Desktop → **Settings** → **Resources** → **WSL Integration** で使用する WSL ディストリビューションを有効化
3. Docker Desktop のメモリ割り当てを **4GB 以上** に設定

WSL2 のメモリ制限を設定する場合、`%USERPROFILE%\.wslconfig` を作成:

```ini
[wsl2]
memory=6GB
processors=4
```

### 改行コード

`.sh` ファイルが CRLF（Windows 改行）だとコンテナ内で実行エラーになる。以下のいずれかで対策:

#### 方法 A: `.gitattributes` を設定（推奨）

```text
*.sh eol=lf
```

#### 方法 B: Git のグローバル設定

```bash
git config --global core.autocrlf input
```

> **注意**: 既にクローン済みの場合は、設定変更後に `git rm --cached -r . && git reset --hard` で改行コードを修正する必要がある。

### パフォーマンス

WSL2 ファイルシステム内にリポジトリをクローンすることを推奨:

```bash
# 推奨: WSL2 ファイルシステム内（高速）
cd /home/<user>/
git clone <repo-url>

# 非推奨: Windows ファイルシステム（マウント経由のため低速）
cd /mnt/c/Users/<user>/
```

Windows ファイルシステム（`C:\Users\...`）は WSL2 から 9P プロトコル経由でマウントされるため、I/O 性能が大幅に低下する。

### PowerShell コマンド対応

Docker CLI コマンドは Windows / macOS / Linux で共通。シェルコマンドの差分:

| 操作 | bash / zsh | PowerShell |
| --- | --- | --- |
| ファイルコピー | `cp .devcontainer/.env.example .env` | `Copy-Item .devcontainer\.env.example .env` |
| 環境変数参照 | `echo $LITELLM_MASTER_KEY` | `echo $env:LITELLM_MASTER_KEY` |
| 環境変数設定 | `export FOO=bar` | `$env:FOO = "bar"` |
| 複数コマンド連結 | `cmd1 && cmd2` | `cmd1; if ($?) { cmd2 }` |

### ファイアウォール

dev コンテナは WSL2 内の Linux コンテナとして動作するため、`iptables` ベースのファイアウォール (`init-firewall.sh`) はそのまま正常に動作する。Windows 側のファイアウォール設定を変更する必要はない。

## プロキシ環境での利用

社内プロキシの背後にある環境で本開発環境を利用する場合の設定手順。

### 1. `.env` にプロキシ設定を追加

`.env.example` を参考に、`.env` にプロキシ設定を追加:

```env
HTTP_PROXY=http://proxy.example.com:8080
HTTPS_PROXY=http://proxy.example.com:8080
NO_PROXY=localhost,127.0.0.1,litellm,dev,api.openai.com,api.anthropic.com
```

### 2. `docker-compose.yml` のプロキシ行をアンコメント

各サービスのコメントアウトされたプロキシ設定を有効化する:

- **litellm**: `environment` のプロキシ行（小文字のみ。大文字は `env_file` 経由で `.env` から自動読み込み）
- **dev**: `build.args` と `environment` のプロキシ行

### 3. `.devcontainer/Dockerfile` のプロキシ設定をアンコメント

dev コンテナのビルド時（`apt-get`, `npm install` 等）にプロキシが必要な場合、`.devcontainer/Dockerfile` のプロキシ行を有効化:

- `ARG HTTP_PROXY` / `ARG HTTPS_PROXY` / `ARG NO_PROXY`
- `ENV HTTP_PROXY=... http_proxy=...` ブロック

> **注意**: `litellm/Dockerfile` にはビルド時のネットワーク操作がないため、プロキシ設定は不要。litellm のランタイムプロキシは `.env` + `docker-compose.yml` の `environment` で設定する。

### 4. 再ビルド

```bash
docker compose up -d --build
```

### 5. 確認

```bash
# dev コンテナ内でプロキシ設定を確認
docker compose exec dev bash -c 'echo $HTTP_PROXY'

# litellm コンテナ内でプロキシ設定を確認
docker compose exec litellm bash -c 'echo $HTTP_PROXY'
```

### NO_PROXY の調整

`NO_PROXY` の設定は、ネットワーク構成に応じて調整が必要:

| シナリオ | NO_PROXY に含める | 説明 |
| --- | --- | --- |
| LLM API にプロキシなしで直接アクセス可能 | `api.openai.com`, `api.anthropic.com` | デフォルト設定。API 通信がプロキシを迂回 |
| LLM API にプロキシ経由でのみアクセス可能 | Docker 内部のみ (`localhost,litellm` 等) | API エンドポイントを NO_PROXY から除外 |

> **大文字・小文字の両方を設定する理由**: `curl` / `wget` は小文字（`http_proxy`）、Python / Go は大文字（`HTTP_PROXY`）を参照する。本設定ではすべてのサービスで両方を設定している。
