#!/bin/sh
# fp.sh pid [pid...] -> soma do Footprint (phys_footprint, o que o Activity Monitor mostra) em MB.
# Lido nada (pid morto / sem permissao) = ERRO rc 3, nunca "0 MB": 0 MB seria um valor valido.
args=""; for p in "$@"; do args="$args -p $p"; done
out=$(footprint $args 2>/dev/null) || true
printf '%s\n' "$out" | awk '/\[[0-9]+\]: .*Footprint:/ { for(i=1;i<=NF;i++) if($i=="Footprint:"){v=$(i+1); u=$(i+2); if(u=="KB")v/=1024; else if(u=="GB")v*=1024; else if(u=="bytes"||u=="B")v/=1048576; s+=v; n++}} END{ if(n==0){print "ERRO: footprint nao leu nenhum processo" > "/dev/stderr"; exit 3} printf "%d procs, %.1f MB\n", n, s}'
