# Proxy 環境での Claude Code (バイナリ版) DevContainer 起動手順書

本書は、社内 Proxy 環境下で本リポジトリの DevContainer を起動し、Claude Code の **バイナリ版** を動作させるための手順書（たたき台）です。既存リポジトリのファイルには触らず、**オーバーレイ用ファイルだけを追加** する方針でまとめています。

## 前提

- 社内 Proxy 経由でのみ外部 HTTPS に出られる環境
- Claude Code は **バイナリ版を維持**（サプライチェーン観点で npm 版は使わない）
- Bun ネイティブ `fetch()` が `HTTP_PROXY` 系環境変数を無視する既知の制約に対処する
- 経路: `Bun fetch → http://litellm:4000 (Dockerブリッジ内) → httpx (Proxy尊重) → 社内Proxy → api.anthropic.com`
- 既存リポジトリには手を入れず、オーバーレイファイルだけを追加する

## 既知のバグ: Bun `fetch()` が Proxy 環境変数を無視する

Claude Code のネイティブバイナリ版は内部で 2 系統の HTTP クライアントを使っている。

- **axios + `https-proxy-agent`** … OAuth・認証・自己更新チェック・一部のダウンロード処理。`HTTP_PROXY / HTTPS_PROXY` を正しく解釈する。
- **Bun ネイティブ `fetch()`** … Anthropic API へのメッセージ送信・SSE ストリーミング。Bun ランタイム自体が `HTTP_PROXY/HTTPS_PROXY` を参照しないため、直接接続しようとして Proxy の手前で 503 になる。

このため「インストール（ダウンロード）はできるが、モジュールがインターネット接続するタイミングで 503」という症状が出る。本手順書では **LiteLLM をゲートウェイとして挟む** ことでこの問題を回避する。

---

## Step 0. 事前準備（ホスト側で確認）

- 社内 Proxy の URL / 認証要否: 例 `http://proxy.corp.example:8080`
- Proxy がユーザー認証を要求する場合、`http://user:pass@proxy...:8080` 形式で扱えるか、Kerberos/NTLM 必須かを確認（後者なら手前に `cntlm` を立てる別手順が必要）
- 社内 Proxy が TLS インスペクション（MITM）しているか。している場合は社内 CA 証明書 `corporate-ca.crt` を入手
- `proxy.corp.example` が `dev` コンテナ内から名前解決できるか、あるいは IP 直指定が必要か

---

## Step 1. `.env.proxy` の追加

既存 `.env` を直接編集せず、`.env.proxy` を別ファイルとして用意し、`docker compose --env-file` で重ねる。

```dotenv
# .env.proxy

# --- Proxy ---
HTTP_PROXY=http://proxy.corp.example:8080
HTTPS_PROXY=http://proxy.corp.example:8080
NO_PROXY=localhost,127.0.0.1,litellm,host.docker.internal,172.16.0.0/12,.corp.example

# --- Claude Code を LiteLLM 経由に固定 ---
ANTHROPIC_BASE_URL=http://litellm:4000
ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}

# --- ファイアウォールはまず無効化して疎通確認 ---
ENABLE_FIREWALL=false
```

`.gitignore` に `.env.proxy` を追加しておく。

---

## Step 2. Compose オーバーレイ `docker-compose.proxy.yml`

既存 `docker-compose.yml` には触らず、オーバーレイファイルを追加する。

```yaml
# docker-compose.proxy.yml
services:
  litellm:
    build:
      args:
        HTTP_PROXY: ${HTTP_PROXY}
        HTTPS_PROXY: ${HTTPS_PROXY}
        NO_PROXY: ${NO_PROXY}
    environment:
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=${NO_PROXY}
      - http_proxy=${HTTP_PROXY}
      - https_proxy=${HTTPS_PROXY}
      - no_proxy=${NO_PROXY}

  dev:
    build:
      # ビルド時のみ Proxy を使う（バイナリ DL、apt、npm、pip 用）
      args:
        HTTP_PROXY: ${HTTP_PROXY}
        HTTPS_PROXY: ${HTTPS_PROXY}
        NO_PROXY: ${NO_PROXY}
    environment:
      # ランタイムには Proxy を渡さない（Bun fetch が中途半端に絡むのを避ける）
      # 行き先を LiteLLM に固定
      - ANTHROPIC_BASE_URL=http://litellm:4000
      - ANTHROPIC_AUTH_TOKEN=${LITELLM_MASTER_KEY}
```

起動コマンド:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.proxy.yml \
  --env-file .env --env-file .env.proxy \
  up -d --build
```

### 設計ポイント

- **ビルド時だけ** Proxy を使わせて curl/apt/npm/pip を通す
- **ランタイムでは** `dev` に Proxy 変数を一切渡さない。Bun は Proxy を見ないが、行き先が `http://litellm:4000` なのでそもそも Proxy が不要
- LiteLLM コンテナ内の httpx は `HTTPS_PROXY` を尊重して Anthropic 等に到達する

---

## Step 3. Dockerfile オーバーレイ（MITM 環境のみ）

社内 Proxy が TLS インスペクションしている場合のみ必要。CA を注入しないと curl/npm/pip/Playwright の TLS 検証が失敗する。

`.devcontainer/Dockerfile.proxy-overlay`（案）:

```dockerfile
FROM <既存 Dockerfile から生成したイメージタグ>

USER root
COPY corporate-ca.crt /usr/local/share/ca-certificates/corporate-ca.crt
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt
USER node
```

`docker-compose.proxy.yml` 側で `dev.build.dockerfile` を切り替えて使う。MITM していない環境では本 Step はスキップする。

---

## Step 4. 起動と疎通確認

### 4-1. ビルドが通るか

```bash
docker compose -f docker-compose.yml -f docker-compose.proxy.yml \
  --env-file .env --env-file .env.proxy build dev litellm
```

失敗しやすい箇所: `sops` / `age` / `git-delta` / JDTLS の curl、`apt-get`、`npm install -g`、`pip install`、`playwright install chromium`。TLS エラーが出る場合は Step 3 の CA 注入が必要。

### 4-2. LiteLLM が Anthropic に到達できるか

```bash
docker compose exec litellm sh -lc 'env | grep -i proxy'
docker compose exec litellm sh -lc 'curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/'
```

401/403 などが返ってくれば Proxy 越えは成功（200 は返らないのが正常）。タイムアウトの場合は Proxy 設定か `NO_PROXY` の抜けを疑う。

### 4-3. dev コンテナから LiteLLM への内部通信

```bash
docker compose exec dev sh -lc 'curl -sS -o /dev/null -w "%{http_code}\n" http://litellm:4000/health/liveliness'
docker compose exec dev sh -lc 'env | grep -i proxy || echo "no proxy vars (OK)"'
```

200 が返ればブリッジ内通信 OK。`dev` コンテナ内に Proxy 変数が **残っていない** ことを確認する。

### 4-4. Claude Code バイナリ本体

```bash
docker compose exec dev claude --version
docker compose exec dev sh -lc 'echo $ANTHROPIC_BASE_URL; echo $ANTHROPIC_AUTH_TOKEN | head -c 8'
docker compose exec dev claude
```

503 / connection error が出たら行き先が本当に `http://litellm:4000` になっているかを確認する。

---

## Step 5. ファイアウォールを段階的に戻す

Step 1 で `ENABLE_FIREWALL=false` にしているので、Step 4 まで完全に動くことを確認してから戻す。

### 方針

`init-firewall.sh` は DNS→IP 解決方式なので Proxy 環境と相性が悪い。戻すときは許可先を絞る:

- `dev` コンテナからの外向き通信は原則 `litellm:4000`（= `172.16.0.0/12` 宛）のみで足りる
- GitHub / npm / pypi などはビルド時に通っていれば、ランタイムではほぼ不要
- どうしてもランタイムで外に出したい MCP サーバーがあれば、その分だけ例外許可する

### 手順

1. `.env.proxy` の `ENABLE_FIREWALL=false` を外す
2. まずそのまま再起動し、`postStartCommand` 内の `init-firewall.sh` が `CRITICAL_DOMAINS` の解決で落ちないかを見る
3. 社内 DNS で `api.anthropic.com` 等が解決できない場合は、`init-firewall.sh` を **直接いじらず** オーバーレイ版を bind mount する

`docker-compose.proxy.yml` に追加する例:

```yaml
dev:
  volumes:
    - ./overlays/init-firewall.proxy.sh:/usr/local/bin/init-firewall.sh:ro
```

`overlays/init-firewall.proxy.sh` の方針:

- `CRITICAL_DOMAINS` チェックを `curl -x $HTTPS_PROXY https://api.anthropic.com/` の HTTP コード確認に差し替え
- `ALL_DOMAINS` のループは削除（直接通信しないため）
- 許可対象: localhost、`172.16.0.0/12`、`HOST_NETWORK`、社内 Proxy の IP:Port のみ
- GitHub meta 取得部 (`curl https://api.github.com/meta`) は Proxy 経由に変更するか丸ごと削除

---

## Step 6. フォールバック: redsocks による透過 Proxy

`dev` コンテナから LiteLLM 以外にも **どうしても** 外部へ出したいもの（GitHub MCP、`gh` コマンド、Playwright の実ブラウジング等）が発生した場合の選択肢。本手順書ではスコープ外とし、ポインタのみ残す。

- `apt install redsocks` を Dockerfile オーバーレイで追加
- `redsocks.conf` をマウント
- `init-firewall.sh` のオーバーレイに `iptables -t nat ... REDIRECT --to-ports 12345` を追加
- L4 レベルで Bun を騙して Proxy に流す

トレードオフ: アタックサーフェスが広がる代わりに互換性が上がる。

---

## ロールバック手順

既存環境を汚さないための撤収方法:

```bash
docker compose -f docker-compose.yml -f docker-compose.proxy.yml down
rm .env.proxy docker-compose.proxy.yml
# 追加していれば
rm -rf overlays/ .devcontainer/Dockerfile.proxy-overlay
```

元のリポジトリは `git status` でクリーンのまま保たれる。

---

## チェックリスト

- [ ] `.env.proxy` を作成
- [ ] `docker-compose.proxy.yml` を作成
- [ ] （MITM なら）社内 CA を入手して `Dockerfile.proxy-overlay` を作成
- [ ] `ENABLE_FIREWALL=false` でまずビルド & 起動
- [ ] `litellm` → 社内 Proxy → Anthropic の疎通を curl で確認
- [ ] `dev` → `litellm:4000` の疎通を curl で確認
- [ ] `claude --version` と簡単な対話で Claude Code 本体を確認
- [ ] 問題なければ `ENABLE_FIREWALL=true` に戻し、必要なら `init-firewall.sh` のオーバーレイを追加
- [ ] 撤収時は `down` + オーバーレイファイル削除

---

## 補足: なぜこの構成なのか

- **npm 版を使わない**: サプライチェーン攻撃リスクを避けるためバイナリ版を維持
- **Bun fetch の Proxy 無視問題**: バイナリ側を改修できないので、行き先を Proxy 不要な内部ネットワーク (`litellm:4000`) に固定して回避
- **LiteLLM が Proxy を肩代わり**: httpx ベースなので `HTTPS_PROXY` を正しく尊重する
- **`dev` にランタイム Proxy を渡さない**: Bun が中途半端に変数を読んで不安定になるのを避け、かつ `dev` から外部への直接通信経路を作らないことでアタックサーフェスを最小化
- **オーバーレイ方針**: 既存リポジトリを汚さず、検証と撤収が容易
