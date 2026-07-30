#!/usr/bin/env bash
# promote.sh — build this repo and make it the running CloudCLI.
#
#   sudo scripts/promote.sh              build, install, restart, verify
#   sudo scripts/promote.sh --dry-run    build and pack only, install nothing
#   sudo scripts/promote.sh --rollback   reinstall the previous build
#
# WHY IT DETACHES ITSELF: production CloudCLI is the tool we work in.
# `systemctl restart cloudcli` drops every WebSocket, including the session that
# ran this command — so a foreground promote would kill its own operator
# mid-restart and leave the box in an unknown state. This re-execs itself under
# setsid, prints a log path, and returns immediately, so the promote finishes
# whether or not the caller survives.
#
# WHY IT BUILDS FROM A WORKTREE: the build runs from a throwaway checkout of
# `main`, never from the working tree. An in-progress edit therefore cannot leak
# into production, and a promote cannot disturb an edit.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BRANCH=${PROMOTE_BRANCH:-main}
WORKTREE=/home/dev/.cache/promote/cloudcli
BACKUPS=/var/backups/cloudcli
LOGDIR=/var/log/cloudcli-promote
SERVICE=cloudcli.service
PKG=@cloudcli-ai/cloudcli
ENV_FILE=/etc/cloudcli/cloudcli.env
RUN_AS=dev

die() { echo "promote: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
asdev() { sudo -u "$RUN_AS" "$@"; }

[[ $EUID -eq 0 ]] || die "must run as root — npm -g and systemctl both need it: sudo scripts/promote.sh"

MODE=deploy
case "${1:-}" in
--dry-run) MODE=dry ;;
--rollback) MODE=rollback ;;
"") ;;
*) die "unknown option '$1'" ;;
esac

mkdir -p "$LOGDIR" "$BACKUPS"

# --- detach ------------------------------------------------------------------
if [[ "${PROMOTE_DETACHED:-}" != 1 && "$MODE" != dry ]]; then
	log="$LOGDIR/$(date +%Y%m%d-%H%M%S).log"
	PROMOTE_DETACHED=1 setsid bash -c "'${BASH_SOURCE[0]}' ${1:-} >'$log' 2>&1" >/dev/null 2>&1 &
	echo "promote running detached — it survives the CloudCLI restart."
	echo "  log:    $log"
	echo "  follow: tail -f $log"
	exit 0
fi

# Read the port the service actually uses rather than assuming 3001.
PORT=$( (set -a; . "$ENV_FILE" 2>/dev/null; set +a; echo "${SERVER_PORT:-3001}") )

healthy() {
	local code
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" || echo 000)
	[[ "$code" =~ ^(200|30[0-9]|401|403)$ ]]
}

install_tarball() {
	local tb=$1 i
	step "installing $(basename "$tb")"
	npm install -g --no-fund --no-audit "$tb"
	step "restarting $SERVICE"
	systemctl restart "$SERVICE"
	# A cold start loads a lot; give it a real chance before calling it dead.
	for i in $(seq 1 30); do
		sleep 2
		if healthy; then echo "healthy after $((i * 2))s on 127.0.0.1:$PORT"; return 0; fi
	done
	return 1
}

previous_tarball() { ls -1t "$BACKUPS"/*.tgz 2>/dev/null | sed -n 2p; }

if [[ "$MODE" == rollback ]]; then
	prev=$(previous_tarball) || true
	[[ -n "${prev:-}" ]] || die "no previous build in $BACKUPS to roll back to"
	install_tarball "$prev" || die "rollback installed but is not healthy — journalctl -u $SERVICE -n 50"
	echo "rolled back to $(basename "$prev")"
	exit 0
fi

# --- build -------------------------------------------------------------------
asdev git -C "$REPO" rev-parse --verify --quiet "$BRANCH" >/dev/null \
	|| die "no '$BRANCH' branch in $REPO"

step "checking out $BRANCH into $WORKTREE"
mkdir -p "$(dirname "$WORKTREE")"
chown "$RUN_AS:$RUN_AS" "$(dirname "$WORKTREE")"
if [[ -e "$WORKTREE/.git" ]]; then
	asdev git -C "$WORKTREE" checkout --quiet --detach "$BRANCH"
	asdev git -C "$WORKTREE" reset --hard --quiet "$BRANCH"
	# Keep node_modules — reinstalling it every promote costs minutes.
	asdev git -C "$WORKTREE" clean -fdq -e node_modules
else
	asdev git -C "$REPO" worktree add --detach --force "$WORKTREE" "$BRANCH"
fi
commit=$(asdev git -C "$WORKTREE" rev-parse --short HEAD)
echo "building $commit"

step "installing dependencies"
if [[ -f "$WORKTREE/package-lock.json" ]]; then
	asdev npm --prefix "$WORKTREE" ci --no-fund --no-audit
else
	asdev npm --prefix "$WORKTREE" install --no-fund --no-audit
fi

step "building client + server"
(cd "$WORKTREE" && asdev npm run build)

step "packing"
tb=$(cd "$WORKTREE" && asdev npm pack --silent --pack-destination "$WORKTREE")
[[ -f "$WORKTREE/$tb" ]] || die "npm pack produced nothing"
stamped="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$commit-$tb"
cp "$WORKTREE/$tb" "$stamped"
echo "artifact: $stamped"

if [[ "$MODE" == dry ]]; then
	echo; echo "dry run complete — built and packed, installed nothing."
	exit 0
fi

# --- install -----------------------------------------------------------------
step "current install"
npm ls -g --depth 0 2>/dev/null | grep -F "$PKG" || echo "  ($PKG not currently installed)"

if install_tarball "$stamped"; then
	step "done — $commit is live"
else
	step "FAILED — the new build never became healthy; rolling back"
	prev=$(previous_tarball) || true
	if [[ -n "${prev:-}" ]]; then
		install_tarball "$prev" && echo "rolled back to $(basename "$prev")" \
			|| echo "ROLLBACK ALSO FAILED — journalctl -u $SERVICE -n 50" >&2
	else
		echo "no previous build to roll back to — journalctl -u $SERVICE -n 50" >&2
	fi
	exit 1
fi
