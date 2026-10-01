#!/usr/bin/env bash
# build-estudo.sh — ga-5c3msy: ../token-por-bead-e8.md -> ONE self-contained HTML for the 📚 Estudos tab, with the Athos's
# canonical table behaviour (wa-6qnv9: click to sort, right-click/hold to filter a column, sticky header).
# Builds and TESTS; it does not publish (publishing writes to the WA rig's shared/data/estudos — see README.md).
#
#   bash build-estudo.sh <output.html>
#
# Needs pandoc and node (+ the jsdom module for the DOM test, found via JSDOM_PATH). Read-only on the repo; writes only <output.html>.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD="$HERE/../token-por-bead-e8.md"
OUT="${1:?usage: build-estudo.sh <output.html>}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
[[ -f "$MD" ]] || { echo "build-estudo: report not found: $MD" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/build-estudo.XXXXXX")"; trap 'rm -rf "$T"' EXIT
{ echo '<style id="estudo-tabelas-css">'; cat "$HERE/estudo-tabelas.css"; echo '</style>'; } > "$T/head.html"
# the script is inlined verbatim; a literal closing script tag inside it would end the element early
if grep -q -F '</script' "$HERE/estudo-tabelas.js"; then echo "build-estudo: estudo-tabelas.js contains a closing script tag" >&2; exit 2; fi
{ echo '<script id="estudo-tabelas">'; cat "$HERE/estudo-tabelas.js"; echo '</script>'; } > "$T/after.html"

pandoc -f gfm -t html5 -s \
  --metadata pagetitle="Tokens por bead aprovada: medidor, baseline de 7 dias e A/B de effort (E8, ga-5c3msy)" \
  --include-in-header="$T/head.html" --include-after-body="$T/after.html" \
  -o "$OUT" "$MD"

# jsdom is not installed globally; the WA rig carries it (25.x). JSDOM_PATH overrides where to look.
NODE_PATH="${JSDOM_PATH:-/Users/athos/gt/whatsapp_automation/node_modules}${NODE_PATH:+:$NODE_PATH}" node "$HERE/estudo-tabelas.test.js" "$OUT"
echo "build-estudo: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
