#!/bin/bash
# 3 rodadas x 9 configs, uma por vez, contra o Chrome descartavel :47222. Falha de uma config nao derruba o resto.
export PATH=/opt/homebrew/bin:$PATH EVAL_S=$1
cd "$EVAL_S/work" || exit 2
for r in r1 r2 r3; do
  echo "### round $r  $(date +%H:%M:%S)  load: $(uptime | sed 's/.*load averages*: //')"
  for c in pw-A pw-B pw-B2 pw-npx ab-full-A ab-c-A ab-i-A ab-i-B ab-batch; do
    RUN_TAG=$r timeout 300 node "$EVAL_S/scripts/run-task.js" $c 2>&1 | tail -2 | cut -c1-1500
    echo "rc=$? cfg=$c"
  done
done
echo "### DONE $(date +%H:%M:%S)"
