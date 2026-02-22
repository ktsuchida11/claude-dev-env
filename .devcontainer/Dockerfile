FROM node:20

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

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
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
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
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
  python3 \
  python3-pip \
  python3-venv \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

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

# Install GitLab CLI (glab)
ARG GLAB_VERSION=1.86.0
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz" && \
  tar -xzf "glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz" && \
  sudo install -m 755 bin/glab /usr/local/bin/glab && \
  rm -rf "glab_${GLAB_VERSION}_linux_${ARCH}.tar.gz" bin/

# Install uv (provides uvx for running Serena MCP server)
RUN pip3 install --break-system-packages uv

# Set up non-root user
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin:/home/node/.local/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Install zsh with powerline10k
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Pre-install MCP server npm packages
RUN npm install -g @upstash/context7-mcp @playwright/mcp @modelcontextprotocol/server-sequential-thinking

# Install Playwright Chromium browser
RUN npx playwright install chromium

# Install language servers for Serena
RUN npm install -g typescript-language-server typescript pyright

# Copy firewall script, MCP config template, and setup script
COPY init-firewall.sh /usr/local/bin/
COPY mcp-servers.json /etc/claude-mcp/mcp-servers.json
COPY setup-mcp.sh /usr/local/bin/setup-mcp.sh

USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-mcp.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall
USER node
