# Containerized kitchen (optional)

The kitchen can run inside a single long-lived Linux container instead of
directly on your machine. This is **entirely optional and opt-in**. If you never
build or run the container, the kitchen runs natively exactly as today —
`setup.sh` and everything under `bin/` are unchanged. The container is a
*parallel* launch path, not a replacement.

> **Phase 1 scope.** This is the minimal viable container: one image, the host
> boundary in place, secrets injected by env. Credential brokering, egress
> lockdown, and remote iOS CI are later phases and are **not** part of this.

## Why a container

The container's entire value is the **host boundary**. Nothing your host has —
`~/.ssh`, `~/.config/gh`, `~/.aws`, `~/.gnupg`, your dotfiles, sibling repos — is
ever copied into the image or mounted into the container. It is simply *absent*,
so no agent in the kitchen can read it. The kitchen reaches GitHub only through a
**scoped, short-lived token you create**, never your personal GitHub login.

## What is and isn't mounted

Storage is two **named Docker volumes** — not host bind mounts. A named volume
lives in the container runtime's storage, so there is no host filesystem path to
accidentally widen and nothing on your host tree to leak.

| Volume         | Container path          | Holds                                  |
| -------------- | ----------------------- | -------------------------------------- |
| `ck_home`      | `/home/chef/kitchen`    | the kitchen home (`projects/`, `data/`, `state/`, `config/`, `bin/`, `AGENTS.md`) |
| `ck_worktrees` | `/home/chef/.sc-worktrees` | the git worktree pool (managed by `bin/sc-worktree.sh`) |

Plus a **read-only secrets drop via `--env-file`** (see below).

**Never mounted:** your host home, any host dotfile, any SSH/GPG/cloud/`gh`
credential, any sibling repo, your host's `claude`/harness credentials.

### The worktree pool is built fresh inside

A git worktree's `.git` is a file pointing at an **absolute** gitdir in its
backing repo. So you **cannot** seed the container's pool from your host's
`~/.sc-worktrees` — the absolute links would dangle. Instead the pool is built
**fresh inside the container** at the fixed path `/home/chef/.sc-worktrees`
(`sc-container.sh` sets `SC_WORKTREE_ROOT` to it), and projects are cloned
inside. Don't relocate that mount point across restarts. This also helps
confidentiality: the host's `~/.sc-worktrees` (which references host project
paths) is never mounted in.

The first time you bring the container up, its `ck_home` volume is empty — clone
the kitchen repo into it (or populate it however you prefer) so
`/home/chef/kitchen/bin/sc-bootstrap.sh` exists, then clone your projects inside
and let the brigade run normally.

## Usage

```sh
bin/sc-container.sh build   # build the image (docker/kitchen.Dockerfile)
bin/sc-container.sh up       # start the container (daemon up, git+bootstrap run)
bin/sc-container.sh shell    # attach to the Chef (tmux + harness)
bin/sc-container.sh down     # stop & remove the container; volumes persist
bin/sc-container.sh nuke     # remove the container AND its volumes (explicit discard)
```

- `up` starts the container detached. Its entrypoint configures git for
  HTTPS+token, runs `bin/sc-bootstrap.sh` to confirm a clean detection, and then
  idles.
- `shell` attaches you to the Chef inside a persistent tmux session running
  your harness. You interact with the kitchen *through the container*; PRs land
  on GitHub as usual.
- `down` keeps the named volumes — the kitchen survives a restart (the
  "restart is a non-event" property holds at the container level too). `up`
  resumes it.
- `nuke` is the explicit discard: container **and** volumes are removed.

Environment overrides (all optional): `SC_CONTAINER_RUNTIME` (default `docker`;
Colima exposes the same docker API), `SC_CONTAINER_IMAGE`, `SC_CONTAINER_NAME`,
`SC_HARNESS` (default `claude`), `SC_SECRETS_ENV` (default
`~/.config/code-kitchen/secrets.env`).

### macOS

`docker` works via Docker Desktop, **Colima** (FOSS, `brew install colima &&
colima start`), or OrbStack. Set `SC_CONTAINER_RUNTIME` if your CLI isn't named
`docker`. A Linux container cannot run Xcode, so iOS builds are delegated to CI
(a later phase); backend/frontend (Go, Node/Next.js) build fully inside.

## Credentials — the manual steps you perform

Secrets are **never** baked into the image and **never** taken from your host's
`gh`/`claude`/ssh config. You create a scoped token and an env file by hand.

### 1. Create a scoped fine-grained GitHub PAT

In GitHub → **Settings → Developer settings → Fine-grained personal access
tokens → Generate new token**:

1. **Repository access → Only select repositories** — pick *only* the kitchen's
   repos (e.g. `you/voop`, `you/code-kitchen`). Nothing else.
2. **Permissions:**
   - **Contents: Read and write** (push branches),
   - **Pull requests: Read and write** (open/manage PRs via `gh`),
   - **Metadata: Read** (mandatory, auto-selected).
   - Optionally **Actions: Read** (CI status), if you want the brigade to read
     check results.
   - **Nothing else** — no admin, no org, no other repos.
3. **Expiration: short** (e.g. 7–30 days). Rotate by regenerating; the container
   reads the token fresh on each `up`.

A fine-grained PAT limits the blast radius to those repos for those few days —
unlike copying your `gh` login, which can touch every repo and org you belong to.

### 2. Create `secrets.env`

Create `~/.config/code-kitchen/secrets.env` (host-side, `chmod 600`, **never
committed**):

```sh
GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxx
GIT_AUTHOR_NAME=Kitchen Cook
GIT_AUTHOR_EMAIL=cook@users.noreply.github.com
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxx
```

```sh
mkdir -p ~/.config/code-kitchen
chmod 600 ~/.config/code-kitchen/secrets.env
```

`bin/sc-container.sh up` injects these with `--env-file`. `gh`
honors `GH_TOKEN` with no `gh auth login` and no config file written; the git
credential helper reads `GH_TOKEN` for HTTPS pushes (no SSH key ever enters the
container); Claude Code uses `ANTHROPIC_API_KEY` headlessly (use a key
provisioned for the kitchen so you can rotate it independently). For a non-claude
harness, inject that provider's API key the same way.

**`NEEDS_GH_AUTH` is expected before you supply the token.** Without `GH_TOKEN`,
`bin/sc-bootstrap.sh` inside the container will print `NEEDS_GH_AUTH` — this is
normal and harmless. Supplying `secrets.env` clears it; do **not** copy a host
`gh` credential to silence it.

## ⚠️ Residual risk — read this

> **The single container is one shared room.** It isolates agents from the
> **host**, but **NOT from each other or from the in-container token.** Every
> Cook and the Chef run in the same container and can read every credential
> inside it — `GH_TOKEN`, `ANTHROPIC_API_KEY`, the git credential helper. A
> prompt-injected or compromised Cook can read the in-container token and use it
> within that token's scope, or attempt to exfiltrate anything it can
> legitimately read.

The whole credential strategy is damage-limitation against this:

- **Scope the GitHub token to only the kitchen's repos** — a leaked token can't
  reach your other repos.
- **Short expiry + easy rotation** — a leaked token dies fast.
- **No SSH key, no host `gh` config, no host harness creds** — so the worst-case
  credential is the scoped PAT, not your GitHub identity.

Tightening this further — keeping even the scoped token *out* of the room via a
credential broker, and bounding exfiltration with egress control — is later-phase
hardening, not part of Phase 1.

## What Phase 1 does NOT cover (later phases)

- **Credential brokering:** a sidecar holding the real secret and exposing only
  push/PR over a socket, so Cooks never see a long-lived token.
- **Egress control:** default-deny network with an allow-list (GitHub, npm, Go
  proxy, harness API) to bound exfiltration.
- **Remote iOS CI:** a Linux container can't run Xcode; iOS build/sign/test gets
  delegated to GitHub Actions `macos-*` runners.

## Captain's manual acceptance test

The automated build/run validation does **not** exercise a real end-to-end flow,
because that needs your real scoped PAT and API key. After creating `secrets.env`,
verify end-to-end yourself:

1. `bin/sc-container.sh build && bin/sc-container.sh up && bin/sc-container.sh shell`
2. Inside, confirm `bin/sc-bootstrap.sh` runs with no `MISSING` and no
   `NEEDS_GH_AUTH`.
3. Fire one real Cook on a `direct-PR` project; confirm a worktree is created
   in the in-container pool, the cook validates locally, a branch pushes, a PR
   opens, and 86 tears the worktree down.
