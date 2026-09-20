#!/usr/bin/env bash
# engine-backup-fixture.sh (ga-ta2w6r) -- helpers SOURCED pelos selftests de
# engine-backup-lib, engine-binary-backup-guard e engine-window-run.
#
# Tudo acontece em $FX_WORK (mktemp -d): repos git descartaveis e um remoto
# "GitHub" que e um repo bare local. Nada aqui toca repo, binario, symlink ou
# config de git reais (GIT_CONFIG_GLOBAL=/dev/null; identidade por env).

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
assert_eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$2', veio '$3')"; fi; }
assert_has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (nao achei '$3' em: $(printf '%s' "$2" | head -c 400))" ;; esac; }
assert_lacks() { case "$2" in *"$3"*) bad "$1 (achei '$3' em: $(printf '%s' "$2" | head -c 400))" ;; *) ok "$1" ;; esac; }
fx_finish() { echo; echo "── $PASS ok, $FAIL falha(s) ──"; [ "$FAIL" -eq 0 ]; }

# fx_init <workdir> -- cria $FX_REMOTE (bare) e $FX_ENGINE (clone de trabalho com
# origin -> $FX_REMOTE, 1 commit "base" ja empurrado em main).
fx_init() {
    FX_WORK="$1"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@test.local
    export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@test.local
    FX_REMOTE="$FX_WORK/remote.git"
    FX_ENGINE="$FX_WORK/engine"
    mkdir -p "$FX_WORK"
    git init -q --bare -b main "$FX_REMOTE"
    git init -q -b main "$FX_ENGINE"
    git -C "$FX_ENGINE" remote add origin "$FX_REMOTE"
    printf 'base\n' > "$FX_ENGINE/f.txt"
    git -C "$FX_ENGINE" add f.txt
    git -C "$FX_ENGINE" commit -q -m base
    git -C "$FX_ENGINE" push -q origin main
}

# fx_commit <repo|worktree> <texto> [epoch] -- novo commit no branch atual; imprime o sha completo.
fx_commit() {
    printf '%s\n' "$2" >> "$1/f.txt"
    git -C "$1" add f.txt
    if [ -n "${3:-}" ]; then
        GIT_AUTHOR_DATE="@$3" GIT_COMMITTER_DATE="@$3" git -C "$1" commit -q -m "$2"
    else
        git -C "$1" commit -q -m "$2"
    fi
    git -C "$1" rev-parse HEAD
}

# Binarios de mentira: imprimem o stamp que o gc/bd de verdade imprimem.
fx_fake_gc() {   # <path> <token-do-commit, ex.: 4f4837703-dirty>
    printf '#!/bin/sh\necho "engwin-fixture (commit: %s, built: 2026-01-01T00:00:00Z)"\n' "$2" > "$1"
    chmod +x "$1"
}
fx_fake_gc_unstamped() {   # <path>
    printf '#!/bin/sh\necho "dev (commit: unknown, built: unknown)"\n' > "$1"
    chmod +x "$1"
}
fx_fake_bd() {   # <path> <build> <commit-do-stamp-vcs (o do repo ERRADO)>
    printf '#!/bin/sh\ncat <<J\n{"branch":"main","build":"%s","commit":"%s","schema_version":1,"version":"1.1.0"}\nJ\n' "$2" "$3" > "$1"
    chmod +x "$1"
}
# notify de mentira: registra cada chamada (nunca dispara notificacao de verdade).
fx_fake_notify() {   # <path-do-script> <arquivo-de-log>
    printf '#!/bin/sh\necho "NOTIFY $*" >> "%s"\n' "$2" > "$1"
    chmod +x "$1"
}
