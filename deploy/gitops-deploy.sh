#!/usr/bin/env bash
# Pull-based deploy for one Docker Compose stack in this repository.
#
# Run by gitops-deploy.timer. When origin/main changes the stack's folder, it
# pulls and starts the stack, waits until every container is running (and
# healthy, where the image has a healthcheck) on the image the compose file
# pins, and reports the result to Discord.
#
# Settings are read from /etc/gitops-deploy.env:
#   DISCORD_WEBHOOK_URL  required
#   STACK                folder to deploy (default: the short hostname)
#   REPO_DIR             checkout of this repository (default: /opt/selfhosted)
#   BRANCH               branch to follow (default: main)
#   HEALTH_TIMEOUT       seconds to wait for containers (default: 180)
set -euo pipefail

CONF=/etc/gitops-deploy.env
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"
: "${DISCORD_WEBHOOK_URL:?set DISCORD_WEBHOOK_URL in $CONF}"
STACK=${STACK:-$(hostname -s)}
REPO_DIR=${REPO_DIR:-/opt/selfhosted}
BRANCH=${BRANCH:-main}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}

STATE_DIR=/var/lib/gitops-deploy
deployed_file=$STATE_DIR/$STACK.deployed # last commit deployed successfully
failed_file=$STATE_DIR/$STACK.failed     # last failed commit, so it is reported once
mkdir -p "$STATE_DIR"

notify() {
  python3 -c 'import json, sys; print(json.dumps({"content": sys.stdin.read()[:1990]}))' |
    curl -fsS -m 15 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL" >/dev/null ||
    echo "Discord notification failed" >&2
}

git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
target=$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")
deployed=$(cat "$deployed_file" 2>/dev/null || true)
[[ $target == "$deployed" ]] && exit 0
[[ $target == "$(cat "$failed_file" 2>/dev/null || true)" ]] && exit 0

# The stack's .env is gitignored, so a hard reset keeps it.
git -C "$REPO_DIR" reset --quiet --hard "$target"

# A commit that does not touch this stack only moves the marker.
if [[ -n $deployed ]] && git -C "$REPO_DIR" cat-file -e "$deployed^{commit}" 2>/dev/null &&
  git -C "$REPO_DIR" diff --quiet "$deployed" "$target" -- "$STACK"; then
  echo "$target" >"$deployed_file"
  exit 0
fi

short=${target:0:7}
subject=$(git -C "$REPO_DIR" log -1 --format=%s "$target")
commit_url=$(git -C "$REPO_DIR" remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')/commit/$target
log=$(mktemp)
trap 'rm -f "$log"' EXIT

fail() {
  echo "$target" >"$failed_file"
  notify <<EOF
❌ **$STACK** deploy failed at [\`$short\`](<$commit_url>) $subject
$1
\`\`\`
$(tail -n 15 "$log")
\`\`\`
EOF
  exit 1
}

cd "$REPO_DIR/$STACK" 2>/dev/null || fail "folder $STACK/ not found in the repository"
[[ -f .env ]] || fail "missing $REPO_DIR/$STACK/.env"
docker compose pull --quiet >>"$log" 2>&1 || fail "image pull failed"
docker compose up -d --remove-orphans >>"$log" 2>&1 || fail "docker compose up failed"

# One line per container: "<name> <status> <restarts> <image ref> <ok|stale>".
# Status is healthy or running for services, completed for one-shot containers
# (restart policy "no" or "on-failure") that exited 0, else the raw state.
# "stale" means the container does not run the image its pinned ref resolves to.
snapshot() {
  local id name state health exit_code policy restarts ref image_id status
  for id in $(docker compose ps -aq); do
    read -r name state health exit_code policy restarts ref image_id < <(docker inspect -f \
      '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.State.ExitCode}} {{or .HostConfig.RestartPolicy.Name "no"}} {{.RestartCount}} {{.Config.Image}} {{.Image}}' "$id")
    if [[ $state == running ]]; then
      status=${health/#-/running}
    elif [[ $state == exited && $exit_code == 0 && $policy =~ ^(no|on-failure)$ ]]; then
      status=completed
    else
      status=$state
    fi
    if [[ $(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null) == "$image_id" ]] &&
      grep -qxF "$ref" <<<"$wanted"; then
      echo "${name#/} $status $restarts $ref ok"
    else
      echo "${name#/} $status $restarts $ref stale"
    fi
  done | sort
}

# Settled means every container is healthy, running (no healthcheck) or
# completed, on its pinned image, and unchanged across two checks 10s apart.
settled() {
  [[ -n $1 ]] && ! awk '$2 !~ /^(healthy|running|completed)$/ || $5 != "ok" { bad = 1 } END { exit !bad }' <<<"$1"
}

wanted=$(docker compose config --images)
deadline=$((SECONDS + HEALTH_TIMEOUT))
previous=""
while :; do
  current=$(snapshot)
  settled "$current" && [[ $current == "$previous" ]] && break
  if ((SECONDS >= deadline)); then
    echo "container states after ${HEALTH_TIMEOUT}s:" >>"$log"
    echo "$current" >>"$log"
    fail "containers did not become healthy"
  fi
  previous=$current
  sleep 10
done

echo "$target" >"$deployed_file"
rm -f "$failed_file"
notify <<EOF
✅ **$STACK** deployed [\`$short\`](<$commit_url>) $subject
$(awk '{ sub(/@sha256:.*/, "", $4); printf "`%s` %s\n", $4, $2 }' <<<"$current")
EOF
