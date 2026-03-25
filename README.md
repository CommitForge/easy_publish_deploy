# Easy Publish Deploy

Deployment orchestration repo for Easy Publish.

This repo is meant to hold:
- checkout/sync scripts for all Easy Publish repos
- build/deploy helpers
- later: `systemd` service/unit files and server ops docs

## Included Now

- `scripts/sync_and_build.sh`

It can:
- clone or update `easy_publish_backend`, `easy_publish_frontend`, `easy_publish_cli`
- optionally run build steps
- provide a deploy placeholder step (to be replaced with your real deployment flow)

## Quick Start

```bash
chmod +x scripts/sync_and_build.sh
./scripts/sync_and_build.sh
```

With build:

```bash
./scripts/sync_and_build.sh --build
```

With build + deploy placeholder:

```bash
./scripts/sync_and_build.sh --build --deploy
```

## Defaults

The script uses these repo URLs by default:
- `git@github.com:CommitForge/easy_publish_backend.git`
- `git@github.com:CommitForge/easy_publish_frontend.git`
- `git@github.com:CommitForge/easy_publish_cli.git`

## Environment Overrides

```bash
TARGET_DIR=/opt/easy_publish/repos \
TARGET_BRANCH=main \
BACKEND_REPO=git@github.com:CommitForge/easy_publish_backend.git \
FRONTEND_REPO=git@github.com:CommitForge/easy_publish_frontend.git \
CLI_REPO=git@github.com:CommitForge/easy_publish_cli.git \
./scripts/sync_and_build.sh --build
```

## Next Step

When you send your `systemd` scripts, we will add them here and wire the deploy step to use them.
