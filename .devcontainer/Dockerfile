# ベースイメージを SHA256 ダイジェストでピン留め（サプライチェーン対策）
# Trixie (Debian 13, glibc 2.41) を採用。Bookworm (glibc 2.36) では rtk arm64 バイナリが
# GLIBC_2.39 必須のため実行不可だった経緯による（amd64 は musl 静的なので独立）。
# 更新時: docker pull node:24-trixie && docker inspect --format='{{index .RepoDigests 0}}' node:24-trixie
FROM node:24-trixie@sha256:135dc9a66aef366e09958c18dab705081d77fb31eccffe8c3865fac9d3e42a1d

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
RUN apt-get update && apt-get install -y --no-install-recommends \
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
#   - trivy                 : Aqua Security 公式 APT リポジトリ（signed-by 鍵検証）
#   - tflint / terraform-docs / gitleaks : 公式 GitHub Release の SHA256 checksums
# バージョン更新時はリリースノートと checksums の存在のみ確認すれば良い
# （個別バイナリの SHA を手で書き写す必要はなし）。
# GPG fingerprint は鍵ローテーション時のみ更新が必要。

# --- 1. Terraform CLI (HashiCorp PGP 署名検証 + SHA256) ---
# HashiCorp PGP fingerprint: https://www.hashicorp.com/trust/security
ARG TERRAFORM_VERSION=1.14.9
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
# AWS は session-manager-plugin の PGP 署名 / SHA256 公開ファイルを提供していない
# ため、S3 への HTTPS (TLS) が信頼アンカー。より厳密にピン留めする場合は
# https://s3.amazonaws.com/session-manager-downloads/plugin/<VERSION>/ 配下を
# 利用して SHA256 を ARG で固定する方式へ切り替えること。
# Refs: https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-debian-and-ubuntu.html
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  if [ "${ARCH}" = "arm64" ]; then SSM_ARCH=ubuntu_arm64; else SSM_ARCH=ubuntu_64bit; fi; \
  cd /tmp; \
  curl -fsSLo session-manager-plugin.deb \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SSM_ARCH}/session-manager-plugin.deb"; \
  dpkg -i session-manager-plugin.deb; \
  rm session-manager-plugin.deb; \
  session-manager-plugin

# --- 3. tflint (SHA256 公式 checksums) ---
ARG TFLINT_VERSION=0.62.0
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  cd /tmp; \
  ZIP="tflint_linux_${ARCH}.zip"; \
  curl -fsSLo "${ZIP}" "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/${ZIP}"; \
  curl -fsSLo tflint_checksums.txt "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/checksums.txt"; \
  grep "tflint_linux_${ARCH}.zip" tflint_checksums.txt | sha256sum -c -; \
  unzip "${ZIP}" -d /usr/local/bin/; \
  rm "${ZIP}" tflint_checksums.txt; \
  tflint --version

# --- 4. terraform-docs (SHA256 公式 .sha256sum) ---
# 単一の sha256sum ファイルに全プラットフォームのハッシュが含まれる形式
ARG TERRAFORM_DOCS_VERSION=0.22.0
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  cd /tmp; \
  TGZ="terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${ARCH}.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/${TGZ}"; \
  curl -fsSLo terraform-docs.sha256sum "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}.sha256sum"; \
  grep "linux-${ARCH}.tar.gz" terraform-docs.sha256sum | sha256sum -c -; \
  tar -xzf "${TGZ}" -C /usr/local/bin/ terraform-docs; \
  rm "${TGZ}" terraform-docs.sha256sum; \
  terraform-docs --version

# --- 5. trivy (Aqua Security 公式 APT GPG 検証) ---
RUN set -eux; \
  curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg; \
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/trivy.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends trivy; \
  apt-get clean && rm -rf /var/lib/apt/lists/*; \
  trivy --version

# --- 6. gitleaks (SHA256 公式 checksums) ---
ARG GITLEAKS_VERSION=8.30.1
RUN set -eux; \
  ARCH=$(dpkg --print-architecture); \
  if [ "${ARCH}" = "arm64" ]; then GL_ARCH=arm64; else GL_ARCH=x64; fi; \
  cd /tmp; \
  TGZ="gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz"; \
  curl -fsSLo "${TGZ}" "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${TGZ}"; \
  curl -fsSLo gitleaks_checksums.txt "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_checksums.txt"; \
  grep "linux_${GL_ARCH}.tar.gz" gitleaks_checksums.txt | sha256sum -c -; \
  tar -xzf "${TGZ}" -C /usr/local/bin/ gitleaks; \
  rm "${TGZ}" gitleaks_checksums.txt; \
  gitleaks version

# --- SOPS（.env 暗号化・復号バックエンド） ---
# SOPS は CNCF（旧 Mozilla）の getsops/sops 公式バイナリを GitHub release から取得
# age 本体は distro パッケージで導入済み（Debian Bookworm の age 1.1.1、Layer 1 参照）
ARG SOPS_VERSION=3.12.2
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}" \
  -o /usr/local/bin/sops && chmod +x /usr/local/bin/sops

# --- rtk（CLI 出力圧縮プロキシ、LLM トークン削減用） ---
# 個人メンテのため SHA256 ピン留めで導入。signature/attestation は未発行のため
# checksums.txt と GitHub TLS が信頼アンカー。RTK_VERSION 更新時は両 SHA を必ず差し替えること。
# 取得元: https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/checksums.txt
# arm64 は musl ビルドが無いため glibc 版を使用（base image が glibc なので問題なし）
ARG RTK_VERSION=0.38.0
ARG RTK_SHA256_AMD64=9bafb356450fb0f66a7f2d68d0468d1b1e270163f1620574e67a4c8f816d9610
ARG RTK_SHA256_ARM64=2e171f1d1c76086bb447e372d9332869d2cd3cc106c08c6e5fbd102b12e91ad9
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
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main" > /etc/apt/sources.list.d/adoptium.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends temurin-21-jdk \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && ln -s /usr/lib/jvm/temurin-21-jdk-* /usr/lib/jvm/temurin-21-jdk; \
  fi
ENV JAVA_HOME=/usr/lib/jvm/temurin-21-jdk

# Install Maven
ARG MAVEN_VERSION=3.9.9
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  curl -fsSL https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
  | tar -xz -C /opt \
  && ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn; \
  fi

# Install Gradle
ARG GRADLE_VERSION=8.12
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  curl -fsSL https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip -o /tmp/gradle.zip \
  && unzip -q /tmp/gradle.zip -d /opt \
  && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle \
  && rm /tmp/gradle.zip; \
  fi

# --- Docker CLI and Docker Compose plugin ---
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
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

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# --- Python tooling ---
# pip 自体もクールダウン対応バージョン（>= 26.1）にアップグレード
# ※ pip/uv 自体のインストールにはクールダウンを適用しない（ブートストラップ）
# Trixie の python3-pip は dpkg 管理 (RECORD ファイル無し) で、--break-system-packages だけでは
# 上書きインストールが拒否される。--ignore-installed を併用して既存メタデータを無視させる。
RUN pip3 install --break-system-packages --ignore-installed --upgrade pip && \
  pip3 install --break-system-packages uv && \
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
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -a "alias claude-litellm='ANTHROPIC_BASE_URL=\$LITELLM_BASE_URL ANTHROPIC_AUTH_TOKEN=\$LITELLM_AUTH_TOKEN claude'" \
  -x

# Install Claude Code CLI at build time
# CLAUDE_CODE_VERSION でバージョン固定可能（latest / stable / X.Y.Z）。
# 他ツール同様のサプライチェーン対策として、本番運用では特定バージョンの pin を推奨。
ARG CLAUDE_CODE_VERSION=latest
COPY --chmod=755 install-claude.sh /usr/local/bin/install-claude.sh
RUN cd /tmp && CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} /usr/local/bin/install-claude.sh

# --- MCP server npm packages (個別インストールで1つの失敗が他に影響しない) ---
# バージョンは mcp-servers.json と必ず揃える。更新時は両方一緒に変更すること。
ARG CONTEXT7_MCP_VERSION=2.1.8
ARG PLAYWRIGHT_MCP_VERSION=0.0.70
RUN npm install -g --ignore-scripts @upstash/context7-mcp@${CONTEXT7_MCP_VERSION} || echo "WARN: context7-mcp install failed"
RUN npm install -g --ignore-scripts @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} || echo "WARN: playwright-mcp install failed"

# Install Playwright Chromium browser
# Node.js 版（@playwright/mcp が使用）と Python 版（python -m playwright が使用）を両方インストール。
# 各バージョンは /home/node/.cache/ms-playwright/chromium-<rev>/ に並存する。
# プロジェクト側で異なるバージョンの playwright を使う場合は、
# プロジェクトの venv 内で `playwright install chromium` を再実行すること
# （既存バージョンはそのまま残るため副作用なし）。
RUN npx playwright install chromium && \
  python3 -m playwright install chromium

# Install language servers for Serena
RUN npm install -g --ignore-scripts typescript-language-server typescript pyright

# Copy firewall script, MCP config template, and setup script
COPY init-firewall.sh /usr/local/bin/
COPY mcp-servers.json /etc/claude-mcp/mcp-servers.json
COPY setup-mcp.sh /usr/local/bin/setup-mcp.sh
COPY decrypt-env.sh /usr/local/bin/decrypt-env.sh

USER root

# Install Java language server (jdtls) for Serena
ARG JDTLS_VERSION=1.57.0
ARG JDTLS_TIMESTAMP=202602261110
RUN if [ "$ENABLE_JAVA" = "true" ]; then \
  mkdir -p /opt/jdtls \
  && curl -fsSL https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}/jdt-language-server-${JDTLS_VERSION}-${JDTLS_TIMESTAMP}.tar.gz \
  | tar -xz -C /opt/jdtls \
  && printf '#!/bin/sh\nexec java -Declipse.application=org.eclipse.jdt.ls.core.id1 -Dosgi.bundles.defaultStartLevel=4 -Declipse.product=org.eclipse.jdt.ls.core.product -jar /opt/jdtls/plugins/org.eclipse.equinox.launcher_*.jar -configuration /opt/jdtls/config_linux "$@"\n' > /usr/local/bin/jdtls \
  && chmod +x /usr/local/bin/jdtls; \
  fi

RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-mcp.sh /usr/local/bin/decrypt-env.sh && \
  echo 'Defaults env_keep += "FIREWALL_ALLOWED_PORTS ENABLE_FIREWALL"' > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/bin/chmod, /usr/sbin/iptables, /usr/sbin/ip6tables" >> /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall && \
  groupadd -f docker && usermod -aG docker node
USER node
