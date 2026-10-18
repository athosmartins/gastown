#!/usr/bin/env bash
# remote-shim-mutants.selftest.sh — a campanha de mutantes do remote-shim (remote-shim.mutants.py) com cara de selftest, para o `mbp-run.sh --repo hq` levá-la ao nó
# Linux (o alvo tem que ser um *.selftest.sh); os mutantes do transporte por puxada (p, u) rodam o remote-shim-spool.selftest.sh, que não precisa de sshd.
# Contents: Uso
# USO: scripts/remote-shim-mutants.selftest.sh [--jobs N] [--only NOME,NOME]   (os argumentos vão direto para o remote-shim.mutants.py; sai 0 só se TODO mutante morreu)
set -u
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/remote-shim.mutants.py" "$@"
