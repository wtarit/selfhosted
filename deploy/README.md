# Pull-based deploy

Each Docker host follows `main` on its own: `gitops-deploy.timer` checks every
5 minutes, and when a commit changes the host's stack folder it runs
`docker compose pull` and `up -d`, waits for the containers to be healthy on
the pinned images, and posts the result to Discord. Hosts only need outbound
HTTPS; nothing connects in to deploy.

## Install on a host

```sh
sudo apt-get install -y git
sudo git clone https://github.com/wtarit/selfhosted.git /opt/selfhosted
sudo install -m 755 /opt/selfhosted/deploy/gitops-deploy.sh /usr/local/bin/gitops-deploy
sudo install -m 644 /opt/selfhosted/deploy/gitops-deploy.{service,timer} /etc/systemd/system/

# Secrets stay on the host: the stack's .env (gitignored) and the webhook.
sudo install -m 600 /dev/null /etc/gitops-deploy.env
echo 'DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...' | sudo tee /etc/gitops-deploy.env >/dev/null
# STACK defaults to the hostname; set STACK=<folder> if they differ.
sudo install -m 600 /path/to/.env /opt/selfhosted/<stack>/.env

sudo systemctl start gitops-deploy.service   # first deploy, reports to Discord
sudo systemctl enable --now gitops-deploy.timer
```

Logs: `journalctl -u gitops-deploy`. A failed commit is reported once and not
retried; the next commit to `main` is deployed as usual. To retry the same
commit, remove `/var/lib/gitops-deploy/<stack>.failed`.
