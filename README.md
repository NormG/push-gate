# push-gate

A project-agnostic pre-push consistency gate. Keeps version numbers in sync across all files, enforces code formatting, and blocks pushes that fail compile or lint checks. Works with any project language — configure with a single `.gate.conf` file.

---

## How it works

```
git push gate master
       │
       ▼
.githooks/pre-push (verona1)
  ├─ gate fix   → auto-sync versions, run cargo fmt
  │              → if changes made: commit + abort push with "run git push again"
  └─ gate check → cargo check, cargo clippy
                 → if failures: block push with error

       │ passes
       ▼
verona5 bare repo (optional second gate)
  └─ post-receive hook
       ├─ gate check on checked-out code
       └─ if passes: git push github
```

---

## Installation

### 1. Clone push-gate

```bash
git clone git@github.com:NormG/push-gate ~/Projects/push-gate
chmod +x ~/Projects/push-gate/gate
```

Add to `$PATH` (add to `~/.bashrc`):
```bash
export PATH="${HOME}/Projects/push-gate:${PATH}"
```

### 2. Install into a project

```bash
gate install /path/to/your/project
```

This creates:
- `/path/to/project/.gate.conf` — copy of `.gate.conf.example` (edit this)
- `/path/to/project/.githooks/pre-push` — the hook script
- Sets `core.hooksPath = .githooks` in the project's git config
- Records `gate.path` so the hook always finds the `gate` binary

### 3. Configure the project

Edit `.gate.conf` in the project root. The file is plain bash and defines five variables — see [`.gate.conf.example`](.gate.conf.example) for the full schema.

### 4. Commit the gate files

```bash
git add .gate.conf .githooks/pre-push
git commit -m "chore: install push-gate"
```

Any collaborator who clones the repo needs to run `gate install .` once to activate the hook (git hooks are not cloned automatically).

---

## Commands

```bash
gate check   [dir]    # dry-run: report what is out of sync
gate fix     [dir]    # apply auto-fixable changes (version sync + fmt)
gate run     [dir]    # fix + check — used by the pre-push hook
gate install <dir>    # scaffold .gate.conf and .githooks/pre-push
```

---

## `.gate.conf` schema

```bash
# ── Version source (required) ─────────────────────────────────────────────
# File that contains the canonical version.
GATE_VERSION_SOURCE="Cargo.toml"

# Regex to extract the version (first capture group).
GATE_VERSION_REGEX='^version\s*=\s*"(.+)"'

# ── Version sync targets ──────────────────────────────────────────────────
# "file:match-regex:replacement" triples.
# {VERSION} is substituted with the version read from GATE_VERSION_SOURCE.
# match-regex  — ERE that the line SHOULD contain when already in sync
# replacement  — exact string to use when patching
GATE_SYNC=(
    "some.spec:^Version:\s*{VERSION}:Version:   {VERSION}"
    'script.sh:^VERSION="{VERSION}":VERSION="{VERSION}"'
)

# ── Auto-fix commands ─────────────────────────────────────────────────────
# Run by `gate fix`; may modify files; changes are committed automatically.
GATE_AUTO_FIX=(
    "cargo fmt"
)

# ── Must-pass checks ──────────────────────────────────────────────────────
# Must exit 0 AND produce no output. Any output = failure.
GATE_MUST_PASS=(
    "cargo check --quiet"
    "cargo clippy --quiet"
)
```

---

## verona5 remote gate (optional)

For a second line of defence — useful if multiple people push, or if you want to ensure nothing sneaks through even with `--no-verify`.

```bash
bash ~/Projects/push-gate/setup-gate.sh \
  --host    verona5 \
  --user    norm \
  --repo    /home/norm/git/project-name.git \
  --project /home/norm/Projects/project-name \
  --github  git@github.com:NormG/project-name.git
```

After setup, push through the gate:
```bash
git push gate master   # validated → forwarded to GitHub
git push origin master # direct (skip gate — not recommended)
```

### Requirements on verona5
- `git` installed
- SSH key from verona1 authorised (`~/.ssh/authorized_keys`)
- `cargo`, `rustc`, and any other tools listed in `GATE_MUST_PASS`

---

## Adding a new project

```bash
gate install /path/to/new-project
# edit .gate.conf
git add .gate.conf .githooks/pre-push && git commit -m "chore: install push-gate"
```

Each project has its own `.gate.conf` — the gate binary is shared.

---

## License

GPL-3.0-or-later
