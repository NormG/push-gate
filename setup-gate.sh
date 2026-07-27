#!/usr/bin/env bash
# =============================================================================
# setup-gate.sh — Configure a remote machine as a push gate
#
# Architecture:
#   verona1  ──git push gate──►  verona5 (bare repo + post-receive hook)
#                                    │
#                            gate check passes?
#                                    │ yes
#                                    ▼
#                              github (origin)
#
# The post-receive hook on verona5 runs 'gate check' on the pushed code.
# If all checks pass it pushes to GitHub.  If they fail it rejects the push
# and prints the error so verona1 sees it immediately.
#
# Usage (run once from verona1):
#   bash setup-gate.sh \
#     --host    verona5 \
#     --user    norm \
#     --repo    /home/norm/git/home-backup.git \   # bare repo path on verona5
#     --project /home/norm/Projects/home-backup2 \  # local project on verona1
#     --github  git@github.com:NormG/Backup-Tool.git
#
# After setup, push via the gate with:
#   git push gate master
# =============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;34m'; X='\033[0m'
else
    G=''; Y=''; R=''; B=''; X=''
fi
ok()     { printf "${G}  ✓  ${X}%s\n" "$*"; }
step()   { printf "${B}  →  ${X}%s\n" "$*"; }
fail()   { printf "${R}  ✗  ${X}%s\n" "$*" >&2; }
die()    { fail "$*"; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
GATE_HOST=""
GATE_USER="${USER}"
GATE_REPO_PATH=""
LOCAL_PROJECT=""
GITHUB_URL=""
GATE_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    GATE_HOST="$2";       shift 2 ;;
        --user)    GATE_USER="$2";       shift 2 ;;
        --repo)    GATE_REPO_PATH="$2";  shift 2 ;;
        --project) LOCAL_PROJECT="$2";   shift 2 ;;
        --github)  GITHUB_URL="$2";      shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${GATE_HOST}" ]]     || die "--host required (e.g. verona5)"
[[ -n "${GATE_REPO_PATH}" ]] || die "--repo required (bare repo path on ${GATE_HOST})"
[[ -n "${LOCAL_PROJECT}" ]] || die "--project required (local project directory)"
[[ -n "${GITHUB_URL}" ]]    || die "--github required (GitHub remote URL)"
[[ -d "${LOCAL_PROJECT}" ]] || die "Local project directory not found: ${LOCAL_PROJECT}"

GATE_SSH="${GATE_USER}@${GATE_HOST}"

printf "\n${B}push-gate remote setup${X}\n"
printf "  Gate host  : ${GATE_SSH}\n"
printf "  Bare repo  : ${GATE_REPO_PATH}\n"
printf "  Project    : ${LOCAL_PROJECT}\n"
printf "  GitHub URL : ${GITHUB_URL}\n\n"

# ── 1. Test SSH connectivity ───────────────────────────────────────────────────
step "Testing SSH to ${GATE_SSH}…"
ssh -o BatchMode=yes -o ConnectTimeout=5 "${GATE_SSH}" 'echo ok' &>/dev/null \
    || die "Cannot SSH to ${GATE_SSH}.  Set up key-based auth first."
ok "SSH connection OK"

# ── 2. Initialise bare repo on gate host ──────────────────────────────────────
step "Initialising bare repo at ${GATE_SSH}:${GATE_REPO_PATH}…"
ssh "${GATE_SSH}" "
    set -e
    mkdir -p '$(dirname "${GATE_REPO_PATH}")'
    if [ ! -d '${GATE_REPO_PATH}' ]; then
        git init --bare '${GATE_REPO_PATH}'
        echo 'Bare repo created.'
    else
        echo 'Bare repo already exists.'
    fi
"
ok "Bare repo ready"

# ── 3. Install push-gate on the gate host ────────────────────────────────────
step "Copying push-gate tool to ${GATE_SSH}…"
REMOTE_GATE_DIR="/home/${GATE_USER}/.local/share/push-gate"
ssh "${GATE_SSH}" "mkdir -p '${REMOTE_GATE_DIR}'"
scp -q "${GATE_TOOL_DIR}/gate" "${GATE_SSH}:${REMOTE_GATE_DIR}/gate"
ssh "${GATE_SSH}" "chmod +x '${REMOTE_GATE_DIR}/gate'"
ok "push-gate installed at ${REMOTE_GATE_DIR}/gate on ${GATE_HOST}"

# ── 4. Write post-receive hook on gate host ───────────────────────────────────
step "Installing post-receive hook…"
HOOK_PATH="${GATE_REPO_PATH}/hooks/post-receive"

# We need a work-tree on verona5 to run gate check.  We'll use a sibling dir.
WORK_TREE="$(dirname "${GATE_REPO_PATH}")/$(basename "${GATE_REPO_PATH}" .git)-work"

ssh "${GATE_SSH}" "
set -e
mkdir -p '${WORK_TREE}'
cat > '${HOOK_PATH}' << 'HOOKEOF'
#!/usr/bin/env bash
# push-gate post-receive hook — auto-installed by setup-gate.sh
set -euo pipefail

GATE_BIN='${REMOTE_GATE_DIR}/gate'
WORK_TREE='${WORK_TREE}'
GIT_DIR='${GATE_REPO_PATH}'
GITHUB='${GITHUB_URL}'

while read -r oldrev newrev refname; do
    branch=\"\${refname#refs/heads/}\"
    echo \"push-gate: checking \${branch} (\${newrev:0:7})…\"

    # Check out pushed commit into work tree
    GIT_WORK_TREE=\"\${WORK_TREE}\" GIT_DIR=\"\${GIT_DIR}\" \\
        git checkout -f \"\${newrev}\" -- 2>/dev/null

    # Run gate check (read-only: does not modify files)
    if \"\${GATE_BIN}\" check \"\${WORK_TREE}\"; then
        echo \"push-gate: ✓ all checks passed — forwarding to GitHub\"
        git push \"\${GITHUB}\" \"\${newrev}:refs/heads/\${branch}\"
    else
        echo \"push-gate: ✗ checks FAILED — push to GitHub BLOCKED\" >&2
        exit 1
    fi
done
HOOKEOF
chmod +x '${HOOK_PATH}'
echo 'Hook installed.'
"
ok "post-receive hook installed"

# ── 5. Add GitHub as a remote on the bare repo ───────────────────────────────
step "Configuring GitHub remote on bare repo…"
ssh "${GATE_SSH}" "
    git -C '${GATE_REPO_PATH}' remote remove github 2>/dev/null || true
    git -C '${GATE_REPO_PATH}' remote add github '${GITHUB_URL}'
    echo 'Remote github set to ${GITHUB_URL}'
"
ok "GitHub remote configured on gate"

# ── 6. Add gate remote on verona1 ────────────────────────────────────────────
step "Adding 'gate' remote to local project…"
LOCAL_PROJECT="$(cd "${LOCAL_PROJECT}" && pwd)"
git -C "${LOCAL_PROJECT}" remote remove gate 2>/dev/null || true
git -C "${LOCAL_PROJECT}" remote add gate \
    "ssh://${GATE_SSH}${GATE_REPO_PATH}"
ok "Remote 'gate' added: ssh://${GATE_SSH}${GATE_REPO_PATH}"

# ── Done ──────────────────────────────────────────────────────────────────────
printf "\n${G}════════════════════════════════════════${X}\n"
printf "${G} Gate setup complete!${X}\n"
printf "${G}════════════════════════════════════════${X}\n\n"
echo "  Push through the gate:"
echo "    git push gate master"
echo ""
echo "  The gate will run 'gate check' on ${GATE_HOST}."
echo "  If all checks pass, it forwards to GitHub automatically."
echo "  If any check fails, the push is rejected with the error."
echo ""
echo "  Push directly to GitHub (skip gate — not recommended):"
echo "    git push origin master"
