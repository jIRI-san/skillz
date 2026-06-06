# Autopilot execution container — .NET 10 SDK + Copilot CLI + tooling
# Used by plugins/autopilot/scripts/launch-container.ps1 via `docker build`

FROM mcr.microsoft.com/dotnet/sdk:10.0

ARG GH_CLI_VERSION=2.74.0
# Fallback only — launch-container.ps1 resolves and passes the latest published
# version via --build-arg COPILOT_CLI_VERSION so each build auto-upgrades.
ARG COPILOT_CLI_VERSION=1.0.60

# System dependencies + Node.js (needed for Copilot CLI)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    ca-certificates \
    gnupg \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# PowerShell
RUN curl -sSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -sSL "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_amd64.deb" -o /tmp/gh.deb \
    && dpkg -i /tmp/gh.deb \
    && rm /tmp/gh.deb

# Docker CLI (for Testcontainers — talks to host Docker daemon via socket mount)
RUN curl -sSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# GitHub Copilot CLI
RUN npm install -g @github/copilot@${COPILOT_CLI_VERSION}

# Container entry-point script
COPY scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
RUN chmod +x /usr/local/bin/container-entrypoint.sh

# Non-root user for security — add to docker group for socket access
RUN groupadd -g 998 docker || true \
    && useradd -m -s /bin/bash -G docker autopilot
USER autopilot
WORKDIR /work

# Verify tools are installed
RUN git --version && pwsh --version && gh --version && copilot --version
