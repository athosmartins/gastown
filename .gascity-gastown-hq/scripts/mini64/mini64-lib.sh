#!/usr/bin/env bash
# mini64-lib.sh — peças comuns de espera.sh e carregar-camada.sh (ga-ke5w2ie.2). Só funções: quem faz `source` escolhe as opções do shell.
# Roda no bash 3.2 do macOS: sem array associativo, mapfile, ${x,,} nem array vazio sob set -u.
# Toda leitura do mundo (pasta, marcador, tabela, launchctl) traz, na linha de cima, o que o código faz se vier vazia e se falhar: falha NUNCA vira "vazio".

M64_TSV="${M64_TSV:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/camadas.tsv}"   # o override é do selftest (tabela de mentira)
LAUNCHCTL="${MINI64_LAUNCHCTL:-launchctl}"   # o ÚNICO jeito de chamar o launchctl; o selftest aponta para um falso

# m64_dirs: onde moram os plists, a espera e o marcador. Tudo sai do $HOME: o selftest roda com um HOME de mentira.
m64_dirs() {
  # vazio → HOME ausente ou "/": rc 2 (nunca cair em /Library); falhou/ilegível → rc 2 também
  case "${HOME:-}" in (""|"/") echo "mini64: HOME ausente ou '/': não sei onde agir, nada foi feito" >&2; return 2;; esac
  [ -d "$HOME" ] && [ -x "$HOME" ] || { echo "mini64: HOME ilegível: $HOME" >&2; return 2; }
  M64_AGENTS="$HOME/Library/LaunchAgents"; M64_ESPERA="$HOME/Library/LaunchAgents.mini64-espera"; M64_MARCADOR="$HOME/.mini64-espera"
  M64_UID="$(id -u)"
}

# m64_tabela_ok: valida a tabela INTEIRA (linha fora do formato = tabela recusada, nunca pulada)
m64_tabela_ok() {
  # vazio → tabela sem @camada, @familia ou linhas: rc 2; falhou/ilegível → rc 2 também, nunca "ninguém tem camada"
  [ -f "$M64_TSV" ] && [ -r "$M64_TSV" ] || { echo "mini64: tabela ilegível: $M64_TSV" >&2; return 2; }
  awk -F'\t' '
    function ruim(m) { print "mini64: " FILENAME ":" FNR ": " m > "/dev/stderr"; erro = 1 }
    /^[[:space:]]*(#|$)/ { next }
    $1 == "@camada" { if (NF != 4 || $2 !~ /^(0|[1-9][0-9]*)$/ || $3 !~ /^[a-z0-9-]+$/ || $4 !~ /^(-|[a-z0-9-]+)$/ || ($2 in def)) ruim("@camada inválida ou repetida"); else { def[$2] = 1; nc++ }; next }
    $1 == "@familia" { if (NF != 3 || $2 !~ /^[A-Za-z0-9._-]+$/ || $3 !~ /^[0-9]+$/ || ($2 in vis)) ruim("@familia inválida ou repetida"); else { vis[$2] = 1; nf++; usa[$3] = 1 }; next }
    { if (NF != 3 || $1 !~ /^[A-Za-z0-9._-]+$/ || $2 !~ /^[0-9]+$/ || $3 == "" || ($1 in vis)) ruim("esperava prefixo<TAB>camada<TAB>motivo (ou prefixo repetido)"); else { vis[$1] = 1; nr++; usa[$2] = 1 } }
    END { for (c in usa) if (!(c in def)) { print "mini64: camada " c " usada e não definida por @camada" > "/dev/stderr"; erro = 1 }
          if (nc == 0 || nf == 0 || nr == 0) { print "mini64: tabela sem @camada, @familia ou linhas" > "/dev/stderr"; erro = 1 }
          exit erro }
  ' "$M64_TSV"
}

# m64_classificar: labels em stdin (um por linha) → "label<TAB>camada<TAB>origem"; origem = explicito (linha própria) | padrao (só a família) | fora (camada "-")
m64_classificar() {
  # vazio → nada impresso, rc 0; falhou/ilegível → rc ≠ 0 (o chamador trata como "não sei")
  awk -F'\t' -v OFS='\t' '
    FNR == NR { if ($0 ~ /^[[:space:]]*(#|$)/ || $1 == "@camada") next
                if ($1 == "@familia") { nf++; fp[nf] = $2; fc[nf] = $3 } else { nr++; rp[nr] = $1; rc[nr] = $2 }; next }
    { l = $0; best = 0; cam = "-"; o = "fora"
      for (i = 1; i <= nr; i++) if (length(rp[i]) > best && substr(l, 1, length(rp[i])) == rp[i]) { best = length(rp[i]); cam = rc[i]; o = "explicito" }
      if (o == "fora") for (i = 1; i <= nf; i++) if (length(fp[i]) > best && substr(l, 1, length(fp[i])) == fp[i]) { best = length(fp[i]); cam = fc[i]; o = "padrao" }
      print l, cam, o }
  ' "$M64_TSV" -
}

# m64_classificados <pasta>: m64_classificar dos *.plist da pasta (o label é o nome sem .plist, como o plist-bd-env-lint --installed)
m64_classificados() {
  # vazio → nada impresso, rc 0; falhou/ilegível (não existe, não é pasta, sem permissão) → rc 2, nunca lista vazia
  [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ] || return 2
  local f
  for f in "$1"/*.plist; do if [ -f "$f" ] || [ -L "$f" ]; then printf '%s\n' "${f##*/}"; fi; done | sed 's/\.plist$//' | LC_ALL=C sort | m64_classificar
}

# m64_espera_classificados: a pasta da espera; ainda não existir é "vazio" (a espera nunca foi ligada), existir e não ser lida é rc 2
m64_espera_classificados() { if [ -e "$M64_ESPERA" ] || [ -L "$M64_ESPERA" ]; then m64_classificados "$M64_ESPERA"; fi; }

# m64_camada_info <N>: "nome<TAB>exige" da camada · m64_camadas: os números das camadas, "0,1,2,…"
# vazio → camada não definida, rc 1; falhou/ilegível → rc ≠ 0 também, e quem chama RECUSA (nunca age sobre uma camada que não conseguiu ler)
m64_camada_info() { awk -F'\t' -v n="$1" '$1 == "@camada" && $2 + 0 == n + 0 { print $3 "\t" $4; f = 1 } END { exit !f }' "$M64_TSV"; }
m64_camadas() { awk -F'\t' '$1 == "@camada" { printf "%s%s", s, $2; s = "," } END { print "" }' "$M64_TSV"; }

# m64_marcador: sim | nao | nao-sei
m64_marcador() {
  # vazio → "nao" (o arquivo não existe); falhou/ilegível (existe e não é um arquivo legível) → "nao-sei", nunca "nao"
  if [ -f "$M64_MARCADOR" ] && [ -r "$M64_MARCADOR" ]; then echo sim
  elif [ -e "$M64_MARCADOR" ] || [ -L "$M64_MARCADOR" ]; then echo nao-sei
  else echo nao; fi
}

# m64_carregado <label>: rc 0 = carregado, 1 = não carregado, 2 = não sei
m64_carregado() {
  local rc
  # vazio → n/a; falhou → só o rc 113 do launchctl (serviço inexistente) vale como "não carregado"; qualquer outro é "não sei", e quem chama não carrega
  "$LAUNCHCTL" print "gui/$M64_UID/$1" >/dev/null 2>&1; rc=$?
  case "$rc" in (0) return 0;; (113) return 1;; (*) return 2;; esac
}

# m64_contar <texto>: linhas não vazias · m64_por_camada: resumo " [camada K: n]" da saída de m64_classificados em stdin
m64_contar() { printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'; }
m64_por_camada() { awk -F'\t' 'NF && $3 != "fora" { print $2 }' | sort -n | uniq -c | awk '{ printf " [camada %s: %s]", $2, $1 }'; }

# m64_lista <título> <nomes>: nada se a lista é vazia; senão o título e até 15 nomes recuados (o resto vira "… e mais N")
m64_lista() {
  [ -n "$2" ] || return 0
  echo "$1"; printf '%s\n' "$2" | awk 'NF { if (++n <= 15) print "    " $0 } END { if (n > 15) print "    … e mais " n - 15 }'
}
