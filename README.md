# Pi Node Telegram Controller PRO — SoloHost

Repository: https://github.com/cannoi/pinode-telegram-controller

This is the SoloHost/Linux container edition. It does not require Windows PowerShell, Pi Desktop, WSL, or a Docker socket mount.

## Phone-only deployment

1. Upload the files in this repository to GitHub.
2. Open **Actions** and run **Build and publish Docker image** (or push to `main`).
3. Wait for the workflow to finish successfully.
4. Open **Packages** on GitHub and make the `pinode-telegram-controller` container package public so SoloHost can pull it without credentials.
5. Upload this repository's `docker-compose.yml` and `config_options.yml` as the SoloHost app package.
6. Enter Telegram Bot Token and Chat ID in the SoloHost form.

## Image

`ghcr.io/cannoi/pinode-telegram-controller:latest`

## Important

Never commit `.env`, Telegram Bot Token, or Gemini API keys. Rotate any credentials that were previously stored in the old Windows ZIP.

## Current monitoring model

The container checks Pi Node network ports through `PI_NODE_HOST`. It intentionally does not mount `/var/run/docker.sock`, because SoloHost rejects host bind mounts outside the installation directory.
