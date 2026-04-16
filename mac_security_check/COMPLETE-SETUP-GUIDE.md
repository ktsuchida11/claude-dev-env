# Mac サプライチェーン攻撃チェッカー — 完全セットアップガイド

> **関連ドキュメント**:
> - [QUICKSTART.md](../QUICKSTART.md) — DevContainer 環境のクイックスタート
> - [SECURITY-GUIDE.md](../SECURITY-GUIDE.md) — DevContainer 内の 4 層セキュリティ設計
> - [README.md](../README.md) — 環境の全体説明
>
> 統合セットアップ: `bash mac_security_check/setup.sh` で本ガイドの手順を一括実行できます。

## 1. このシステムの全体像

```
┌─────────────────────────────────────────────────────────────────┐
│  外部脅威フィード (abuse.ch / ThreatFox / URLhaus)             │
│  + Claude セキュリティデイリーレポート                           │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
        ┌──────────────────────────────────┐
        │  threat-intel-updater.sh         │  ← 毎日 07:00 自動実行
        │  IOC (脅威指標) を取得・蓄積     │
        └──────────────────┬───────────────┘
                           ▼
        ┌──────────────────────────────────┐
        │  ~/.security-ioc/               │  ← ローカル IOC データベース
        │  - malicious_hashes.txt         │     日々成長する
        │  - bad_domains.txt              │
        │  - malicious_packages.json      │
        │  - threatfox_iocs.json          │
        │  - vuln_packages.txt            │
        │  - tracked_cves.txt             │
        └──────────────────┬───────────────┘
                           ▼
        ┌──────────────────────────────────┐
        │  mac-supply-chain-check.sh       │  ← 毎週月曜 09:00 自動実行
        │  (v2本体 + v3追加モジュール統合) │
        │  全17項目のチェックを実行        │
        └──────────┬───────────┬───────────┘
                   ▼           ▼
        ┌──────────────┐ ┌────────────────┐
        │ Markdown     │ │ macOS 通知     │
        │ レポート     │ │ (CRITICAL時)   │
        └──────────────┘ └────────────────┘
```

---

## 2. ファイル一覧と役割

配布ファイルは以下の通りです。最終的に使うのは **4ファイル** です。

| # | ファイル名 | 役割 | 配置先 |
|---|-----------|------|--------|
| 1 | `mac-supply-chain-check-v2.sh` | メインチェックスクリプト (v2本体) | `~/bin/` |
| 2 | `mac-supply-chain-check-v3-additions.sh` | 追加チェック9項目 (v2にsourceで統合) | `~/bin/` |
| 3 | `threat-intel-updater.sh` | 外部脅威情報の日次取得 | `~/bin/` |
| 4 | `com.sample.security-check.plist` | 週次チェックの launchd 設定 | `~/Library/LaunchAgents/` |
| 5 | `com.sample.threat-intel-update.plist` | 日次IOC更新の launchd 設定 | `~/Library/LaunchAgents/` |

**不要なファイル** (v2+v3 に統合済み):
- `mac-supply-chain-check.sh` (v1) — v2 に置き換え
- `setup-guide.md` (v1用) — この文書に統合
- `setup-guide-v2.md` — この文書に統合
- `v3-additions-guide.md` — この文書に統合

---

## 3. チェック項目一覧 (全17項目)

### v2 本体 (8項目) — 基盤チェック

| # | チェック | 何を見るか |
|---|---------|-----------|
| 1 | macOS システム整合性 | SIP, Gatekeeper, FileVault, Firewall, XProtect |
| 2 | Launch Agents/Daemons | 既知ベンダー以外の常駐プロセス検出 |
| 3 | Homebrew 整合性 | brew doctor, 非公式 tap, 未更新パッケージ |
| 4 | npm/pip 脆弱性監査 | npm audit, pip-audit |
| 5 | IOC データベース照合 | 悪意あるパッケージ / 悪性ドメイン / マルウェアハッシュ / 脆弱パッケージ |
| 6 | アプリ署名検証 | /Applications の codesign チェック |
| 7 | ネットワーク接続 | 非標準ポートの外部接続, DNS設定 |
| 8 | 最近変更されたバイナリ | /usr/local/bin, /opt/homebrew/bin の過去7日変更 |
| 9 | 前回レポートとの差分 | 新規 Launch Agent の検出 |

### v3 追加 (9項目) — 2025-2026年の最新脅威への対応

| # | チェック | 何を見るか | 対応する脅威 |
|---|---------|-----------|-------------|
| A | **Lockdown設定の改ざん** | .npmrc / pip.conf / uv.toml の設定値・所有者・権限 | axios侵害 (postinstall) |
| B | **AI ツール認証情報** | ~/.claude, ~/.cursor 等のパーミッション, .env内APIキー | Shai-Hulud (LLMトークン窃取) |
| C | **MCP サーバー設定** | mcp_config.json の接続先棚卸し | AMOS (AI agent汚染) |
| D | **Git Hooks** | .git/hooks/ の不審スクリプト, グローバルhooksPath | GitHub Actions侵害 |
| E | **SSH 鍵監査** | authorized_keys の変更, 秘密鍵パーミッション | Shai-Hulud (SSH鍵窃取) |
| F | **VS Code/Cursor 拡張** | 拡張数, マーケットプレイス外インストール検出 | 拡張経由のコード実行 |
| G | **macOS TCC 権限** | Full Disk Access / Accessibility / 画面収録 | AMOS (Keychain窃取) |
| H | **既知C2 接続チェック** | sfrclak.com 等への接続, IOC照合 | axios RAT (C2ビーコン) |
| I | **ロックファイル整合性** | lockfile の uncommitted 変更, .gitignore 除外 | 依存関係改ざん |

---

## 4. セットアップ手順

### Step 1: ディレクトリ準備

```bash
mkdir -p ~/bin ~/security-reports ~/.security-ioc
```

### Step 2: スクリプト配置と実行権限付与

```bash
# ダウンロードしたファイルを ~/bin/ にコピー
cp mac-supply-chain-check-v2.sh ~/bin/
cp mac-supply-chain-check-v3-additions.sh ~/bin/
cp threat-intel-updater.sh ~/bin/

# 実行権限を付与
chmod +x ~/bin/mac-supply-chain-check-v2.sh
chmod +x ~/bin/mac-supply-chain-check-v3-additions.sh
chmod +x ~/bin/threat-intel-updater.sh
```

### Step 3: v2 と v3 を統合

v2 のサマリーセクション（`# サマリー` の行）の **直前** に以下の2行を追加してください:

```bash
vim ~/bin/mac-supply-chain-check-v2.sh
```

追加する内容:
```bash
# ★ v3 追加チェックモジュール読み込み
ADDITIONS="$HOME/bin/mac-supply-chain-check-v3-additions.sh"
if [ -f "$ADDITIONS" ]; then
  source "$ADDITIONS"
fi
```

具体的には、v2 の以下の位置に挿入します:

```
（セクション8 最近変更されたバイナリの後）
（セクション9 前回レポートとの差分の後）

# ★ ここに上の2行を追加 ★

# =============================================================================
# サマリー
# =============================================================================
```

### Step 4: プロジェクトディレクトリの設定 (任意)

ロックファイル整合性チェック (項目I) を有効にするには、チェック対象のプロジェクトパスを設定します。

```bash
# ~/.zshrc または ~/.bashrc に追加
export PROJECT_DIRS="$HOME/dev/project1 $HOME/dev/project2 $HOME/dev/mra-chat"
```

### Step 5: 推奨ツールのインストール (任意だが強く推奨)

```bash
# Python パッケージ脆弱性スキャナ
pip install pip-audit --break-system-packages

# (オプション) コンテナ/ファイルシステム脆弱性スキャナ
brew install trivy
```

### Step 6: 初回手動実行でテスト

```bash
# 1) まず IOC データベースを構築
~/bin/threat-intel-updater.sh

# 2) フルチェックを実行
~/bin/mac-supply-chain-check-v2.sh

# 3) レポートを確認
cat ~/security-reports/mac-check-*.md | less
```

初回実行ではいくつかの ⚠️ が出るのが正常です（非公式 tap、パーミッション等）。
レポートを読み、意図した設定であれば問題ありません。

### Step 7: 自動実行の設定 (launchd)

```bash
# plist 内のパスを自分のホームディレクトリに置換して配置
sed "s|__HOME__|$HOME|g" com.sample.threat-intel-update.plist \
  > ~/Library/LaunchAgents/com.sample.threat-intel-update.plist

sed "s|__HOME__|$HOME|g" com.sample.security-check.plist \
  > ~/Library/LaunchAgents/com.sample.security-check.plist

# launchd に登録
launchctl load ~/Library/LaunchAgents/com.sample.threat-intel-update.plist
launchctl load ~/Library/LaunchAgents/com.sample.security-check.plist

# 動作確認（手動トリガー）
launchctl start com.sample.threat-intel-update
launchctl start com.sample.security-check
```

### Step 8: 動作確認

```bash
# IOC 更新ログの確認
cat ~/.security-ioc/update.log

# チェック実行ログの確認
cat ~/security-reports/launchd-stdout.log

# 最新レポートの確認
ls -lt ~/security-reports/mac-check-*.md | head -3
```

---

## 5. 自動実行スケジュール

| 時刻 | 処理 | launchd Label |
|------|------|---------------|
| 毎日 07:00 | 脅威情報取得 → IOC DB 更新 | `com.sample.threat-intel-update` |
| 毎週月曜 09:00 | Mac フルスキャン (17項目) | `com.sample.security-check` |

Mac がスリープ中だった場合、起動後に実行されます。

---

## 6. なぜこのシステムが「成長する」のか

### 成長経路 1: 公開フィードからの自動蓄積

`threat-intel-updater.sh` が毎朝 abuse.ch の3つのフィード (MalwareBazaar, URLhaus, ThreatFox) から IOC を取得し、`~/.security-ioc/` に **累積保存** します。毎日数百〜数千のエントリが追加され、チェック精度が日々向上します。

### 成長経路 2: Claude セキュリティレポートとの連携

Claude に「セキュリティチェックして」と頼むと、既存のセキュリティ脆弱性モニタースキルがデイリーレポート (`~/security-reports/security-report-*.md`) を生成します。`threat-intel-updater.sh` はこのレポートから CVE 番号と影響パッケージ名を **自動抽出** して IOC DB に追加します。

つまり **Claude に毎日チェックしてもらうだけで IOC DB が自動的に育つ** 仕組みです。

### 成長経路 3: 手動 IOC 追加

ニュースや Snyk アラートで新しい悪性パッケージを見つけたら、手動で追加できます:

```bash
# 悪意あるパッケージの追加
vim ~/.security-ioc/malicious_packages.json
# → npm / pip 配列に追加

# 悪性ドメインの追加
echo "malicious-domain.example.com" >> ~/.security-ioc/bad_domains.txt

# マルウェアハッシュの追加
echo "sha256hashvalue..." >> ~/.security-ioc/malicious_hashes.txt
```

---

## 7. 既存の Lockdown 設定との関係

既に導入している npm/uv/pip のロックダウン設定は **防御の第一線** です。
このチェッカーはそれを **補完** します。

```
[防御] npm ignore-scripts=true     ←  攻撃を防ぐ
[防御] pip require-hashes           ←  攻撃を防ぐ
[防御] uv lockfile                  ←  攻撃を防ぐ
                ↕
[検知] チェッカー v2+v3             ←  防御が破られていないか検知する
  - 設定が改ざんされていないか (項目A)
  - 防御をすり抜けた攻撃の痕跡 (項目B〜I)
  - 前回からの差分 (項目9)
```

**防御と検知は別のもの**です。どんなに堅い防御も改ざんされれば意味がありません。
このチェッカーは「防御が正しく機能しているか」を定期的に検証する仕組みです。

---

## 8. 背景: 2025-2026年の主要サプライチェーン攻撃

| 時期 | 攻撃名 | 手法 | 影響 |
|------|--------|------|------|
| 2026-03 | **axios npm 侵害** | メンテナアカウント乗っ取り → postinstall で macOS RAT | 週間1億DLのパッケージ。sfrclak.com:8000 にC2通信 |
| 2026-03 | **LiteLLM PyPI 侵害** | TeamPCP による AWS/GCP/SSH 窃取 | 日間340万DL。3時間で検疫されたが影響大 |
| 2026-02 | **AMOS via OpenClaw** | AI スキルファイル汚染 → macOS Stealer | Keychain + ドキュメント窃取。2,200以上の悪性スキル |
| 2025-09〜11 | **Shai-Hulud** | 自己増殖型 npm ワーム | 500+パッケージ侵害。AI LLM認証トークンが新標的 |
| 2025-03 | **GitHub Actions 侵害** | tj-actions/changed-files 改ざん | ビルドログにシークレット流出 |

---

## 9. 追加チェック項目の詳細

### A. パッケージマネージャ Lockdown 設定の改ざんチェック

**なぜ**: npm の `ignore-scripts=true` が axios 攻撃の最大の防御線。
しかしプロジェクトレベルの `.npmrc` で上書き (`ignore-scripts=false`) されると無効化される。
攻撃者がリポジトリ内に `.npmrc` を仕込むケースも報告されている。

**チェック内容**:
- ~/.npmrc の ignore-scripts=true が維持されているか
- pip.conf の trusted-host が公式 PyPI 以外を指していないか
- uv の index-url が正当か
- 設定ファイルの所有者・パーミッション

### B. AI ツール認証情報の監査

**なぜ**: Shai-Hulud 攻撃で **Claude, Gemini, Q の認証情報が標的になった**ことが確認されている。
AI ツールは開発環境全体にアクセスできるため、トークンが漏洩すると被害が甚大。

**チェック内容**:
- ~/.claude, ~/.cursor, ~/.config/github-copilot 等のパーミッション
- .env ファイルに平文の API キーが含まれていないか
- 最近の変更日時（不正アクセスの兆候）

### C. MCP サーバー設定の棚卸し

**なぜ**: AMOS の OpenClaw 攻撃は MCP と同じ構造。
悪意のある MCP サーバーが接続されていると、Claude Code 経由でシステム全体が危険に。

**チェック内容**:
- mcp_config.json の接続先一覧
- 見覚えのないサーバーの有無
- 環境変数に渡されているクレデンシャルの種類

### D. Git Hooks チェック

**なぜ**: `git clone` → `.git/hooks/post-checkout` が自動実行される。
攻撃者がリポジトリに仕込んだ hook 経由でマルウェアが実行されるケースがある。

**チェック内容**:
- .sample 以外のアクティブな hook の一覧
- curl/wget/eval 等の危険コマンドの有無
- グローバル core.hooksPath の設定

### E. SSH 鍵の監査

**なぜ**: Shai-Hulud は SSH 鍵を窃取対象に含む。authorized_keys に鍵が追加されていれば永続的なバックドア。

**チェック内容**:
- authorized_keys の鍵数と最終変更日
- 秘密鍵のパーミッション (600 必須)
- 過去7日の変更検出

### F. VS Code / Cursor 拡張機能

**なぜ**: 拡張機能はファイルシステム全体にアクセスできる。
マーケットプレイス外からの直接インストールは署名検証がない。

**チェック内容**:
- インストール済み拡張の総数
- 過去7日の新規/更新拡張
- マーケットプレイス外インストールの検出

### G. macOS TCC 権限監査

**なぜ**: Full Disk Access を持つアプリは全ファイルにアクセス可能。
AMOS は Keychain からクレデンシャルを窃取する際に権限を悪用。

**チェック内容**:
- Full Disk Access / Accessibility / 画面収録の許可アプリ一覧
- 不要な権限の取り消しリマインド

### H. 既知 C2 アクティブ接続チェック

**なぜ**: axios 侵害の RAT は sfrclak.com:8000 に60秒毎にビーコンを送信。
アクティブな接続を即座に検出できれば被害を最小化できる。

**チェック内容**:
- ハードコードされた既知 C2 ドメインへの接続
- IOC DB の悪性ドメインとの照合
- /etc/hosts の改ざん

### I. ロックファイル整合性

**なぜ**: ロックファイルの改ざんにより、意図しないバージョンの依存関係がインストールされる。
.gitignore に含まれていると変更が追跡されない。

**チェック内容**:
- uncommitted なロックファイル変更
- .gitignore でロックファイルが除外されていないか

---

## 10. カスタマイズ

### 既知ベンダーリストの追加

v2 の `KNOWN_PREFIXES` に自分が使うアプリのプレフィックスを追加すると、
Launch Agent の誤検出を減らせます:

```bash
KNOWN_PREFIXES="com.apple.|com.google.|...|com.sample.|your.app."
```

### チェック頻度の変更

毎日チェックに変更する場合、plist の `StartCalendarInterval` から `Weekday` を削除:

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>9</integer>
    <key>Minute</key>
    <integer>0</integer>
</dict>
```

### IOC フィードの追加

`threat-intel-updater.sh` に新しいセクションを追加するだけで対応可能:
- CIRCL MISP feeds (https://www.circl.lu/doc/misp/)
- AlienVault OTX (https://otx.alienvault.com/)
- Feodo Tracker (https://feodotracker.abuse.ch/)

### SBOM (Software Bill of Materials) 連携

将来的には SBOM を生成して依存関係を完全に可視化することも推奨:
```bash
# Node.js プロジェクト
npx @cyclonedx/cyclonedx-npm --output-file sbom.json

# Python プロジェクト  
pip install cyclonedx-bom
cyclonedx-py environment -o sbom.json
```

---

## 11. 推奨運用フロー (最終まとめ)

```
┌─────────────────────────────────────────────────────────────┐
│  毎日                                                       │
│  07:00  threat-intel-updater.sh が自動実行                  │
│         → IOC DB が毎日成長                                 │
│  随時   Claude に「セキュリティチェックして」               │
│         → デイリーレポート生成 → IOC DB に自動反映          │
├─────────────────────────────────────────────────────────────┤
│  毎週 月曜                                                  │
│  09:00  mac-supply-chain-check (v2+v3) が自動実行           │
│         → 全17項目チェック → レポート生成                   │
│         → CRITICAL があれば macOS 通知                      │
├─────────────────────────────────────────────────────────────┤
│  随時 (手動)                                                │
│  - 新パッケージ追加時: lockfile diff 確認                   │
│  - 新 MCP サーバー接続時: 接続先の信頼性確認               │
│  - ニュースで新脅威を見たら: IOC DB に手動追加             │
│  - レポートの ⚠️ を確認し、必要に応じて対処                │
├─────────────────────────────────────────────────────────────┤
│  月次 (推奨)                                                │
│  - macOS システム設定 > プライバシーとセキュリティ 確認     │
│  - 使っていない Chrome 拡張 / VS Code 拡張を削除           │
│  - KNOWN_PREFIXES / malicious_packages.json の更新          │
└─────────────────────────────────────────────────────────────┘
```

---

## 12. トラブルシューティング

### launchd が動かない

```bash
# 状態確認
launchctl list | grep com.sample

# エラーログ確認
cat ~/security-reports/launchd-stderr.log
cat ~/.security-ioc/launchd-stderr.log

# 再登録
launchctl unload ~/Library/LaunchAgents/com.sample.security-check.plist
launchctl load ~/Library/LaunchAgents/com.sample.security-check.plist
```

### IOC 更新が失敗する

```bash
# ネットワーク接続確認
curl -sf "https://bazaar.abuse.ch/export/txt/sha256/recent/" | head -5

# 手動実行でエラーを確認
~/bin/threat-intel-updater.sh 2>&1 | tail -20
```

### TCC データベースにアクセスできない

macOS のバージョンによっては TCC DB への直接アクセスが制限されます。
その場合は `システム設定 > プライバシーとセキュリティ` で手動確認してください。

---

_このドキュメントはセキュリティ運用ガイドとして作成されました。_
_最終更新: 2026年4月9日_
