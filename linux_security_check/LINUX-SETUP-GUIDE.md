# Linux ホストセキュリティ セットアップガイド

Amazon Linux 2023 (AL2023) / Windows (WSL2) 向けのホストセキュリティ設定ガイド。
macOS 版の `mac_security_check/COMPLETE-SETUP-GUIDE.md` に対応する Linux 版です。
Windows ユーザーは WSL2 上でこのガイドの手順を実行してください（[WSL2 利用ガイド](#windows-wsl2-利用ガイド) を参照）。

## 前提条件

| ツール | 用途 | インストール |
|--------|------|-------------|
| Docker | DevContainer 実行 | `sudo dnf install -y docker` |
| Docker Compose | マルチコンテナ管理 | Docker Desktop または `sudo dnf install -y docker-compose-plugin` |
| jq | JSON 処理（Hooks 用） | `sudo dnf install -y jq` |
| git | バージョン管理 | `sudo dnf install -y git` |
| python3 | サプライチェーンガード | `sudo dnf install -y python3` |
| AWS CLI v2 | Secrets Manager 連携 | [公式ガイド](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |

### オプション（.env 暗号化を使う場合）

| ツール | 用途 | インストール |
|--------|------|-------------|
| age | 暗号化 | [GitHub Releases](https://github.com/FiloSottile/age/releases) |
| sops | 暗号化管理 | [GitHub Releases](https://github.com/getsops/sops/releases) |

### オプション（サプライチェーン対策をホストにも適用する場合）

| ツール | バージョン | 確認コマンド | インストール |
|--------|-----------|-------------|-------------|
| npm | 11.10.0+ | `npm --version` | `npm install -g npm@latest` |
| pip | 26.0+ | `pip --version` | `pip install --upgrade pip` |
| uv | 0.9.17+ | `uv --version` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

---

## セットアップ

### 一括セットアップ（推奨）

```bash
# リポジトリをクローン
git clone <repository-url>
cd claude-dev-env

# 一括セットアップ（OS 自動検出）
bash host_security/setup.sh

# 全自動（確認なし）
bash host_security/setup.sh --yes

# IOC フィードをスキップ（ネットワーク制限環境向け）
bash host_security/setup.sh --skip-ioc

# 状態確認のみ
bash host_security/setup.sh --check
```

### 個別セットアップ

#### 1. Claude Code グローバル設定

```bash
bash mac_security_check/global-claude-setup.sh apply
```

`~/.claude/settings.json` に deny ルール（67 パターン）を適用します。
このスクリプトは Linux でも変更なしで動作します（jq のみ必要）。

#### 2. パッケージマネージャ クールダウン

```bash
bash cooldown_management/local-cooldown-setup.sh
```

npm, pip, uv に 7 日間のクールダウンを設定します。
Linux 版の date コマンド（GNU date）に対応済みです。

#### 3. IOC データベース（オプション）

```bash
bash mac_security_check/threat-intel-updater.sh
```

abuse.ch 等から脅威インテリジェンスデータを取得します。
`curl` が必要です（AL2023 にはデフォルトで含まれます）。

#### 4. systemd タイマー

セットアップスクリプトが自動で登録しますが、手動の場合:

```bash
# ユニットファイルの配置
mkdir -p ~/.config/systemd/user
cp linux_security_check/zui-*.service ~/.config/systemd/user/
cp linux_security_check/zui-*.timer ~/.config/systemd/user/

# __HOME__ プレースホルダーの置換
sed -i "s|__HOME__|$HOME|g" ~/.config/systemd/user/zui-*

# 有効化
systemctl --user daemon-reload
systemctl --user enable --now zui-security-check.timer
systemctl --user enable --now zui-threat-intel-update.timer

# 確認
systemctl --user list-timers
```

> **WSL2 の場合**: systemd が有効でない場合があります。
> `/etc/wsl.conf` に `[boot] systemd=true` を追加して再起動するか、
> cron を代替として使用してください。

#### 5. セキュリティ監査

```bash
bash linux_security_check/claude-code-security-audit-linux.sh
```

---

## 秘密鍵管理

### AWS Secrets Manager（推奨）

AL2023 では AWS Secrets Manager を使用して age 秘密鍵を管理します。

```bash
# 前提: AWS CLI が設定済み、IAM ロールに権限あり
aws sts get-caller-identity

# .env 暗号化セットアップ
bash scripts/setup-env-encryption.sh
```

**必要な IAM 権限:**
```json
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "secretsmanager:CreateSecret",
            "secretsmanager:GetSecretValue",
            "secretsmanager:PutSecretValue",
            "secretsmanager:DescribeSecret"
        ],
        "Resource": "arn:aws:secretsmanager:*:*:secret:claude-devcontainer-*"
    }]
}
```

### フォールバック順位

スクリプトは以下の順で秘密鍵管理を試みます:

1. **AWS Secrets Manager** — `aws` CLI が認証済みの場合
2. **secret-tool (libsecret)** — GUI 環境 / WSL2 向け
3. **ファイルベース** — `~/.config/age/key.txt`（権限 600）

---

## Linux 固有のセキュリティチェック

`linux-supply-chain-check.sh` は以下の Linux 固有チェックを実行します:

| チェック | macOS 対応物 | 説明 |
|---------|-------------|------|
| SELinux 状態 | SIP (csrutil) | `getenforce` で Enforcing を確認 |
| firewalld/iptables | macOS Firewall | ファイアウォール状態の確認 |
| LUKS 暗号化 | FileVault | ディスク暗号化の確認 |
| systemd サービス監査 | Launch Agents | 不審なユーザーサービスの検出 |
| RPM 整合性 | Homebrew doctor | `rpm -V` でパッケージ改ざんを検出 |
| dnf リポジトリ監査 | 非公式 tap | GPG チェックと非公式リポジトリの検出 |
| RPM 所有バイナリ | codesign | `rpm -qf` で非管理バイナリを検出 |
| sudo/権限監査 | TCC (プライバシー) | NOPASSWD 設定と sudo グループの確認 |

共通チェック（npm/pip 監査、IOC、SSH、Git hooks、VS Code 拡張等）は macOS 版と同じです。

---

## SELinux の推奨設定

AL2023 ではデフォルトで SELinux が Enforcing です。

```bash
# 現在の状態確認
getenforce
sestatus

# Enforcing でない場合
sudo setenforce 1
sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
```

Docker を使用する場合、SELinux と Docker の共存設定が必要な場合があります:

```bash
# Docker の SELinux サポート確認
docker info | grep Security
```

---

## Windows (WSL2) 利用ガイド

Windows ユーザーは WSL2 上で Linux パスを利用します。ネイティブ Windows / PowerShell には対応していません。

### WSL2 環境の準備

```powershell
# 管理者 PowerShell で実行
wsl --install -d Ubuntu

# WSL2 を再起動後、Ubuntu ターミナルで以下を実行
sudo apt update && sudo apt install -y jq curl git python3
```

### Docker Desktop の設定

1. Docker Desktop → **Settings** → **General** → **Use the WSL 2 based engine** を有効化
2. Docker Desktop → **Settings** → **Resources** → **WSL Integration** で Ubuntu を有効化
3. メモリ割り当てを **4GB 以上** に設定

### systemd の有効化（定期チェック用）

WSL2 ではデフォルトで systemd が無効です。定期チェック（systemd タイマー）を使う場合:

```bash
# /etc/wsl.conf を編集
sudo tee /etc/wsl.conf > /dev/null << 'EOF'
[boot]
systemd=true
EOF
```

PowerShell で WSL を再起動:
```powershell
wsl --shutdown
```

> systemd を有効化しない場合、セットアップの定期チェックステップはスキップされます。
> セキュリティチェックは手動実行が可能です。

### リポジトリの配置

```bash
# 推奨: WSL2 ファイルシステム内（高速）
cd /home/$USER
git clone <repository-url>
cd claude-dev-env

# 非推奨: /mnt/c/... はパフォーマンスが大幅に低下
```

### 秘密鍵管理

WSL2 では以下の優先順位で秘密鍵を管理します:

1. **secret-tool (libsecret)** — `sudo apt install libsecret-tools` でインストール
2. **ファイルベース** — `~/.config/age/key.txt`（権限 600）

> AWS Secrets Manager は WSL2 からも利用可能です（AWS CLI がインストール・認証済みの場合）。

### 改行コード

リポジトリをクローンする前に Git の改行設定を確認:

```bash
# WSL2 内で設定（LF を維持）
git config --global core.autocrlf input
```

`.sh` ファイルが CRLF になっているとコンテナ内で実行エラーになります。

### WSL2 固有の注意点

| 項目 | 説明 |
|------|------|
| ファイアウォール | DevContainer 内の iptables はそのまま動作。Windows 側の設定変更は不要 |
| VS Code 連携 | VS Code の Remote - WSL 拡張で WSL2 内のプロジェクトを開き、そこから Dev Containers を利用 |
| ネットワーク | WSL2 のネットワークは NAT モード。Docker Desktop が WSL2 バックエンドを使用するため透過的に動作 |
| SELinux | WSL2 では利用不可。セキュリティチェックの SELinux 項目は自動スキップされます |

---

## トラブルシューティング

| 症状 | 原因 | 対処法 |
|------|------|--------|
| `systemctl --user` が失敗 | systemd ユーザーセッション未起動 | `loginctl enable-linger $USER` |
| WSL2 で systemd が使えない | WSL2 のデフォルト設定 | `/etc/wsl.conf` に `[boot] systemd=true` 追加 |
| `aws` コマンドが見つからない | AWS CLI 未インストール | [公式ガイド](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Secrets Manager 権限エラー | IAM ロール不足 | 上記の IAM ポリシーを確認 |
| `jq` が見つからない | 未インストール | `sudo dnf install -y jq` |
| Docker 権限エラー | docker グループ未所属 | `sudo usermod -aG docker $USER` → 再ログイン |
| RPM 検証で差異 | 設定ファイルの変更 | `rpm -V <pkg>` の出力を確認。`c` は設定ファイル変更で正常 |
| WSL2 で `.sh` が実行できない | CRLF 改行 | `git config --global core.autocrlf input` → リポジトリ再クローン |
| WSL2 で Docker が使えない | Docker Desktop 未連携 | Docker Desktop の WSL Integration で対象ディストロを有効化 |
| WSL2 でパフォーマンスが遅い | Windows FS を使用 | `/mnt/c/` ではなく `/home/<user>/` にリポジトリを配置 |
