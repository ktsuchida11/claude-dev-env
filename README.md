# Claude Code + LiteLLM + GitLab CE Docker 開発環境

Claude Code のバックエンドとして LiteLLM プロキシを使い、複数の LLM プロバイダー（OpenAI, Azure OpenAI, Databricks）を切り替えて利用できる Docker 開発環境。GitLab CE によるソースコード管理・CI/CD も統合。

## なぜ Dev Container 構成なのか

### Claude Code を LiteLLM 経由で使う際の課題

Claude Code は本来 Anthropic の API に直接接続して動作する。LiteLLM プロキシを間に挟んで OpenAI 等の別プロバイダーを使う場合、以下の課題がある:

1. **ファイルアクセスの制御が困難**: Claude Code はファイル操作やコマンド実行などの強力な権限を持つ。ホスト環境で直接実行すると、`~/.ssh`、`~/.aws`、他のリポジトリなどホスト上の機密ファイルにアクセスできてしまう
2. **ネットワークの制御が困難**: 同様に、ホスト環境では意図しない外部通信が発生した場合に検知・制御が難しい
3. **API キーの管理リスク**: `OPENAI_API_KEY` や `AZURE_API_KEY` などの機密情報をローカル環境に直接置くと、他のプロセスやツールからアクセスされる可能性がある
4. **環境の再現性**: LiteLLM のバージョン、Node.js のバージョン、Claude Code のバージョンなど、チームで揃える必要のある依存関係が多い

### Dev Container が解決すること

- **ファイルシステムの隔離**: Claude Code がアクセスできるファイルをコンテナ内（`/workspace`）に限定し、ホスト上の機密ファイルや他のリポジトリへのアクセスを防ぐ
- **API キーの隔離**: API キーはコンテナ内にのみ存在し、ホスト環境から分離される
- **ネットワーク制御**: ファイアウォール (`init-firewall.sh`) で外部通信先を明示的にホワイトリスト管理できる
- **再現可能な環境**: Dockerfile と docker-compose.yml で環境が完全に定義され、チームの誰でも同じ環境を再現できる
- **VS Code との統合**: Dev Containers 拡張により、VS Code のエディタ機能（拡張、設定、デバッガ）をコンテナ内で透過的に利用できる

## ファイアウォール (init-firewall.sh) の役割

### なぜファイアウォールが必要か

Claude Code は `--dangerously-skip-permissions` モードで使うと、ファイル操作やシェルコマンドの実行を確認なしで行える。この機能は開発効率を大幅に向上させるが、同時にリスクも伴う:

- 悪意のあるプロンプト注入により、意図しないコマンドが実行される可能性
- コード生成時に予期しない外部サービスへのデータ送信が行われる可能性

ファイアウォールはこのリスクに対する**最終防御ライン**として機能する。

### 仕組み

`init-firewall.sh` は `iptables` と `ipset` を使い、dev コンテナからの外部通信を以下のドメインのみに制限する:

| 許可ドメイン | 用途 |
| --- | --- |
| `registry.npmjs.org` | npm パッケージのインストール |
| `api.github.com` + GitHub IP レンジ | git 操作、GitHub CLI |
| `api.anthropic.com` | Claude Code の認証・テレメトリ |
| `sentry.io` | エラーレポート |
| `statsig.anthropic.com`, `statsig.com` | フィーチャーフラグ |
| `marketplace.visualstudio.com` 等 | VS Code 拡張のインストール・更新 |
| Docker 内部ネットワーク (ホストネットワーク) | litellm, gitlab コンテナとの通信 |

上記以外の外部通信は **すべてブロック** される。これにより、万が一不正なコマンドが実行されても、データが外部に送信されることを防ぐ。

### LiteLLM / GitLab との関係

ファイアウォールは Docker 内部ネットワークの通信は許可するため、dev コンテナから litellm コンテナ (`http://litellm:4000`) や gitlab コンテナ (`http://gitlab:80`) への通信は正常に動作する。外部の LLM API への通信は litellm コンテナが担当するため、dev コンテナのファイアウォールの影響を受けない。

```text
dev コンテナ                        litellm コンテナ
┌──────────────────────┐           ┌──────────────────────┐
│ ファイアウォール有効    │           │ ファイアウォールなし    │
│                      │           │                      │
│ Claude Code ─────────────────▶ LiteLLM Proxy ──┬──▶ OpenAI API
│                      │  Docker   │              ├──▶ Azure OpenAI
│ 外部通信: ブロック     │  内部NW   │              └──▶ Databricks ──▶ Anthropic API
└──────────────────────┘           └──────────────────────┘
```

> **注意**: ファイアウォールの実行には `NET_ADMIN` ケーパビリティが必要です。`docker-compose.yml` で `cap_add: [NET_ADMIN, NET_RAW]` を設定しています。

### ファイアウォールの無効化

環境変数 `ENABLE_FIREWALL=false` を設定すると、ファイアウォールを無効化できる。以下のケースで利用する:

- **プロキシ環境での切り分け**: プロキシ環境で通信エラーが発生した場合に、ファイアウォールが原因かプロキシ設定が原因かを切り分ける
- **Context7 の利用**: Context7 MCP サーバーは外部 API 通信が必要なため、ファイアウォール有効時には動作しない

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
| GitLab CE Docker イメージ | <https://docs.gitlab.com/install/docker/> |
| GitLab Runner Docker イメージ | <https://docs.gitlab.com/runner/install/docker.html> |
| OpenHands ドキュメント | <https://docs.all-hands.dev/> |
| OpenHands GitHub リポジトリ | <https://github.com/All-Hands-AI/OpenHands> |

## プロジェクト構成

```text
m_poc/
├── .devcontainer/
│   ├── Dockerfile              # 開発コンテナ (Node 20 + zsh + Claude Code + glab + MCP + ファイアウォール)
│   ├── devcontainer.json       # VS Code Dev Containers 設定
│   ├── init-firewall.sh        # 外部通信制限スクリプト
│   ├── mcp-servers.json        # MCP サーバー設定テンプレート
│   ├── setup-mcp.sh            # MCP 設定マージスクリプト（冪等）
│   ├── .env.example            # 環境変数テンプレート (ローカル GitLab 版)
│   └── .env.external-gitlab.example  # 環境変数テンプレート (外部 GitLab 版)
├── litellm/
│   ├── Dockerfile              # LiteLLM プロキシコンテナ
│   └── config.yaml             # モデル設定 (OpenAI / Azure / Databricks)
├── docker-compose.yml          # メイン (dev, litellm + profiles: gitlab, openhands)
├── docker-compose.podman.yml   # Podman 対応版 (同上)
├── docker-compose.external-gitlab.yml  # 外部 GitLab 版 (dev, litellm + profile: openhands)
├── workspace/                  # コンテナ内の /workspace にマウント (dev 用)
├── workspace-openhands/        # OpenHands 用ワークスペース (gitignore対象)
├── .env                        # APIキー等 (gitignore対象)
└── .gitignore
```

## コンテナ構成

Docker Compose の `profiles` 機能により、必要なサービスのみを起動できる。

| コマンド | 起動するサービス |
| --- | --- |
| `docker compose up -d` | dev, litellm |
| `docker compose --profile gitlab up -d` | dev, litellm, gitlab, gitlab-runner |
| `docker compose --profile openhands up -d` | dev, litellm, openhands |
| `docker compose --profile gitlab --profile openhands up -d` | 全サービス |

### dev コンテナ（開発用）

| 項目 | 内容 |
| --- | --- |
| ベースイメージ | `node:20` |
| シェル | zsh (Powerlevel10k テーマ) |
| Claude Code | `@anthropic-ai/claude-code@latest` |
| 開発ツール | git, vim, nano, jq, fzf, gh (GitHub CLI), glab (GitLab CLI), git-delta |
| MCP サーバー | Context7 (ドキュメント検索), Playwright (ブラウザ自動化), Serena (セマンティックコード解析) |
| 言語サーバー | typescript-language-server, pyright (Serena 用) |
| ユーザー | `node` (非 root) |
| ファイアウォール | 外部通信を許可ドメインのみに制限 (npm, GitHub, Anthropic API, VS Code 等) |

VS Code 拡張（自動インストール）:

- `anthropic.claude-code` - Claude Code
- `dbaeumer.vscode-eslint` - ESLint
- `esbenp.prettier-vscode` - Prettier
- `eamodio.gitlens` - GitLens

### litellm コンテナ（LLM プロキシ）

| 項目 | 内容 |
| --- | --- |
| ベースイメージ | `ghcr.io/berriai/litellm:main-latest` |
| ポート | 4000 |
| 役割 | Anthropic Messages API → OpenAI/Azure/Databricks API の変換プロキシ |

### gitlab コンテナ（ソースコード管理）※ `--profile gitlab` で起動

| 項目 | 内容 |
| --- | --- |
| イメージ | `gitlab/gitlab-ce:17.8.1-ce.0` |
| Web UI ポート | 8929 (ホスト) → 80 (コンテナ) |
| SSH ポート | 2224 (ホスト) → 22 (コンテナ) |
| 役割 | Git リポジトリ管理、MR/Issue、CI/CD、Pages |
| メモリ | ~2-3GB（最適化設定済み） |

### gitlab-runner コンテナ（CI/CD）※ `--profile gitlab` で起動

| 項目 | 内容 |
| --- | --- |
| イメージ | `gitlab/gitlab-runner:v17.8.1` |
| 役割 | GitLab CI/CD ジョブの実行 |
| Executor | Docker (ホストの Docker ソケットをマウント) |

### ネットワークフロー

```text
VS Code (ホスト) ──── http://localhost:8929 ──── GitLab Web UI
    │
    │ Remote - Containers 接続
    ▼
dev コンテナ (Claude Code + glab CLI)
    │
    ├── ANTHROPIC_BASE_URL=http://litellm:4000
    │   ANTHROPIC_AUTH_TOKEN=<LITELLM_MASTER_KEY>
    │   ▼
    │   litellm コンテナ (:4000)
    │       │
    │       │ config.yaml で設定されたプロバイダーへ転送
    │       ├──▶ OpenAI API (gpt-4o, gpt-4o-mini)
    │       ├──▶ Azure OpenAI (azure-gpt)
    │       └──▶ Azure Databricks (db-claude-sonnet) ──▶ Anthropic API
    │
    └── http://gitlab:80 (git/API) ──▶ gitlab コンテナ
        ssh://git@gitlab:22 (git)          ▲
                                           │ Runner 登録 & ジョブ実行
                                    gitlab-runner コンテナ
```

## セットアップ

### 前提条件

- Docker Desktop
- VS Code + [Dev Containers 拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

### 1. 環境変数の設定

```bash
cp .devcontainer/.env.example .env
```

`.env` を編集して API キーを設定:

```env
OPENAI_API_KEY=sk-your-openai-api-key
LITELLM_MASTER_KEY=sk-any-string-you-choose
```

> `LITELLM_MASTER_KEY` は LiteLLM プロキシ自体へのアクセスを保護する鍵です。外部サービスのキーではなく、自分で自由に決める文字列です。

### 2. コンテナのビルドと起動

まずコマンドラインでコンテナをビルド・起動する:

```bash
cd m_poc/

# 最小構成（dev + litellm のみ）
docker compose up -d --build

# GitLab CE を含める場合
docker compose --profile gitlab up -d --build

# OpenHands も含める場合
docker compose --profile gitlab --profile openhands up -d --build

# 2回目以降: 起動のみ（profile は毎回指定が必要）
docker compose --profile gitlab up -d

# 起動確認
docker compose ps
```

> **注意**: `--profile` を指定しない場合、dev + litellm のみが起動します。GitLab や OpenHands を使う場合は毎回 `--profile` の指定が必要です。

### 3. 開発環境への接続

#### 方法 A: VS Code から接続（推奨）

1. コンテナが起動していることを確認（`docker compose ps` で `dev` が `running`）
2. VS Code で `m_poc/` フォルダを開く
3. 左下の `><` アイコンをクリック、または `Cmd+Shift+P` → `Dev Containers: Reopen in Container`
4. VS Code がコンテナ内にリモート接続される
5. ターミナルで `claude` コマンドが使える

> **注意**: `Dev Containers: Reopen in Container` が表示されない場合は、[Dev Containers 拡張](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)がインストールされているか、Docker Desktop が起動しているかを確認してください。

#### 方法 B: コマンドラインから接続

```bash
# dev コンテナに入る
docker compose exec -it dev zsh

# MCP サーバーの設定（初回 or settings.json がない場合）
/usr/local/bin/setup-mcp.sh

# Claude Code を使う
claude "Hello!"
```

> **注意**: `docker compose up` で直接起動した場合、`devcontainer.json` の `postStartCommand` は実行されません。MCP サーバーの設定が `/home/node/.claude/.claude.json` にない場合は、手動で `setup-mcp.sh` を実行してください。VS Code の Dev Containers 経由で接続した場合は自動で実行されます。

### 4. 停止

```bash
# 起動時と同じ profile を指定して停止
docker compose --profile gitlab down

# 全 profile のコンテナを停止する場合
docker compose --profile gitlab --profile openhands down
```

## モデル切り替え

ターミナルで環境変数 `ANTHROPIC_MODEL` を変更して Claude Code を起動:

```bash
# デフォルト: OpenAI GPT-4o
claude

# GPT-4o-mini に切り替え
ANTHROPIC_MODEL=gpt-4o-mini claude

# Phase 2: Azure OpenAI (.env に認証情報の設定が必要)
ANTHROPIC_MODEL=azure-gpt claude

# Phase 3: Azure Databricks 経由の Claude (.env に認証情報の設定が必要)
ANTHROPIC_MODEL=db-claude-sonnet claude
```

## Phase 2/3 の有効化

### Phase 2: Azure OpenAI

#### Azure ポータルでのリソース作成

1. Azure ポータル → 「リソースの作成」→「Azure OpenAI」
2. サブスクリプション、リソースグループ、リージョン、名前、価格レベルを設定
3. 作成完了後、Azure AI Foundry (<https://ai.azure.com>) を開く
4. 「デプロイメント」→「モデルのデプロイ」→ gpt-4o を選択してデプロイ
5. デプロイメント名をメモ（`litellm/config.yaml` に使用）
6. Azure ポータルの「キーとエンドポイント」から API キーとエンドポイント URL を取得

#### `.env` の設定

`.env` に Azure の認証情報を追加:

```env
AZURE_DEPLOYMENT_NAME=gpt-5-mini
AZURE_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
AZURE_API_BASE=https://your-resource.openai.azure.com/
AZURE_API_VERSION=2025-04-01-preview
```

| 変数 | 説明 | 確認場所 |
|------|------|---------|
| `AZURE_DEPLOYMENT_NAME` | デプロイメント名 | Azure AI Foundry → デプロイメント |
| `AZURE_API_KEY` | API キー | Azure ポータル → キーとエンドポイント |
| `AZURE_API_BASE` | エンドポイント URL | 同上 |
| `AZURE_API_VERSION` | API バージョン | `2025-04-01-preview` または `2024-10-21`（安定 GA） |

#### `litellm/config.yaml` の設定

`litellm/config.yaml` の `<your-deployment-name>` を `.env` の `AZURE_DEPLOYMENT_NAME` の値に置き換える:

```yaml
model: azure/gpt-5-mini  # ← AZURE_DEPLOYMENT_NAME の値
```

#### ビルド・起動・テスト

```bash
# litellm コンテナを再ビルド
docker compose up -d --build litellm

# ヘルスチェック（Authorization ヘッダー必須）
curl -s http://localhost:4000/health -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{healthy: [.healthy_endpoints[].model], unhealthy: [.unhealthy_endpoints[].model]}'

# モデル一覧で Azure モデルが表示されるか確認
curl -s http://localhost:4000/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'

# Azure モデルへの直接リクエストテスト
curl -s -X POST http://localhost:4000/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"azure-gpt","messages":[{"role":"user","content":"Hello"}]}'

# dev コンテナから Azure モデルで Claude Code を起動
docker compose exec -it dev bash -c 'ANTHROPIC_MODEL=azure-gpt claude'
```

### Phase 3: Azure Databricks (Claude External Model)

Azure Databricks の **External Model** 機能を使い、Anthropic API を Databricks 経由でプロキシ利用する。Databricks がリクエストの認証・ログ・ガバナンスを担い、Anthropic API への通信は Databricks 側で行われる。

#### 仕組み

```text
Claude Code → LiteLLM → Azure Databricks (External Model) → Anthropic API
                         ↑ PAT で認証        ↑ Anthropic API キーで認証
                         (.env で管理)        (Databricks UI で登録)
```

#### Azure Databricks ワークスペースの作成

1. Azure ポータル →「リソースの作成」→「Azure Databricks」
2. 以下を設定:

   | 項目 | 設定値 |
   |------|--------|
   | ワークスペース名 | 任意 |
   | サブスクリプション | 従量課金制（無料試用版は不可） |
   | リソースグループ | 新規作成 or 既存 |
   | リージョン | 任意（External Model はリージョン制約なし） |
   | **価格レベル** | **Premium（必須）** |

3. 「確認および作成」→「作成」→ デプロイ完了を待つ
4. リソースページで「ワークスペースの起動」をクリック

#### External Model エンドポイントの作成

1. Databricks ワークスペース → 左メニュー「Serving」
2. 「Create serving endpoint」をクリック
3. 以下を設定:

   | フィールド | 設定値 |
   |-----------|--------|
   | **名前** | エンドポイント名（例: `claude-sonnet-4-5`） |
   | **エンティティ種別** | 「External model」を選択 |
   | **プロバイダー** | Anthropic |
   | **API キーシークレット** | Anthropic API キー（`sk-ant-...`）※下記参照 |
   | **タスク** | Chat |
   | **プロバイダーモデル** | `claude-sonnet-4-5` などモデル名 |

4. 「Create」でエンドポイントを作成
5. ステータスが「Ready」になるまで待つ

> **Anthropic API キーの取得**: <https://console.anthropic.com> → API Keys → Create Key

#### 利用可能なプロバイダーモデル名

エンドポイント作成時の「プロバイダーモデル」に入力する Anthropic モデル名:

| モデル | プロバイダーモデル名 | 特徴 |
|--------|---------------------|------|
| Claude Sonnet 4.5 | `claude-sonnet-4-5` | ハイブリッド推論・コード開発 |
| Claude Opus 4 | `claude-opus-4` | 高度な推論・複雑なタスク |
| Claude Sonnet 4 | `claude-sonnet-4` | コード開発・大規模コンテンツ分析 |
| Claude Haiku 4.5 | `claude-haiku-4-5` | 高速・低コスト |

> モデルごとにエンドポイントを作成する。例: `claude-sonnet-4-5`, `claude-opus-4`

#### 個人アクセストークン (PAT) の生成

1. Azure Databricks ワークスペースにログイン
2. 右上のユーザー名 →「Settings」
3. 「Developer」→「Access tokens」の「Manage」をクリック
4. 「Generate new token」→ コメントと有効期限を設定
5. **トークンをコピー**（再表示不可）

#### `.env` の設定

`.env` に Databricks の認証情報を追加:

```env
DATABRICKS_API_KEY=dapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
DATABRICKS_API_BASE=https://adb-1234567890.11.azuredatabricks.net/serving-endpoints
```

| 変数 | 説明 | 確認場所 |
|------|------|---------|
| `DATABRICKS_API_KEY` | 個人アクセストークン (PAT) | ワークスペース → Settings → Developer → Access tokens |
| `DATABRICKS_API_BASE` | サービングエンドポイント URL | Databricks Serving のエンドポイント「URL プレビュー」からホスト部分 + `/serving-endpoints` |

> **注意**: Anthropic API キーは `.env` には不要。Databricks のエンドポイント設定画面で登録済みのため、LiteLLM からは Databricks PAT のみで認証される。

#### `litellm/config.yaml` の設定

Databricks で作成したエンドポイント名を `model` フィールドの `databricks/` の後に指定する:

```yaml
# エンドポイント名が claude-sonnet-4-5 の場合
- model_name: db-claude-sonnet
  litellm_params:
    model: databricks/claude-sonnet-4-5
    api_key: os.environ/DATABRICKS_API_KEY
    api_base: os.environ/DATABRICKS_API_BASE
```

複数モデルを使う場合は、モデルごとにエンドポイントを作成し追加:

```yaml
- model_name: db-claude-opus
  litellm_params:
    model: databricks/claude-opus-4
    api_key: os.environ/DATABRICKS_API_KEY
    api_base: os.environ/DATABRICKS_API_BASE
```

#### ビルド・起動・テスト

```bash
# litellm コンテナを再ビルド
docker compose up -d --build litellm

# ヘルスチェック（Authorization ヘッダー必須）
curl -s http://localhost:4000/health -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '{healthy: [.healthy_endpoints[].model], unhealthy: [.unhealthy_endpoints[].model]}'

# モデル一覧で Databricks モデルが表示されるか確認
curl -s http://localhost:4000/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.data[].id'

# Databricks Claude への直接リクエストテスト
curl -s -X POST http://localhost:4000/chat/completions -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"model":"db-claude-sonnet","messages":[{"role":"user","content":"Hello"}]}'

# dev コンテナから Databricks Claude Sonnet で Claude Code を起動
docker compose exec -it dev bash -c 'ANTHROPIC_MODEL=db-claude-sonnet claude'
```

## GitLab CE セットアップ

### リソース要件

| リソース | 最小 | 推奨 |
| --- | --- | --- |
| Docker Desktop メモリ | 4GB | 6GB+ |
| ディスク（GitLab イメージ） | ~3GB | ~3GB |
| GitLab 起動時間 | 3分 | 5分 |

### 初回起動

```bash
# GitLab を含めてビルド & 起動
docker compose --profile gitlab up -d --build

# GitLab の起動状態を確認（healthy になるまで3-5分待つ）
docker compose --profile gitlab ps
```

GitLab が `healthy` になったら、ブラウザで <http://localhost:8929> にアクセス:

- **ユーザー名**: `root`
- **パスワード**: `.env` の `GITLAB_ROOT_PASSWORD` の値（デフォルト: `P@ssw0rd1234`）

### Personal Access Token の作成

1. GitLab Web UI にログイン
2. 右上のアバター → **Edit profile** → 左メニュー **Access Tokens**
3. **Add new token** をクリック:
   - **Token name**: `glab-cli`
   - **Expiration date**: 任意
   - **Scopes**: `api`, `read_repository`, `write_repository`
4. **Create personal access token** をクリックし、表示されたトークンをコピー
5. `.env` にトークンを設定:

   ```env
   GITLAB_PERSONAL_ACCESS_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
   ```

6. コンテナを再起動して環境変数を反映:

   ```bash
   docker compose up -d
   ```

### glab CLI の設定

dev コンテナ内で以下を実行:

```bash
glab auth login --hostname gitlab --token $GITLAB_TOKEN
```

### Git リモート設定

GitLab Web UI でプロジェクトを作成後、dev コンテナ内でリモートを追加:

```bash
# HTTP 経由
git remote add gitlab http://gitlab/root/<project-name>.git

# SSH 経由（SSH キー登録が必要）
git remote add gitlab ssh://git@gitlab:22/root/<project-name>.git
```

### GitLab Runner の登録

1. GitLab Web UI → **Admin Area** → **CI/CD** → **Runners** → **New instance runner**
2. 表示された登録トークンをコピー
3. Runner を登録:

   ```bash
   docker compose exec gitlab-runner gitlab-runner register \
     --non-interactive \
     --url http://gitlab \
     --token <TOKEN> \
     --executor docker \
     --docker-image alpine:latest \
     --docker-network-mode m_poc_default
   ```

4. 登録確認:

   ```bash
   docker compose exec gitlab-runner gitlab-runner list
   ```

### GitLab Pages

`.gitlab-ci.yml` の例:

```yaml
pages:
  stage: deploy
  script:
    - mkdir -p public
    - cp -r docs/* public/
  artifacts:
    paths:
      - public
  only:
    - main
```

### glab CLI の使用例

```bash
# プロジェクト一覧
glab repo list

# Merge Request の作成
glab mr create --title "Feature: add login" --description "ログイン機能を追加"

# Issue の作成
glab issue create --title "Bug: fix crash" --label bug

# CI/CD パイプラインのステータス確認
glab ci status

# CI/CD パイプラインの一覧
glab ci list
```

### トラブルシューティング

#### GitLab が起動しない / タイムアウトする

```bash
# ログを確認
docker compose logs gitlab

# ヘルスチェックの状態を確認
docker inspect --format='{{json .State.Health}}' m_poc-gitlab-1 | jq
```

GitLab は起動に3-5分かかります。Docker Desktop のメモリ割り当てが 4GB 未満の場合、起動に失敗することがあります。

#### root パスワードをリセットしたい

```bash
docker compose exec gitlab gitlab-rake "gitlab:password:reset[root]"
```

#### Runner が GitLab に接続できない

Runner のジョブ実行時に GitLab に接続できない場合、`--docker-network-mode` が正しいか確認:

```bash
# Docker ネットワーク名を確認
docker network ls | grep m_poc

# Runner の設定を確認
docker compose exec gitlab-runner cat /etc/gitlab-runner/config.toml
```

#### dev コンテナから GitLab に接続できない

```bash
# 疎通確認
curl -s http://gitlab:80/-/readiness

# ファイアウォール有効後の疎通確認
sudo /usr/local/bin/init-firewall.sh && curl -s http://gitlab:80/-/readiness
```

## OpenHands（オプション）

[OpenHands](https://github.com/All-Hands-AI/OpenHands) は Web UI を持つ AI コーディングエージェント。Docker Compose の `profiles` 機能でオプショナルサービスとして追加されており、必要な場合のみ起動できる。LiteLLM 経由で LLM を利用するため、既存のモデル切り替え機能をそのまま活用できる。

### Claude Code との使い分け

| 観点 | Claude Code | OpenHands |
|------|------------|-----------|
| **インターフェース** | ターミナル (CLI) / VS Code 拡張 | Web ブラウザ (GUI) |
| **操作スタイル** | 対話しながら段階的に作業を進める | タスクを指示して自律的に実行させる |
| **ワークスペース** | dev コンテナ内 (`/workspace`) | 専用サンドボックスコンテナ (`workspace-openhands/`) |
| **適したユースケース** | コードレビュー、デバッグ、リファクタリングなど開発者が主導する作業 | 新規機能の雛形作成、定型的なコード生成など自律実行に向くタスク |
| **環境** | dev コンテナ内のツール（git, glab, MCP サーバー等）をフル活用 | 独立したサンドボックスで実行。既存の dev 環境に影響しない |

両ツールは同じ LiteLLM プロキシを共有するため、LLM プロバイダーやモデルの設定を二重に管理する必要はない。用途に応じて使い分け、あるいは併用できる。

### 起動

```bash
# OpenHands を含めて起動
docker compose --profile openhands up -d

# Podman の場合
podman-compose -f docker-compose.podman.yml --profile openhands up -d

# 外部 GitLab 版の場合
docker compose -f docker-compose.external-gitlab.yml --profile openhands up -d
```

起動後、ブラウザで http://localhost:3000 にアクセスして OpenHands の Web UI を開く。

### LLM の設定（初回のみ）

OpenHands の Web UI から LiteLLM 経由で LLM を利用するための設定:

1. Web UI の Settings（歯車アイコン）を開く
2. LLM Provider で「LiteLLM Proxy」を選択
3. 以下を設定:
   - **Model**: `litellm_proxy/gpt-4o`（または `litellm_proxy/<model>`）
   - **Base URL**: `http://litellm:4000`
   - **API Key**: `.env` の `LITELLM_MASTER_KEY` の値

### WORKSPACE_MOUNT_PATH の設定

OpenHands はサンドボックスコンテナを Docker API 経由で起動する。サンドボックスがホスト上のワークスペースをマウントするため、`WORKSPACE_MOUNT_PATH` にはホスト上の絶対パスを指定する必要がある。

`.env` に以下を追加（パスは環境に合わせて変更）:

```env
OPENHANDS_WORKSPACE_MOUNT_PATH=/absolute/path/to/m_poc/workspace-openhands
```

> **注意**: コンテナ内のパスではなくホストパスを指定する。設定しない場合、デフォルト値が使用されるが、環境によっては正しく動作しない場合がある。

### 停止

```bash
docker compose --profile openhands down
```

### Podman での注意点

Podman 環境では OpenHands のサンドボックスコンテナ起動に Docker ソケットアクセスが必要。`docker-compose.podman.yml` では `/run/podman/podman.sock` をマウントしているが、Podman のソケットが有効になっている必要がある。

## MCP サーバー

dev コンテナには以下の MCP (Model Context Protocol) サーバーがプリインストールされており、コンテナ起動時に自動設定される。

| サーバー | 用途 | ファイアウォール対応 |
| --- | --- | --- |
| **Context7** | ライブラリのドキュメント・コード例をリアルタイム検索 | 非対応（外部 API 通信が必要） |
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

Context7 は `context7.com` への外部 API 通信が必要なため、ファイアウォール有効時には動作しない。Context7 を利用する場合は、ファイアウォールを無効にするか、`init-firewall.sh` に `context7.com` を許可ドメインとして追加する必要がある。

## 既知の制約

- Claude Code は Anthropic Messages API 形式で通信し、LiteLLM がプロバイダー固有の形式に変換する。ツール使用等の高度な機能は完全互換ではない場合がある
- モデルの自己申告名は正確ではない（GPT-4o でも「Claude」と名乗る場合がある。Claude Code のシステムプロンプトの影響）
- ファイアウォールスクリプト (`init-firewall.sh`) の実行には `NET_ADMIN` ケーパビリティが必要

## Windows 環境での利用

### 前提条件

- **Docker Desktop for Windows**（WSL2 バックエンド必須）
- WSL2 がインストール・有効化されていること

### WSL2 設定

1. Docker Desktop → **Settings** → **General** → **Use the WSL 2 based engine** を有効化
2. Docker Desktop → **Settings** → **Resources** → **WSL Integration** で使用する WSL ディストリビューションを有効化
3. Docker Desktop のメモリ割り当てを **4GB 以上** に設定（GitLab CE が ~2-3GB 消費するため）

WSL2 のメモリ制限を設定する場合、`%USERPROFILE%\.wslconfig` を作成:

```ini
[wsl2]
memory=6GB
processors=4
```

### 改行コード

`.sh` ファイルが CRLF（Windows 改行）だとコンテナ内で実行エラーになる。以下のいずれかで対策:

**方法 A: `.gitattributes` を設定（推奨）**

```text
*.sh eol=lf
```

**方法 B: Git のグローバル設定**

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
|------|-----------|------------|
| ファイルコピー | `cp .devcontainer/.env.example .env` | `Copy-Item .devcontainer\.env.example .env` |
| 環境変数参照 | `echo $LITELLM_MASTER_KEY` | `echo $env:LITELLM_MASTER_KEY` |
| 環境変数設定 | `export FOO=bar` | `$env:FOO = "bar"` |
| 複数コマンド連結 | `cmd1 && cmd2` | `cmd1; if ($?) { cmd2 }` |

### プロキシ設定（Windows 固有の注意点）

Windows 環境でプロキシを使用する場合、[プロキシ環境での利用](#プロキシ環境での利用) の手順に加えて以下に注意:

#### Docker Desktop のプロキシ設定

Windows のシステム環境変数に `HTTP_PROXY` / `HTTPS_PROXY` を設定すると、Docker Desktop 自体の通信（イメージの pull、Docker Hub 認証等）にも影響する。Docker Desktop には専用のプロキシ設定がある:

1. Docker Desktop → **Settings** → **Resources** → **Proxies**
2. **Manual proxy configuration** を有効化
3. HTTP Proxy / HTTPS Proxy にプロキシ URL を入力
4. Bypass にプロキシ除外ホストを入力

> **推奨**: Docker Desktop のプロキシは GUI で設定し、`.env` のプロキシ設定はコンテナ内部の通信用として分離管理する。

#### `NO_PROXY` のワイルドカード問題

Windows / Docker Desktop 環境では `NO_PROXY` のワイルドカード指定 (`*.example.com`) が正しく解釈されない場合がある:

```env
# macOS / Linux（ワイルドカード使用可）
NO_PROXY=localhost,127.0.0.1,litellm,gitlab,*.openai.azure.com,*.azuredatabricks.net

# Windows（ワイルドカードが効かない場合はドット始まりで指定）
NO_PROXY=localhost,127.0.0.1,litellm,gitlab,.openai.azure.com,.azuredatabricks.net
```

`.openai.azure.com` のようにドット始まり（アスタリスクなし）で指定すると、そのドメインおよびすべてのサブドメインにマッチする。これは Go の `httpproxy` 実装（Docker で使用）の仕様に準拠しており、Windows でも安定して動作する。

#### PowerShell での環境変数確認

```powershell
# システム環境変数のプロキシ設定を確認
[System.Environment]::GetEnvironmentVariable("HTTP_PROXY", "Machine")
[System.Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Machine")

# 現在のセッションの環境変数を確認
$env:HTTP_PROXY
$env:HTTPS_PROXY
```

### ファイアウォール

dev コンテナは WSL2 内の Linux コンテナとして動作するため、`iptables` ベースのファイアウォール (`init-firewall.sh`) はそのまま正常に動作する。Windows 側のファイアウォール設定を変更する必要はない。

## Podman での利用

Docker の代わりに Podman を使用する場合の設定ガイド。

### Podman 専用 Compose ファイル

Podman 用に `docker-compose.podman.yml` を用意している。Docker 版との主な差分:

| 差分 | Docker (`docker-compose.yml`) | Podman (`docker-compose.podman.yml`) |
|------|------------------------------|--------------------------------------|
| ネットワーク | 暗黙の default ブリッジ | 明示的な `networks.default` (bridge) を定義 |
| ソケットパス | `/var/run/docker.sock` | `/run/podman/podman.sock` |
| volumes オプション | `:delegated` あり | `:delegated` なし（Podman 未サポート） |

#### なぜ明示的なネットワーク定義が必要か

`podman-compose` はデフォルトで **Pod モード** で動作し、全コンテナが同一の Pod 内に配置される。Pod 内のコンテナはネットワーク名前空間を共有するため:

- すべてのコンテナが `localhost` を共有し、ポートが競合する
- サービス名（`litellm`, `gitlab` 等）での DNS 名前解決が機能しない
- `http://litellm:4000` のようなコンテナ間通信が失敗する

`docker-compose.podman.yml` では `networks.default` を `driver: bridge` で明示定義し、各サービスに `networks: [default]` を指定することで、各コンテナが独立したネットワーク名前空間を持ちつつ、サービス名での名前解決が正常に動作する。

### podman-compose のインストール

```bash
pip install podman-compose
```

### 起動・停止

```bash
# 起動（Podman 用ファイルを明示指定）
podman-compose -f docker-compose.podman.yml up -d --build

# 停止
podman-compose -f docker-compose.podman.yml down

# ログ確認
podman-compose -f docker-compose.podman.yml logs -f dev
```

> **tips**: エイリアスを設定すると便利:
> ```bash
> alias pdc='podman-compose -f docker-compose.podman.yml'
> # pdc up -d --build / pdc down / pdc logs -f dev
> ```

### ルートフル実行（推奨）

以下の理由から `sudo podman` でのルートフル実行を推奨:

- dev コンテナのファイアウォール設定に `NET_ADMIN` ケーパビリティが必要
- GitLab Runner が Podman ソケットにアクセスする必要がある
- GitLab CE のボリュームマウントに root 権限が必要な場合がある

```bash
sudo podman-compose -f docker-compose.podman.yml up -d --build
```

### Docker vs Podman 設定対応表

| 項目 | Docker | Podman |
|------|--------|--------|
| Compose ファイル | `docker-compose.yml` | `docker-compose.podman.yml` |
| コマンド | `docker compose` | `podman-compose -f docker-compose.podman.yml` |
| ソケットパス | `/var/run/docker.sock` | `/run/podman/podman.sock` |
| デーモン | Docker daemon (常駐) | デーモンレス |
| ルートレス | Docker Desktop はルートレス | `podman --rootless`（制約あり） |
| Compose 仕様 | Docker Compose V2 (組み込み) | podman-compose (別途インストール) |
| DNS | `127.0.0.11` (内蔵 DNS) | `aardvark-dns` |
| ネットワーク | 暗黙の default bridge | 明示的な bridge 定義が必要 |

### DNS の注意点

Docker は内蔵 DNS（`127.0.0.11`）を使用するが、Podman は `aardvark-dns` を使用する。`init-firewall.sh` の DNS ルールに影響する場合がある:

- Podman 4.0+ では `aardvark-dns` がデフォルトで、コンテナ名による名前解決が自動的に動作する
- ファイアウォールの DNS 許可ルールの調整が必要な場合は、`init-firewall.sh` の DNS 関連の iptables ルールを確認する

### GitLab Runner

Podman 環境での GitLab Runner の設定。`docker-compose.podman.yml` ではソケットパスが Podman 用に設定済み。

Runner 登録時のネットワークモード指定:

```bash
# ネットワーク名を確認
podman network ls

# Runner 登録（ネットワーク名はプロジェクト名に依存）
podman-compose -f docker-compose.podman.yml exec gitlab-runner gitlab-runner register \
  --non-interactive \
  --url http://gitlab \
  --token <TOKEN> \
  --executor docker \
  --docker-image alpine:latest \
  --docker-network-mode m_poc_default
```

Docker executor が動作しない場合は shell executor に変更:

```bash
podman-compose -f docker-compose.podman.yml exec gitlab-runner gitlab-runner register \
  --non-interactive \
  --url http://gitlab \
  --token <TOKEN> \
  --executor shell
```

### VS Code Dev Containers

VS Code の Dev Containers 拡張で Podman を使用するには:

```json
// VS Code settings.json
{
  "dev.containers.dockerPath": "podman",
  "dev.containers.dockerComposePath": "podman-compose"
}
```

> **注意**: Podman での Dev Containers サポートは実験的です。一部の機能が正常に動作しない場合があります。

## プロキシ環境での利用

社内プロキシの背後にある環境で本開発環境を利用する場合の設定手順。

### 1. `.env` にプロキシ設定を追加

`.devcontainer/.env.example` を参考に、`.env` にプロキシ設定を追加:

```env
HTTP_PROXY=http://proxy.example.com:8080
HTTPS_PROXY=http://proxy.example.com:8080
NO_PROXY=localhost,127.0.0.1,litellm,gitlab,gitlab-runner,dev,api.openai.com,*.openai.azure.com,*.cognitiveservices.azure.com,*.azuredatabricks.net,api.anthropic.com
```

### 2. `docker-compose.yml` のプロキシ行をアンコメント

各サービスのコメントアウトされたプロキシ設定を有効化する:

- **litellm**: `environment` のプロキシ行（小文字のみ。大文字は `env_file` 経由で `.env` から自動読み込み）
- **gitlab**: `environment` のプロキシ行
- **gitlab-runner**: `environment` のプロキシ行
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
|---------|------------------|------|
| LLM API にプロキシなしで直接アクセス可能 | `api.openai.com`, `*.openai.azure.com` 等 | デフォルト設定。API 通信がプロキシを迂回 |
| LLM API にプロキシ経由でのみアクセス可能 | Docker 内部のみ (`localhost,litellm,gitlab` 等) | API エンドポイントを NO_PROXY から除外 |

> **大文字・小文字の両方を設定する理由**: `curl` / `wget` は小文字（`http_proxy`）、Python / Go は大文字（`HTTP_PROXY`）を参照する。本設定ではすべてのサービスで両方を設定している。

### Windows でのプロキシ利用

Windows 固有の注意点は [Windows 環境での利用 > プロキシ設定](#プロキシ設定windows-固有の注意点) を参照。主なポイント:

- **Docker Desktop のプロキシ設定**: Settings → Resources → Proxies で GUI から設定する（システム環境変数とは別管理を推奨）
- **`NO_PROXY` のワイルドカード**: `*.example.com` が動作しない場合は `.example.com`（ドット始まり）に置き換える
- **システム環境変数の影響**: Windows にシステムレベルで `HTTP_PROXY` が設定されていると Docker Desktop 自体の通信にも影響する
