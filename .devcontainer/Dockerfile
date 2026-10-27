# ベースイメージを SHA256 ダイジェストでピン留め（サプライチェーン対策）
# Trixie (Debian 13, glibc 2.41) を採用。Bookworm (glibc 2.36) では rtk arm64 バイナリが
# GLIBC_2.39 必須のため実行不可だった経緯による（amd64 は musl 静的なので独立）。
# Node はパッチバージョンまでタグで明示する（.github/workflows/devcontainer-version-update.yml が同一メジャー内で自動更新）。
# -slim を採用（フル版の buildpack-deps 由来パッケージによる脆弱性を削減。必要なものは Layer 1 で明示導入）。
# 更新時: docker pull node:<ver>-trixie-slim && docker inspect --format='{{index .RepoDigests 0}}' node:<ver>-trixie-slim
FROM node:24.22.1-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea

ARG TZ
ENV TZ="$TZ"

# Proxy settings for build time (uncomment if behind a corporate proxy)
# ARG HTTP_PROXY
# ARG HTTPS_PROXY
# ARG NO_PROXY
# ENV HTTP_PROXY=${HTTP_PROXY} \
#     HTTPS_PROXY=${HTTPS_PROXY} \
#     NO_PROXY=${NO_PROXY} \
#     http_proxy=${HTTP_PROXY} \
#     https_proxy=${HTTPS_PROXY} \
#     no_proxy=${NO_PROXY}

# Supply chain: ビルド時の npm にもクールダウンを適用
# node:24 は npm 11.x 同梱のため min-release-age が利用可能
# workspace/.npmrc はビルド時にマウントされないため、グローバル設定で適用
# 緊急時は --build-arg NPM_MIN_RELEASE_AGE=0 で待機なしビルド可能
ARG NPM_MIN_RELEASE_AGE=7
RUN npm config set -g ignore-scripts true && \
  npm config set -g save-exact true && \
  npm config set -g min-release-age ${NPM_MIN_RELEASE_AGE}

# --- Layer 1: 基本開発ツール ---
# ベースは -slim のため、フルイメージ (buildpack-deps) に含まれていたもののうち必要なものを明示する:
#   dirmngr (gpg --recv-keys) / openssh-client (git over SSH) / xz-utils (.tar.xz 展開)
# gcc/make 等のビルドツールは脆弱性面を減らすため入れない。ネイティブ拡張のビルドが必要なら build-essential を追加すること。
RUN apt-get update && apt-get install -y --no-install-recommends \
  dirmngr \
  openssh-client \
  xz-utils \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  bubblewrap \
  socat \
  gnome-keyring \
  dbus-x11 \
  libsecret-1-dev \
  ripgrep \
  postgresql-client \
  jq \
  nano \
  vim \
  python3 \
  python3-pip \
  python3-venv \
  age \
  ca-certificates \
  curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*


# --- Terraform 開発ツール群（GPG 署名検証 / SHA256 検証） ---
# 信頼の起点:
#   - terraform / aws cli   : HashiCorp / AWS の PGP 署名（fingerprint を ARG で固定）
#   - docker / temurin (APT) : 公式 APT リポジトリ（署名鍵の fingerprint を ARG で固定）
#   - tflint / terraform-docs / trivy / gitleaks / sops / rtk / git-delta / zsh-in-docker :
#       アーキテクチャ別 SHA256 を ARG に直書き（固定後のリリース差し替えを検出するため）
# 同一リリース内の checksums ファイルとの照合だけでは、リリース自体が乗っ取られた場合
# （例: 2026-03 の trivy 侵害）にバイナリと checksums を同時に差し替えられて検出できない。
# バージョン更新時は SHA ARG も必ず差し替えること（公式 checksums との一致を確認した値を使う）。
# GPG fingerprint は鍵ローテーション時のみ更新が必要。

# --- 1. Terraform CLI (HashiCorp PGP 署名検証 + SHA256) ---
# HashiCorp PGP fingerprint: https://www.hashicorp.com/trust/security
ARG TERRAFORM_VERSION=1.16.6
ARG HASHICORP_PGP_FINGERPRINT=C874011F0AB405110D02105534365D9472D7468F
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  cd /tmp; \
  ZIP="terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"; \
  curl -fsSLo "${ZIP}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${ZIP}"; \
  curl -fsSLo SHA256SUMS "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
  curl -fsSLo SHA256SUMS.sig "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"; \
  gpg --keyserver keyserver.ubuntu.com --recv-keys "${HASHICORP_PGP_FINGERPRINT}"; \
  gpg --verify SHA256SUMS.sig SHA256SUMS; \
  grep "linux_${ARCH}.zip" SHA256SUMS | sha256sum -c -; \
  unzip "${ZIP}" -d /usr/local/bin/; \
  rm "${ZIP}" SHA256SUMS SHA256SUMS.sig; \
  terraform version

# --- 2. AWS CLI v2 (AWS 公式 PGP 署名検証) ---
# AWS CLI Public Key: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
ARG AWS_PGP_FINGERPRINT=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  if [ "${ARCH}" = "arm64" ]; then AWS_ARCH=aarch64; else AWS_ARCH=x86_64; fi; \
  cd /tmp; \
  curl -fsSLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"; \
  curl -fsSLo awscliv2.sig "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip.sig"; \
  gpg --keyserver keyserver.ubuntu.com --recv-keys "${AWS_PGP_FINGERPRINT}"; \
  gpg --verify awscliv2.sig awscliv2.zip; \
  unzip -q awscliv2.zip; \
  ./aws/install; \
  rm -rf aws awscliv2.zip awscliv2.sig; \
  aws --version

# --- 2b. AWS Session Manager Plugin (EC2 への SSM 経由接続用) ---
# `aws ssm start-session` 用クライアントプラグイン。
# バージョン固定 + SHA256 ピン留め + AWS 公式 PGP 署名 (.deb.sig) で検証する。
# 他の鍵による署名を受け入れないよう、専用の一時キーリング (GNUPGHOME) に SSM の鍵のみを入れて検証する。
# 公開鍵は keyserver に登録されておらず AWS ドキュメント上でのみ配布されているため、
# session-manager-plugin.pub としてリポジトリに同梱し、fingerprint と鍵が 1 本のみであることを照合してから使う。
# PGP fingerprint / 公開鍵ファイルは鍵ローテーション時のみ更新が必要。
# Refs: https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-linux-verify-signature.html
ARG SSM_PLUGIN_VERSION=1.2.896.0
ARG SSM_PLUGIN_SHA256_AMD64=53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e
ARG SSM_PLUGIN_SHA256_ARM64=914eeca87b18b55356c58be197080f73742b3ca60d3823f0a45670dc9056aa9c
ARG SSM_PLUGIN_PGP_FINGERPRINT=7959637124CE093AD501D47A2C4D4AFF6F6757EE
COPY session-manager-plugin.pub /tmp/session-manager-plugin.pub
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) SSM_ARCH=ubuntu_64bit; SHA=${SSM_PLUGIN_SHA256_AMD64} ;; arm64) SSM_ARCH=ubuntu_arm64; SHA=${SSM_PLUGIN_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  BASE="https://s3.amazonaws.com/session-manager-downloads/plugin/${SSM_PLUGIN_VERSION}/${SSM_ARCH}"; \
  curl -fsSLo session-manager-plugin.deb "${BASE}/session-manager-plugin.deb"; \
  echo "${SHA}  session-manager-plugin.deb" | sha256sum -c -; \
  curl -fsSLo session-manager-plugin.deb.sig "${BASE}/session-manager-plugin.deb.sig"; \
  export GNUPGHOME="$(mktemp -d)"; \
  test "$(gpg --show-keys --with-colons /tmp/session-manager-plugin.pub | awk -F: '$1=="pub"{n++} $1=="fpr"&&!f{f=$10} END{print n":"f}')" = "1:${SSM_PLUGIN_PGP_FINGERPRINT}"; \
  gpg --batch --import /tmp/session-manager-plugin.pub; \
  gpg --batch --verify session-manager-plugin.deb.sig session-manager-plugin.deb; \
  rm -rf "${GNUPGHOME}" /tmp/session-manager-plugin.pub; \
  dpkg -i session-manager-plugin.deb; \
  rm session-manager-plugin.deb session-manager-plugin.deb.sig; \
  session-manager-plugin

# --- 3. tflint (SHA256 ピン留め、公式 checksums.txt と照合済みの値) ---
ARG TFLINT_VERSION=0.64.0
ARG TFLINT_SHA256_AMD64=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537
ARG TFLINT_SHA256_ARM64=560da89aacf59389d4eb029730dd5b109b7288096c32f2726a0d9e783a5ea8eb
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) SHA=${TFLINT_SHA256_AMD64} ;; arm64) SHA=${TFLINT_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  ZIP="tflint_linux_${ARCH}.zip"; \
  curl -fsSLo "${ZIP}" "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${ZIP}"; \
  echo "${SHA}  ${ZIP}" | sha256sum -c -; \
  unzip "${ZIP}" -d /usr/local/bin/; \
  rm "${ZIP}"; \
  tflint --version

# --- 4. terraform-docs (SHA256 ピン留め、公式 .sha256sum と照合済みの値) ---
ARG TERRAFORM_DOCS_VERSION=0.24.0
ARG TERRAFORM_DOCS_SHA256_AMD64=9005daf969de0b50134493a2c00078b49f5f5b39d021cda7c89bf4d4f3d776d3
ARG TERRAFORM_DOCS_SHA256_ARM64=d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) SHA=${TERRAFORM_DOCS_SHA256_AMD64} ;; arm64) SHA=${TERRAFORM_DOCS_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  TGZ="terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${ARCH}.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/${TGZ}"; \
  echo "${SHA}  ${TGZ}" | sha256sum -c -; \
  tar -xzf "${TGZ}" -C /usr/local/bin/ terraform-docs; \
  rm "${TGZ}"; \
  terraform-docs --version

# --- 5. trivy (SHA256 ピン留め、公式 checksums と照合済みの値) ---
# 2026-03 にサプライチェーン攻撃 (CVE-2026-33634, v0.69.4 が改ざん) を受けているため、
# 未固定で最新を取り込まずバージョンと SHA256 を明示する。更新時はリリースノートとアドバイザリを確認すること。
# APT リポジトリは distro コードネーム別の反映が遅れ版指定で取得できないことがあるため GitHub Release を使う。
# 0.76.1 は公開 7 日未満だが、eMudhra 中間 CA 鍵漏えいへのセキュリティ修正のためクールダウンの例外とする。
ARG TRIVY_VERSION=0.76.1
ARG TRIVY_SHA256_AMD64=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
ARG TRIVY_SHA256_ARM64=e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) TV_ARCH=64bit; SHA=${TRIVY_SHA256_AMD64} ;; arm64) TV_ARCH=ARM64; SHA=${TRIVY_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  TGZ="trivy_${TRIVY_VERSION}_Linux-${TV_ARCH}.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TGZ}"; \
  echo "${SHA}  ${TGZ}" | sha256sum -c -; \
  tar -xzf "${TGZ}" -C /usr/local/bin/ trivy; \
  rm "${TGZ}"; \
  trivy --version

# --- 6. gitleaks (SHA256 ピン留め、公式 checksums と照合済みの値) ---
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA256_AMD64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ARG GITLEAKS_SHA256_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) GL_ARCH=x64; SHA=${GITLEAKS_SHA256_AMD64} ;; arm64) GL_ARCH=arm64; SHA=${GITLEAKS_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  TGZ="gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${TGZ}"; \
  echo "${SHA}  ${TGZ}" | sha256sum -c -; \
  tar -xzf "${TGZ}" -C /usr/local/bin/ gitleaks; \
  rm "${TGZ}"; \
  gitleaks version

# --- SOPS（.env 暗号化・復号バックエンド、SHA256 ピン留め） ---
# SOPS は CNCF（旧 Mozilla）の getsops/sops 公式バイナリを GitHub release から取得
# age 本体は distro パッケージで導入済み（Layer 1 参照）
ARG SOPS_VERSION=3.13.3
ARG SOPS_SHA256_AMD64=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
ARG SOPS_SHA256_ARM64=53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) SHA=${SOPS_SHA256_AMD64} ;; arm64) SHA=${SOPS_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  BIN="sops-v${SOPS_VERSION}.linux.${ARCH}"; \
  curl -fsSLo "${BIN}" "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/${BIN}"; \
  echo "${SHA}  ${BIN}" | sha256sum -c -; \
  install -m0755 "${BIN}" /usr/local/bin/sops; \
  rm "${BIN}"; \
  sops --version

# --- rtk（CLI 出力圧縮プロキシ、LLM トークン削減用） ---
# 個人メンテのため SHA256 ピン留めで導入。signature/attestation は未発行のため
# checksums.txt と GitHub TLS が信頼アンカー。RTK_VERSION 更新時は両 SHA を必ず差し替えること。
# 取得元: https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/checksums.txt
# arm64 は musl ビルドが無いため glibc 版を使用（base image が glibc なので問題なし）
# ライセンス: 1.0.0 以降はデフォルトバイナリに BUSL-1.1 (rtk-engine) が含まれ、第三者への
# 商用提供に制約があるため 0.x 系に留める。0.52.0 は Apache-2.0（LICENSE / Cargo.toml で確認、
# engine/ 無し）。イメージを配布する場合は Apache-2.0 の条件に従い LICENSE を同梱すること。
ARG RTK_VERSION=0.52.0
ARG RTK_SHA256_AMD64=46765d4e570ccb3d759e95bcec11feb42fceed5ab2453eac8d787f81d4a0cdab
ARG RTK_SHA256_ARM64=b1de881a0381f1f059ce9dbb0cfb97e0f94f22460965f39aaff77b2956024fa9
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) TARGET=x86_64-unknown-linux-musl; SHA=$RTK_SHA256_AMD64 ;; \
    arm64) TARGET=aarch64-unknown-linux-gnu;  SHA=$RTK_SHA256_ARM64 ;; \
    *) echo "rtk: unsupported arch $ARCH" >&2; exit 1 ;; \
  esac && \
  curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/rtk-${TARGET}.tar.gz" -o /tmp/rtk.tgz && \
  echo "${SHA}  /tmp/rtk.tgz" | sha256sum -c - && \
  tar -xzf /tmp/rtk.tgz -C /tmp && \
  install -m0755 /tmp/rtk /usr/local/bin/rtk && \
  rm -f /tmp/rtk.tgz /tmp/rtk

# --- Layer 2: ネットワーク・ファイアウォール ---
RUN apt-get update && apt-get install -y --no-install-recommends \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Layer 3: ブラウザ依存ライブラリ（Playwright 用） ---
RUN apt-get update && apt-get install -y --no-install-recommends \
  libnss3 \
  libatk-bridge2.0-0 \
  libdrm2 \
  libxcomposite1 \
  libxdamage1 \
  libxrandr2 \
  libgbm1 \
  libxkbcommon0 \
  libpango-1.0-0 \
  libasound2 \
  libatspi2.0-0 \
  libcups2 \
  libdbus-1-3 \
  libx11-xcb1 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Java environment (optional, controlled by ENABLE_JAVA build arg) ---
# Java を使わないプロジェクトのビルドを高速化するためデフォルトは無効。
# 有効化するには docker compose build --build-arg ENABLE_JAVA=true もしくは
# .env で ENABLE_JAVA=true を設定する。
ARG ENABLE_JAVA=false

# Install Java (Eclipse Temurin JDK 21)
# APT 署名鍵は fingerprint を照合し、鍵が 1 本のみであることも確認してから登録する。
ARG ADOPTIUM_GPG_FINGERPRINT=3B04D753C9050D9A5D343F39843C48A565F8F04B
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  curl -fsSLo /tmp/adoptium.asc https://packages.adoptium.net/artifactory/api/gpg/key/public \
  && test "$(gpg --show-keys --with-colons /tmp/adoptium.asc | awk -F: '$1=="pub"{n++} $1=="fpr"&&!f{f=$10} END{print n":"f}')" = "1:${ADOPTIUM_GPG_FINGERPRINT}" \
  && install -m 0755 -d /etc/apt/keyrings \
  && gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg /tmp/adoptium.asc \
  && rm /tmp/adoptium.asc \
  && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends temurin-21-jdk \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && ln -s /usr/lib/jvm/temurin-21-jdk-* /usr/lib/jvm/temurin-21-jdk; \
  fi
ENV JAVA_HOME=/usr/lib/jvm/temurin-21-jdk

# Install Maven (SHA512 公式 .sha512)
ARG MAVEN_VERSION=3.10.0
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  set -eux; \
  cd /tmp; \
  TGZ="apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/${TGZ}"; \
  echo "$(curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/${TGZ}.sha512" | awk '{print $1}')  ${TGZ}" | sha512sum -c -; \
  tar -xzf "${TGZ}" -C /opt; \
  ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn; \
  rm "${TGZ}"; \
  fi

# Install Gradle (SHA256 公式 .sha256)
ARG GRADLE_VERSION=9.8.1
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  set -eux; \
  cd /tmp; \
  ZIP="gradle-${GRADLE_VERSION}-bin.zip"; \
  curl -fsSLo "${ZIP}" "https://services.gradle.org/distributions/${ZIP}"; \
  echo "$(curl -fsSL "https://services.gradle.org/distributions/${ZIP}.sha256" | awk '{print $1}')  ${ZIP}" | sha256sum -c -; \
  unzip -q "${ZIP}" -d /opt; \
  ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle; \
  rm "${ZIP}"; \
  fi

# --- Docker CLI and Docker Compose plugin ---
# APT 署名鍵は fingerprint を照合し、鍵が 1 本のみであることも確認してから登録する。
ARG DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && test "$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="pub"{n++} $1=="fpr"&&!f{f=$10} END{print n":"f}')" = "1:${DOCKER_GPG_FINGERPRINT}" \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Misc setup ---
# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# --- git-delta (SHA256 ピン留め。公式 checksums 未提供のため初回取得時の値で固定) ---
ARG GIT_DELTA_VERSION=0.20.1
ARG GIT_DELTA_SHA256_AMD64=0683067a4cbbcc19b9fd2841253131d1b37ccfa724725098d811d4d0d9fcc25b
ARG GIT_DELTA_SHA256_ARM64=6e08b734d611037eb9eb5db883cab7ac0a089216a9efdc1d2caac44319029c28
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  case "${ARCH}" in amd64) SHA=${GIT_DELTA_SHA256_AMD64} ;; arm64) SHA=${GIT_DELTA_SHA256_ARM64} ;; *) exit 1 ;; esac; \
  cd /tmp; \
  DEB="git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"; \
  curl -fsSLo "${DEB}" "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/${DEB}"; \
  echo "${SHA}  ${DEB}" | sha256sum -c -; \
  dpkg -i "${DEB}"; \
  rm "${DEB}"

# --- Python tooling ---
# pip 自体もクールダウン対応バージョン（>= 26.1）にアップグレード
# ※ pip/uv 自体のインストールにはクールダウンを適用しない（ブートストラップ）ため、バージョンを明示固定する
# Trixie の python3-pip は dpkg 管理 (RECORD ファイル無し) で、--break-system-packages だけでは
# 上書きインストールが拒否される。--ignore-installed を併用して既存メタデータを無視させる。
ARG PIP_VERSION=26.2.2
ARG UV_VERSION=0.13.4
RUN pip3 install --break-system-packages --ignore-installed "pip==${PIP_VERSION}" && \
  pip3 install --break-system-packages "uv==${UV_VERSION}" && \
  pip3 install --break-system-packages --uploaded-prior-to=P7D langfuse pip-audit playwright

# --- Non-root user setup ---
USER node

# Supply chain: Maven settings symlink (mvn auto-reads ~/.m2/settings.xml)
RUN mkdir -p /home/node/.m2 && \
  ln -s /workspace/.mvn-settings.xml /home/node/.m2/settings.xml
# Supply chain: pip config symlink (pip/uv auto-reads this path)
RUN mkdir -p /home/node/.config/pip && \
  ln -s /workspace/.pip.conf /home/node/.config/pip/pip.conf
# Supply chain: uv config symlink (uv auto-reads this path)
RUN mkdir -p /home/node/.config/uv && \
  ln -s /workspace/uv.toml /home/node/.config/uv/uv.toml

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin:/home/node/.local/bin:/home/node/.claude/local/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
ENV POWERLEVEL9K_DISABLE_GITSTATUS=true

# Install zsh with powerline10k
# スクリプトを直接パイプ実行せず、SHA256 検証後に実行する（公式 checksums 未提供のため初回取得時の値で固定）
ARG ZSH_IN_DOCKER_VERSION=1.2.1
ARG ZSH_IN_DOCKER_SHA256=0cf15b6f9c63a8103eb33bad87dc4b43fed0e0ad5884dff90f943ee1e868796e
RUN set -eux; \
  curl -fsSLo /tmp/zsh-in-docker.sh "https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh"; \
  echo "${ZSH_IN_DOCKER_SHA256}  /tmp/zsh-in-docker.sh" | sha256sum -c -; \
  sh /tmp/zsh-in-docker.sh \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -a "alias claude-litellm='ANTHROPIC_BASE_URL=\$LITELLM_BASE_URL ANTHROPIC_AUTH_TOKEN=\$LITELLM_AUTH_TOKEN claude'" \
  -x; \
  rm -f /tmp/zsh-in-docker.sh

# Install Claude Code CLI at build time
COPY --chmod=755 install-claude.sh /usr/local/bin/install-claude.sh
RUN cd /tmp && /usr/local/bin/install-claude.sh

# --- MCP server npm packages (個別インストールで1つの失敗が他に影響しない) ---
# バージョンは mcp-servers.json と必ず揃える。更新時は両方一緒に変更すること。
ARG CONTEXT7_MCP_VERSION=4.4.2
ARG PLAYWRIGHT_MCP_VERSION=0.0.83
RUN npm install -g --ignore-scripts @upstash/context7-mcp@${CONTEXT7_MCP_VERSION} || echo "WARN: context7-mcp install failed"
RUN npm install -g --ignore-scripts @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} || echo "WARN: playwright-mcp install failed"

# Install Playwright Chromium browser
# Node.js 版（@playwright/mcp が使用）と Python 版（python -m playwright が使用）を両方インストール。
# Node.js 版は `npx playwright`（バージョン未固定で registry から最新を取得）ではなく、
# @playwright/mcp に同梱された playwright の CLI を使い、MCP が要求するブラウザリビジョンと一致させる。
# 各バージョンは /home/node/.cache/ms-playwright/chromium-<rev>/ に並存する。
# プロジェクト側で異なるバージョンの playwright を使う場合は、
# プロジェクトの venv 内で `playwright install chromium` を再実行すること
# （既存バージョンはそのまま残るため副作用なし）。
RUN node "$(npm root -g)/@playwright/mcp/node_modules/playwright/cli.js" install chromium && \
  python3 -m playwright install chromium

# Install language servers for Serena
# typescript は 6.x に留める: TypeScript 7 (ネイティブ版) は tsserver.js を同梱しておらず、
# typescript-language-server が起動できないため。
ARG TYPESCRIPT_LANGUAGE_SERVER_VERSION=6.0.2
ARG TYPESCRIPT_VERSION=6.0.3
ARG PYRIGHT_VERSION=1.1.414
RUN npm install -g --ignore-scripts \
  typescript-language-server@${TYPESCRIPT_LANGUAGE_SERVER_VERSION} \
  typescript@${TYPESCRIPT_VERSION} \
  pyright@${PYRIGHT_VERSION}

# Copy firewall script, MCP config template, and setup script
COPY init-firewall.sh /usr/local/bin/
COPY mcp-servers.json /etc/claude-mcp/mcp-servers.json
COPY setup-mcp.sh /usr/local/bin/setup-mcp.sh
COPY decrypt-env.sh /usr/local/bin/decrypt-env.sh

USER root

# Install Java language server (jdtls) for Serena
ARG JDTLS_VERSION=1.62.0
ARG JDTLS_TIMESTAMP=202610131109
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  cd /tmp \
  && TGZ="jdt-language-server-${JDTLS_VERSION}-${JDTLS_TIMESTAMP}.tar.gz" \
  && curl -fsSLo "${TGZ}" "https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}/${TGZ}" \
  && echo "$(curl -fsSL "https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}/${TGZ}.sha256" | awk '{print $1}')  ${TGZ}" | sha256sum -c - \
  && mkdir -p /opt/jdtls \
  && tar -xzf "${TGZ}" -C /opt/jdtls \
  && rm "${TGZ}" \
  && printf '#!/bin/sh\nexec java -Declipse.application=org.eclipse.jdt.ls.core.id1 -Dosgi.bundles.defaultStartLevel=4 -Declipse.product=org.eclipse.jdt.ls.core.product -jar /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar -configuration /opt/jdtls/config_linux "$@"\n' > /usr/local/bin/jdtls \
  && chmod +x /usr/local/bin/jdtls; \
  fi

# sudo は init-firewall.sh と iptables のルール参照（security-test.sh 用）のみに限定する。
# chmod / iptables を引数無制限で許可すると root 昇格やファイアウォール解除が可能になるため許可しない。
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-mcp.sh /usr/local/bin/decrypt-env.sh && \
  echo 'Defaults env_keep += "FIREWALL_ALLOWED_PORTS ENABLE_FIREWALL"' > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/sbin/iptables -L OUTPUT -n" >> /etc/sudoers.d/node-firewall && \
  visudo -cf /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall && \
  groupadd -f docker && usermod -aG docker node
USER node
