# code-kitchen optional container image (Phase 1).
#
# A single long-lived Linux image that holds the Souschef, every station
# worktree, and every Cook. Its whole value is the HOST BOUNDARY: nothing the
# host has (~/.ssh, ~/.config/gh, ~/.aws, dotfiles, sibling repos) is ever
# copied in or mounted, so it is simply absent and unreadable to any agent.
#
# This image is OPT-IN. It is a net-new, parallel way to launch the same
# kitchen; native operation (setup.sh + bin/) is completely unaffected if you
# never build or run it.
#
# Build:  bin/sc-container.sh build      (or: docker build -f docker/kitchen.Dockerfile -t code-kitchen:latest .)
# Run:    bin/sc-container.sh up && bin/sc-container.sh shell
#
# Dependency set is grounded in setup.sh and bin/sc-bootstrap.sh; see
# docs/containerization.md for the full rationale.

# Linux base: shares the kernel on Linux hosts; runs as a Linux guest in a VM
# (Colima/OrbStack/Docker Desktop) on macOS.
FROM debian:bookworm-slim

ARG HARNESS=claude            # claude | codex | opencode | pi
ARG NODE_MAJOR=20
ARG KUSER=chef
ARG KUID=1000

ENV DEBIAN_FRONTEND=noninteractive

# 1. Base tools (mirrors setup.sh:26 `git curl tmux node npm gh` and
#    sc-bootstrap.sh TOOLS), plus ca-certificates/gnupg/sudo the installers and
#    a non-root user need.
#
#    Per-project toolchains (report §1.7): voop needs Go + a postgres client, so
#    they are baked here for a working single-image Phase 1. This is the
#    "lean base vs. layered image" choice called out in the plan: we accept a
#    slightly heavier base now (golang + postgresql-client + chromium) over
#    maintaining a separate "kitchen-with-go-node" layer, because Phase 1's goal
#    is to prove one image runs the kitchen end-to-end. If the project mix grows
#    past Go/Node, split per-project toolchains into a layered image built FROM
#    this one rather than bloating the base further.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates tmux gnupg sudo \
      golang chromium postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# 2. Node 20.x via NodeSource. Distro `nodejs` is too old for the harness and
#    the *-axi tools (report §1.1; host runs v20.20.2), so we pin via NodeSource.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. GitHub CLI via the official apt repo (sc-bootstrap maps `gh` here).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# 4. Non-root user. Agents never run as root. NOPASSWD sudo is for in-container
#    convenience only; the security boundary is the container/host edge, not this.
RUN useradd -m -u "${KUID}" -s /bin/bash "${KUSER}" \
    && echo "${KUSER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${KUSER}" \
    && chmod 0440 "/etc/sudoers.d/${KUSER}" \
    # Login shells (every interactive tmux pane the brigade opens) source
    # /etc/profile, which resets PATH and would otherwise drop the dirs set in
    # ENV PATH below - making sc-bootstrap falsely report tools MISSING. Pin both
    # bin dirs for login shells too.
    && printf 'export PATH="/home/%s/.local/bin:/home/%s/.npm-global/bin:$PATH"\n' "${KUSER}" "${KUSER}" \
       > /etc/profile.d/code-kitchen-path.sh

USER ${KUSER}
WORKDIR /home/${KUSER}

# ~/.local/bin holds treehouse + no-mistakes (org installers); ~/.npm-global/bin
# holds the npm globals + harness. Both must be on PATH (report §1.3).
ENV NPM_CONFIG_PREFIX="/home/${KUSER}/.npm-global"
ENV PATH="/home/${KUSER}/.local/bin:/home/${KUSER}/.npm-global/bin:${PATH}"
RUN mkdir -p "/home/${KUSER}/.npm-global" "/home/${KUSER}/.local/bin"

# 5. npm global *-axi tools (setup.sh:42) + each tool's `setup hooks`
#    (setup.sh:50-54). tasks-axi is optional/best-effort (setup.sh:62-68).
RUN npm install -g gh-axi chrome-devtools-axi lavish-axi \
    && (npm install -g tasks-axi || echo "tasks-axi not installable (optional; brigade falls back to hand-edited backlog)") \
    && for p in gh-axi chrome-devtools-axi lavish-axi; do "$p" setup hooks; done

# Point chrome-devtools-axi at the distro Chromium (report §1.6: the axi tool
# installs but cannot drive a browser without a binary). Browser automation is
# opportunistic, not on the critical path.
ENV CHROME_BIN=/usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# 6. The agent harness CLI (report §1.4). Default `claude` via its npm package;
#    swap with --build-arg HARNESS=codex|opencode|pi (those installs are added
#    here as they are verified per the harness-adapters skill).
RUN if [ "$HARNESS" = "claude" ]; then \
      npm install -g @anthropic-ai/claude-code; \
    else \
      echo "WARNING: HARNESS=$HARNESS has no install rule yet; install it in this layer once the adapter is verified." >&2; \
    fi

# 7. Org installers (setup.sh:73): treehouse + no-mistakes, into ~/.local/bin.
#    HARD build-time assertion: treehouse get --help MUST advertise --lease, or
#    the brigade treats it as MISSING (sc-bootstrap.sh) and the kitchen cannot
#    fire stations. Fail the build loudly rather than ship a broken image.
RUN curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh \
    && curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh \
    && if treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'; then \
         echo "OK: treehouse advertises --lease"; \
       else \
         echo "BUILD FAILED: installed treehouse lacks 'treehouse get --lease'; the brigade requires it." >&2; \
         exit 1; \
       fi

# 8. Entrypoint: start the no-mistakes daemon when needed, configure git for
#    HTTPS+token, cd into the mounted kitchen home, run bootstrap, exec the
#    harness under tmux. The kitchen home itself is a runtime mount, not baked in.
COPY --chown=${KUSER}:${KUSER} docker/entrypoint.sh /home/${KUSER}/entrypoint.sh
RUN chmod +x /home/${KUSER}/entrypoint.sh

# Where the kitchen home volume mounts. The treehouse pool and no-mistakes store
# live at ~/.treehouse and ~/.no-mistakes (their default, fixed paths) on their
# own named volumes; treehouse builds the pool FRESH inside (report §2.4).
ENV SC_KITCHEN_HOME=/home/${KUSER}/kitchen
ENV HARNESS=${HARNESS}

ENTRYPOINT ["/home/chef/entrypoint.sh"]
CMD ["tmux", "new", "-A", "-s", "souschef"]
