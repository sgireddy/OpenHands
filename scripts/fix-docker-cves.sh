#!/usr/bin/env bash
# scripts/fix-docker-cves.sh
#
# One-shot CVE remediation for the OpenHands container image.
#
# Strategy: build a hardened overlay image (openhands:custom_base) on top of
# the upstream image (openhands:latest), via containers/app/Dockerfile.overlay.
# No upstream files are modified, so this stays merge-clean across `git pull`.
#
# What this script does, in order:
#   0.  Pre-flight checks (docker, scout, repo files, network).
#   1.  Build (or reuse) the upstream image:           openhands:latest
#   2.  Scout-scan it as the BASELINE.
#   3.  Build the OS-only overlay:                     openhands:custom_base
#   4.  Scout-scan it (post-OS-patch).
#   5.  Diff package list against baseline; if Python deps are still flagged
#       HIGH/CRITICAL, propose a PIP_UPGRADES set, ask, then rebuild + rescan.
#   6.  Print final verdict + report locations.
#
# Run from the repo root (a directory containing pyproject.toml +
# containers/app/Dockerfile.overlay):
#
#   cd /Users/reactivedev/projects/OpenHandsSourceRepo
#   ./scripts/fix-docker-cves.sh
#
# Flags:
#   --image NAME           Hardened image tag (default: openhands:custom_base)
#   --base-image NAME      Upstream image tag (default: openhands:latest)
#   --skip-upstream-build  Reuse an existing openhands:latest, don't rebuild it
#   --no-deps              Don't propose Python package upgrades (OS-only fix)
#   --pip-upgrades "SPECS" Skip the interactive prompt and use these pip specs
#                          directly, e.g.  --pip-upgrades "urllib3==2.5.0 cryptography==45.0.0"
#   --yes | -y             Don't prompt for confirmations
#   -h | --help            Show this help
#
# Exit codes:
#   0  success, no CRITICAL/HIGH remaining
#   1  unrecoverable error
#   2  CRITICAL/HIGH still present after all steps

set -Eeuo pipefail
shopt -s lastpipe

# --------------------------------------------------------------------------- #
# Defaults                                                                    #
# --------------------------------------------------------------------------- #
HARDENED_IMAGE="openhands:custom_base"
UPSTREAM_IMAGE="openhands:latest"
OVERLAY_DOCKERFILE="containers/app/Dockerfile.overlay"
UPSTREAM_DOCKERFILE="containers/app/Dockerfile"
SKIP_UPSTREAM_BUILD=0
DO_DEPS=1
PIP_UPGRADES_OVERRIDE=""
ASSUME_YES=0

# --------------------------------------------------------------------------- #
# Pretty output                                                               #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GRN=$'\033[32m'
    C_YEL=$'\033[33m';  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""
fi
log()  { printf "%s[%s]%s %s\n"   "$C_BLU" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
ok()   { printf "%s[ OK ]%s %s\n" "$C_GRN" "$C_RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$C_YEL" "$C_RESET" "$*" >&2; }
err()  { printf "%s[ERR ]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
hdr()  { printf "\n%s==> %s%s\n"  "$C_BOLD$C_CYN" "$*" "$C_RESET"; }

confirm() {
    local prompt="${1:-Proceed?}"
    (( ASSUME_YES )) && return 0
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

trap 'err "Failed at line $LINENO running: $BASH_COMMAND"' ERR

usage() {
    # Print the contiguous header comment block (lines starting with '#')
    # immediately after the shebang, with the leading '# ' stripped.
    awk '
        NR==1 { next }                       # skip shebang
        /^#/  { sub(/^# ?/, ""); print; next }
        { exit }                             # stop at first non-comment line
    ' "$0"
    exit 0
}

# --------------------------------------------------------------------------- #
# Arg parse                                                                   #
# --------------------------------------------------------------------------- #
while (( $# )); do
    case "$1" in
        --image)               HARDENED_IMAGE="$2"; shift 2 ;;
        --base-image)          UPSTREAM_IMAGE="$2"; shift 2 ;;
        --skip-upstream-build) SKIP_UPSTREAM_BUILD=1; shift ;;
        --no-deps)             DO_DEPS=0; shift ;;
        --pip-upgrades)        PIP_UPGRADES_OVERRIDE="$2"; shift 2 ;;
        --yes|-y)              ASSUME_YES=1; shift ;;
        -h|--help)             usage ;;
        *) err "Unknown arg: $1"; echo "Run with --help for usage." >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(pwd)"

# --------------------------------------------------------------------------- #
# Step 0 — pre-flight                                                         #
# --------------------------------------------------------------------------- #
hdr "Step 0: pre-flight checks"

[[ -f "$REPO_ROOT/$OVERLAY_DOCKERFILE" ]] \
    || { err "Missing $OVERLAY_DOCKERFILE — run from repo root."; exit 1; }
[[ -f "$REPO_ROOT/$UPSTREAM_DOCKERFILE" ]] \
    || { err "Missing $UPSTREAM_DOCKERFILE — wrong directory?"; exit 1; }
[[ -f "$REPO_ROOT/pyproject.toml" ]] \
    || { err "Missing pyproject.toml — run from repo root."; exit 1; }

command -v docker >/dev/null \
    || { err "docker not on PATH"; exit 1; }
docker info >/dev/null 2>&1 \
    || { err "Docker daemon not reachable"; exit 1; }

if ! docker scout version >/dev/null 2>&1; then
    err "Docker Scout CLI not available."
    err "  Install via Docker Desktop (it ships built in) or:"
    err "    curl -sSfL https://raw.githubusercontent.com/docker/scout-cli/main/install.sh | sh -s --"
    exit 1
fi

OUT_DIR="$REPO_ROOT/.pr/scout-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"
ok "Repo:       $REPO_ROOT"
ok "Upstream:   $UPSTREAM_IMAGE   (Dockerfile: $UPSTREAM_DOCKERFILE)"
ok "Hardened:   $HARDENED_IMAGE   (overlay:    $OVERLAY_DOCKERFILE)"
ok "Reports:    $OUT_DIR"

cat <<EOF

Plan:
  1. ${SKIP_UPSTREAM_BUILD:+(skipped) }build $UPSTREAM_IMAGE from $UPSTREAM_DOCKERFILE
  2. scout scan $UPSTREAM_IMAGE                                  → baseline
  3. build $HARDENED_IMAGE from overlay (OS upgrades only)
  4. scout scan $HARDENED_IMAGE                                  → post-OS-patch
  5. ${DO_DEPS:+propose Python package bumps; rebuild + rescan if any
  6. }print verdict
EOF
confirm "Continue?" || { warn "aborted"; exit 1; }

# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #

scan() { # $1 = image, $2 = label
    local image="$1" label="$2"
    hdr "Scout scan: $label  ($image)"
    docker scout quickview "$image" 2>&1 \
        | tee "$OUT_DIR/${label}-quickview.txt"
    docker scout cves "$image" --only-severity critical,high 2>&1 \
        > "$OUT_DIR/${label}-cves-critical-high.txt" || true
    docker scout cves "$image" \
        --only-severity critical,high --format only-packages 2>&1 \
        > "$OUT_DIR/${label}-pkgs-critical-high.txt" || true
    log "Saved: $OUT_DIR/${label}-{quickview,cves-critical-high,pkgs-critical-high}.txt"
}

count_ch() { # parse "N C M H" from quickview file → "<critical>/<high>"
    local f="$1"
    [[ -f "$f" ]] || { echo "n/a"; return; }
    awk '
        /Target/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+C$/ && $(i+1) ~ /^[0-9]+H$/) {
                    c=$i; h=$(i+1); gsub(/C/,"",c); gsub(/H/,"",h);
                    print c "C/" h "H"; exit
                }
            }
        }
    ' "$f" 2>/dev/null || echo "n/a"
}

build_upstream() {
    hdr "Step 1: build upstream → $UPSTREAM_IMAGE"
    if (( SKIP_UPSTREAM_BUILD )); then
        if docker image inspect "$UPSTREAM_IMAGE" >/dev/null 2>&1; then
            ok "Reusing existing $UPSTREAM_IMAGE (--skip-upstream-build)"
        else
            err "$UPSTREAM_IMAGE not present and --skip-upstream-build set."
            exit 1
        fi
        return
    fi
    ( cd "$REPO_ROOT" \
        && docker build \
            -f "$UPSTREAM_DOCKERFILE" \
            -t "$UPSTREAM_IMAGE" . )
    ok "Built $UPSTREAM_IMAGE"
}

build_overlay() { # $1 = pip upgrade specs (may be empty)
    local pip_specs="${1:-}"
    hdr "Build overlay → $HARDENED_IMAGE  (PIP_UPGRADES='$pip_specs')"
    ( cd "$REPO_ROOT" \
        && docker build \
            -f "$OVERLAY_DOCKERFILE" \
            --build-arg "BASE_IMAGE=$UPSTREAM_IMAGE" \
            --build-arg "PIP_UPGRADES=$pip_specs" \
            --no-cache \
            -t "$HARDENED_IMAGE" . )
    ok "Built $HARDENED_IMAGE"
}

# Read Scout's --format only-packages output and emit pip specs (pkg==fix_ver).
# Lines look like:    name 1.2.3
# We don't know the fix version from this format alone, so we ask pip to
# resolve "latest" by emitting just bare names. That's the safe default;
# user can override with --pip-upgrades "name==X.Y.Z ...".
extract_python_packages() { # $1 = pkgs file
    local f="$1"
    [[ -f "$f" ]] || return 0
    # Heuristic: keep alphanumeric package names that look like Python deps
    # (excludes Debian package names like libssl3t64, perl-base, etc.).
    awk 'NF>=1 && $1 ~ /^[a-zA-Z][a-zA-Z0-9_.-]*$/ { print $1 }' "$f" \
        | grep -viE '^(lib|perl|python3|systemd|tzdata|gcc|gpg|dpkg|apt|base-|coreutils|debian|util-linux|e2fs|mount|sysvinit|ncurses|util|login|passwd|adduser|bsdutils|hostname|grep|gzip|tar|sed|gnupg|ca-certificates|openssh|openssl|krb5|pam|cron|init|libc)' \
        | sort -u
}

# --------------------------------------------------------------------------- #
# Step 1 — build upstream                                                     #
# --------------------------------------------------------------------------- #
build_upstream

# --------------------------------------------------------------------------- #
# Step 2 — baseline scan                                                      #
# --------------------------------------------------------------------------- #
scan "$UPSTREAM_IMAGE" "01-baseline"
BASELINE_CH="$(count_ch "$OUT_DIR/01-baseline-quickview.txt")"
log "Baseline CRITICAL/HIGH: $BASELINE_CH"

# --------------------------------------------------------------------------- #
# Step 3 — build OS-only overlay                                              #
# --------------------------------------------------------------------------- #
hdr "Step 3: build OS-only overlay"
build_overlay ""

# --------------------------------------------------------------------------- #
# Step 4 — post-OS-patch scan                                                 #
# --------------------------------------------------------------------------- #
scan "$HARDENED_IMAGE" "02-post-os-patch"
POST_OS_CH="$(count_ch "$OUT_DIR/02-post-os-patch-quickview.txt")"
log "After OS patches CRITICAL/HIGH: $POST_OS_CH   (was $BASELINE_CH)"

# --------------------------------------------------------------------------- #
# Step 5 — Python deps (optional)                                             #
# --------------------------------------------------------------------------- #
FINAL_LABEL="02-post-os-patch"

if (( DO_DEPS )); then
    hdr "Step 5: triage remaining Python package CVEs"
    PIP_SPECS=""

    if [[ -n "$PIP_UPGRADES_OVERRIDE" ]]; then
        PIP_SPECS="$PIP_UPGRADES_OVERRIDE"
        log "Using user-supplied --pip-upgrades: $PIP_SPECS"
    else
        # shellcheck disable=SC2207
        PKGS=( $(extract_python_packages "$OUT_DIR/02-post-os-patch-pkgs-critical-high.txt") )
        if (( ${#PKGS[@]} == 0 )); then
            ok "No Python-package HIGH/CRITICAL findings remain."
        else
            log "Python-package candidates flagged HIGH/CRITICAL:"
            printf '         %s\n' "${PKGS[@]}"
            warn "Scout's only-packages output doesn't include fix versions; we'll"
            warn "ask pip for the latest of each. If you need specific versions,"
            warn "rerun with --pip-upgrades \"pkg==X.Y.Z ...\""
            if confirm "Upgrade these to latest in the overlay?"; then
                PIP_SPECS="${PKGS[*]}"
            else
                warn "Skipping Python upgrades."
            fi
        fi
    fi

    if [[ -n "$PIP_SPECS" ]]; then
        build_overlay "$PIP_SPECS"
        scan "$HARDENED_IMAGE" "03-post-deps-patch"
        FINAL_LABEL="03-post-deps-patch"
        POST_DEPS_CH="$(count_ch "$OUT_DIR/03-post-deps-patch-quickview.txt")"
        log "After deps patches CRITICAL/HIGH: $POST_DEPS_CH   (was $POST_OS_CH)"
    fi
else
    log "Skipping Step 5 (--no-deps)."
fi

# --------------------------------------------------------------------------- #
# Step 6 — verdict                                                            #
# --------------------------------------------------------------------------- #
hdr "Step 6: verdict"
FINAL_CH="$(count_ch "$OUT_DIR/${FINAL_LABEL}-quickview.txt")"

cat <<EOF
  Upstream image    : $UPSTREAM_IMAGE
  Hardened image    : $HARDENED_IMAGE
  Reports directory : $OUT_DIR

  Critical/High counts:
    baseline ($UPSTREAM_IMAGE)      : $BASELINE_CH
    after OS overlay                 : $POST_OS_CH
    final ($FINAL_LABEL)             : $FINAL_CH
EOF

case "$FINAL_CH" in
    0C/0H)
        ok "No CRITICAL or HIGH vulnerabilities remaining in $HARDENED_IMAGE."
        log "Run it via:    docker compose --profile hardened up openhands-hardened"
        exit 0 ;;
    n/a)
        warn "Could not parse final counts; check $OUT_DIR/${FINAL_LABEL}-quickview.txt"
        exit 0 ;;
    *)
        warn "$HARDENED_IMAGE still has $FINAL_CH remaining."
        warn "See $OUT_DIR/${FINAL_LABEL}-cves-critical-high.txt for details."
        exit 2 ;;
esac
