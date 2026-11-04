#!/bin/bash
# disk-recovery-report.selftest.sh — testa disk-recovery-report.py (ga-1p1i5jr.5) com logs no formato EXATO do maestro. Só lê arquivos de teste; não toca na máquina.
#
# ## Contents
#   O que prova · Como rodar
#
# O QUE PROVA   a conta de cada degrau (chamadas, agiu/adiou/falhou/não leu, MB devolvidos, `depois=?` fora da soma); o reinício do D4 inferido da chamada SEM resultado; o aceite da missão nas bordas
#   (60 min não é > 60, 61 min sim; ação até 300 s depois do fim da janela vale, 360 s não; lacuna ENTRE duas leituras baixas une a janela; silêncio depois de uma leitura baixa = NÃO VERIFICADO; só chamada
#   adiada = OK_ADIADA); cobertura mínima de horas; --since; log rotacionado; e os TRÊS estados do arquivo (ausente / sem permissão / diretório = rc 3 sem relatório; vazio = NÃO VERIFICADO; lixo = contado, sem
#   quebrar). O formato das linhas é o do maestro (disk-recovery-ladder.sh); o e2e (disk-recovery-e2e.selftest.sh) prova o mesmo contra o log que o maestro REAL escreve.
# COMO RODAR    bash scripts/disk-recovery-report.selftest.sh      (~2 s). REPORT_PATH=/cópia.py testa uma cópia (mutantes); REPORT_PY=/caminho/python3 troca o interpretador (o mini usa /usr/bin/python3 3.9).
# LASTRO (ga-pfnzwda)   as bordas ao segundo (janela que começa na chamada, graça 300/301 s, lacuna 600/601 s, silêncio 3900/3901 s, --since/--until fechados, gap 0 não é carimbo para trás), os campos do JSON
#   (ordem das chaves, horas com 2 casas, teto de 5 avisos e de 5 silêncios, texto de 90 caracteres) e as linhas do texto (cobertura, nota de sem medida/sem ganho, "nenhuma" chamada) têm um caso cada.
#   Mortos aqui, os 9 da bead: 386dab5fe2 0a07a2e3df 1cf28aa68c 282ce0efce 1b87a59fa8 2e1ca007a8 2f0f743a53 3498435310 05a613788e; dos 181 mutantes do arquivo só o 83f5030d00 (abaixo) fica vivo.
# EQUIVALENT 83f5030d00: o `else 0` -> `else 1` do gap da 1a leitura: so ha `prev` vazio na 1a volta, quando `cur` tambem e None, e o gap so e lido com a janela `cur` aberta
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="${REPORT_PATH:-$HERE/disk-recovery-report.py}"; PY="${REPORT_PY:-/usr/bin/python3}"
[ -f "$REPORT" ] || { echo "FATAL: $REPORT não existe"; exit 1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/dr-report-st.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0; OUT=""
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ "${ST_FAILFAST:-0}" = 1 ] && { printf '\n(ST_FAILFAST) parei no 1º FAIL: %s passaram, %s falharam\n' "$PASS" "$FAIL"; exit 1; }; return 0; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
section() { printf '\n== %s\n' "$1"; }
cat > "$W/jget.py" <<'PY'
import json, re, sys
d = json.load(sys.stdin)
res = []
for path in sys.argv[1:]:
    cur = [d]
    for part in path.split("."):
        key, idx = re.match(r"^(\w+)(?:\[(\d*)\])?$", part).groups()
        vals = [c[key] for c in cur]
        cur = vals if idx is None else [x for v in vals for x in (v if idx == "" else [v[int(idx)]])]
    res.append(",".join(str(x) for x in cur))
print(" ".join(res))
PY
# ── logs no formato do maestro ──────────────────────────────────────────────────────────────────────────────────────────────────
T() { case "$1" in *:*) printf '%s' "$1" ;; *) printf '%02d:%02d:00' $(($1 / 60)) $(($1 % 60)) ;; esac; }   # minutos do dia → HH:MM:SS (ou já um HH:MM:SS, para as bordas de segundos)
L() { printf '[2026-11-02 %s] %s\n' "$(T "$1")" "$2"; }
RD() { L "$1" "leitura: livre=$2MB swap=0MB | abaixo há: D2=0s/900s D3=0s/1800s D4=0s/3600s | < 1536MB seguidas=0/2 | marcas D2=none D3=none D4=none"; }
HB() { L "$1" "ok: livre=$2MB swap=0MB (sem episódio; batimento 1/h)"; }
CALL() { L "$1" "degrau D$2: chamando /x/disk-recovery-d$2.sh --run (livre=$3MB swap=0MB; abaixo do limiar há 960s; leituras < 1536MB seguidas=0)"; }
OUTL() { L "$1" "degrau D$2: rc=$3 ($4) livre antes=$5MB depois=$6MB swap depois=0MB: D$2 --run: texto da linha"; }
LOWS() { local m=$1; while [ "$m" -le "$2" ]; do RD "$m" "$3"; m=$((m + ${4:-5})); done; }   # leituras baixas de $1 a $2 (minutos do dia), livre $3, a cada ${4:-5} min
rep() { OUT=$("$PY" -I "$REPORT" --min-hours 0 --json "$@" 2>"$W/err"); RC=$?; }
jg() { printf '%s' "$OUT" | "$PY" -I "$W/jget.py" "$@"; }
verd() { rep --log "$1"; echo "$RC $(jg acceptance 'windows[].verdict')"; }

section "a conta de cada degrau"
{ HB 540 9000; RD 600 2500; CALL 600 2 2500; OUTL 600 2 0 acted 2500 4700; RD 605 4700; CALL 605 3 4000; OUTL 605 3 0 acted 4000 5100
  CALL 610 3 4000; OUTL 610 3 10 idle 4000 4000; CALL 615 2 4000; OUTL 615 2 20 failed 4000 4000; CALL 620 2 4000; OUTL 620 2 30 unknown 4000 4000
  CALL 625 3 3000; OUTL 625 3 0 acted 3000 '?'; CALL 630 2 3000; OUTL 630 2 0 acted 3000 3000; L 632 "WARN: degrau D4 ausente"; L 633 "ESCALA: D4 elegível"; HB 690 9000; } > "$W/t1.log"
rep --log "$W/t1.log"
eq "$(jg rungs.D2.calls rungs.D2.acted rungs.D2.failed rungs.D2.unknown rungs.D2.returned_mb rungs.D2.no_gain)" "4 2 1 1 2200 1" "D2: 4 chamadas = 2 agiram + 1 falhou + 1 não leu; devolveu 4700-2500 = 2200 MB (só as que agiram); a que agiu sem ganho (3000→3000) é contada à parte"
eq "$(jg rungs.D3.calls rungs.D3.acted rungs.D3.idle rungs.D3.returned_mb rungs.D3.unknown_mb)" "3 2 1 1100 1" "D3: 3 chamadas = 2 agiram + 1 adiou; 1100 MB; a que agiu com depois=? fica FORA da soma e é contada (unknown_mb)"
eq "$(jg readings hours lines_unstamped alerts_total)" "4 2.5 0 2" "4 leituras (batimentos contam), 2,5 h de cobertura, nenhuma linha sem carimbo, 2 avisos (WARN + ESCALA)"
R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/t1.log"); case "$R_TEXT" in *"Degrau  chamadas"*"reinícios pedidos (inferido): 0, 1ª leitura depois: +0 MB"*"sem ação da escada): ATENDIDO"*) ok "a saída em texto traz a tabela por degrau (nenhum reinício = +0 MB, que é verdade) e o veredito do aceite (ATENDIDO, não 'NAO ATENDIDO')" ;; *) nope "texto sem tabela/aceite: $R_TEXT" ;; esac
case "$R_TEXT" in *"Cobertura: 2026-11-02 09:00:00 → 2026-11-02 11:30:00 = 2.5 h, 4 leituras, maior silêncio 60 min"*) ok "o texto abre com a cobertura (1ª e última linha, 2,5 h, 4 leituras, maior silêncio 60 min): a linha existe quando HÁ leituras" ;; *) nope "texto sem a linha de cobertura: $R_TEXT" ;; esac
case "$R_TEXT" in *"(0 sem medida depois, 1 sem ganho)"*"(1 sem medida depois, 0 sem ganho)"*) ok "a tabela diz o que ficou fora da soma, UM dos dois basta: D2 agiu sem ganho (0 sem medida), D3 agiu sem medida depois (0 sem ganho)" ;; *) nope "nota de sem medida/sem ganho ausente em D2 ou D3: $R_TEXT" ;; esac
{ HB 600 9000; L 601 "WARN: a1"; L 602 "WARN: a2"; L 603 "ERROR: a3"; L 604 "ESCALA: a4"; L 605 "WARN: a5"; L 606 "WARN: a6"; L 607 "ERROR: a7"; HB 660 9000; } > "$W/al.log"; rep --log "$W/al.log"
eq "$(jg alerts_total 'alerts[]')" "7 WARN: a1,WARN: a2,ERROR: a3,ESCALA: a4,WARN: a5" "7 avisos no log: o total conta os 7 e a lista mostra só os 5 primeiros (teto de 5, na ordem do log)"

section "D4: o reinício mata o maestro, a chamada fica sem resultado"
{ RD 600 1000; CALL 600 4 1000; HB 610 9000; RD 720 1000; CALL 720 4 1000; OUTL 720 4 10 idle 1000 1000; } > "$W/t2.log"
rep --log "$W/t2.log"
eq "$(jg rungs.D4.calls rungs.D4.no_result rungs.D4.reboots_inferred rungs.D4.idle rungs.D4.after_boot_mb)" "2 1 1 1 8000" "D4: a chamada sem resultado = 1 reinício pedido; devolveu 9000-1000 = 8000 MB (1ª leitura DEPOIS da chamada); a que adiou (rc 10) não conta"
# gate-fix 1: reinício pedido e o log acaba (o mini não voltou): NÃO há leitura depois, então não há número — o texto nunca imprime "+0 MB" (o JSON já contava em unknown_mb)
{ RD 600 1000; CALL 600 4 1000; } > "$W/t3.log"; rep --log "$W/t3.log"; R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/t3.log")
eq "$(jg rungs.D4.reboots_inferred rungs.D4.boot_unread rungs.D4.unknown_mb)" "1 1 1" "D4 sem nenhuma leitura depois do pedido: 1 reinício, 1 sem leitura depois"
case "$R_TEXT" in *"+0 MB"*) nope "D4 sem leitura depois: o texto imprimiu '+0 MB' (desconhecido virou número)" ;; *"1ª leitura depois: sem leitura depois"*) ok "D4 sem leitura depois: o texto diz 'sem leitura depois', nunca '+0 MB'" ;; *) nope "D4 sem leitura depois: texto sem a frase: $R_TEXT" ;; esac
{ RD 600 1000; CALL 600 4 1000; HB 610 9000; RD 800 1000; CALL 800 4 1000; } > "$W/t4.log"; R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/t4.log")
case "$R_TEXT" in *"1ª leitura depois: +8000 MB (+1 sem leitura depois)"*) ok "2 reinícios, um sem leitura depois: o número do que tem leitura e a contagem do que não tem" ;; *) nope "2 reinícios (um sem leitura): texto errado: $R_TEXT" ;; esac

section "aceite da missão: janela > 60 min com disco < 3 GB"
{ LOWS 600 670 2500; CALL 620 2 2500; OUTL 620 2 10 idle 2500 2500; } > "$W/w1.log"; eq "$(verd "$W/w1.log")" "0 ATENDIDO OK_ADIADA" "70 min baixos com UMA chamada que adiou: ATENDIDO, janela OK_ADIADA (a escada tentou)"
{ LOWS 600 670 2500; CALL 620 2 2500; OUTL 620 2 0 acted 2500 2600; } > "$W/w2.log"; eq "$(verd "$W/w2.log")" "0 ATENDIDO OK" "70 min baixos com um degrau que agiu: OK"
LOWS 600 670 2500 > "$W/w3.log"; eq "$(verd "$W/w3.log")" "1 NAO_ATENDIDO VIOLACAO" "70 min baixos SEM nenhuma ação: NÃO ATENDIDO (rc 1)"
{ LOWS 600 650 2500; RD 655 9000; } > "$W/w4.log"; eq "$(verd "$W/w4.log")" "0 ATENDIDO OK" "50 min baixos sem ação e depois uma leitura boa: ainda dentro do prazo"
{ RD 600 2500; RD 660 2500; RD 665 9000; } > "$W/w5.log"; eq "$(verd "$W/w5.log")" "0 ATENDIDO OK" "60 min exatos NÃO é > 60"
{ RD 600 2500; RD 661 2500; } > "$W/w6.log"; eq "$(verd "$W/w6.log")" "1 NAO_ATENDIDO VIOLACAO" "61 min: a lacuna ENTRE duas leituras baixas une a janela (sem leitura não se sabe que recuperou)"
{ RD 600 2500; HB 690 9000; } > "$W/w7.log"; eq "$(verd "$W/w7.log")" "1 NAO_VERIFICADO NAO_VERIFICADO" "leitura baixa e 90 min de silêncio até uma leitura boa: fim INCERTO → NÃO VERIFICADO, nunca ATENDIDO"
{ LOWS 600 670 2500; CALL 674 4 2500; } > "$W/w8.log"; eq "$(verd "$W/w8.log")" "0 ATENDIDO OK" "ação 4 min depois da última leitura baixa (D4 escrito na mesma rodada) vale"
{ LOWS 600 670 2500; CALL 676 4 2500; } > "$W/w9.log"; eq "$(verd "$W/w9.log")" "1 NAO_ATENDIDO VIOLACAO" "ação 6 min depois (> 300 s de graça) NÃO vale"
# as bordas da conta, ao segundo (o maestro escreve a chamada do degrau na MESMA rodada da leitura): fechadas nas duas pontas da janela e da graça, lacuna só ACIMA de 600 s
{ RD 600 2500; CALL 600 2 2500; OUTL 600 2 0 acted 2500 2600; LOWS 605 670 2500; RD 675 9000; } > "$W/g1.log"; eq "$(verd "$W/g1.log")" "0 ATENDIDO OK" "chamada escrita no MESMO segundo da 1ª leitura baixa conta (70 min baixos, um degrau que agiu): a borda de baixo da janela é fechada"
{ LOWS 600 670 2500; CALL 675 4 2500; RD 680 9000; } > "$W/g2.log"; eq "$(verd "$W/g2.log")" "0 ATENDIDO OK" "ação EXATAMENTE 300 s depois da última leitura baixa conta (a de 360 s não, w9): a borda da graça é fechada"
{ RD 10:00:00 2500; RD 10:51:00 2500; RD 11:01:00 9000; } > "$W/b1.log"; eq "$(verd "$W/b1.log")" "0 ATENDIDO OK" "leitura baixa e EXATOS 600 s de silêncio até a boa: não é lacuna (> 600 s), o fim é certo e a janela de 51 min está no prazo"
{ RD 10:00:00 2500; RD 10:51:00 2500; RD 11:01:01 9000; } > "$W/b2.log"; eq "$(verd "$W/b2.log")" "1 NAO_VERIFICADO NAO_VERIFICADO" "601 s de silêncio até a leitura boa já é lacuna: pior caso 51 min + 601 s > 60 min = NÃO VERIFICADO"
{ RD 600 2500; RD 605 2500; RD 610 2500; RD 615 9000; HB 660 9000; RD 700 2500; RD 705 9000; } > "$W/n1.log"; rep --log "$W/n1.log"
eq "$(jg 'windows[].readings' 'windows[].minutes' 'windows[].worst_minutes')" "3,1 10,0 10,0" "cada janela conta as leituras baixas dela: 3 (10 min) e 1 (0 min, uma leitura só); o pior caso de ambas é a própria janela"
{ RD 10:00:00 2500; RD 10:00:59 2500; RD 09:00:00 2500; RD 09:00:59 2500; } > "$W/o1.log"; rep --log "$W/o1.log"
eq "$(jg 'windows[].minutes' 'windows[].worst_minutes' 'windows[].open')" "0,0 0,0 True,True" "janela em aberto (relógio para trás; log acabou): o pior caso é a própria janela, 59 s = 0 min, sem silêncio inventado"
{ LOWS 600 610 2500; LOWS 540 550 2500; } > "$W/w10.log"; rep --log "$W/w10.log"; eq "$(jg 'windows[].minutes')" "10,10" "relógio que andou para trás: duas janelas, nunca uma só"
{ HB 540 9000; HB 600 9000; } > "$W/w11.log"; rep --log "$W/w11.log"; eq "$(jg acceptance exercised)" "ATENDIDO False" "disco sempre bom e nenhum degrau: ATENDIDO por vacuidade, e o relatório diz que NÃO exercitou a escada"

{ RD 600 3072; RD 700 3072; } > "$W/w12.log"; rep --log "$W/w12.log"; eq "$(jg 'windows[].minutes')" "" "livre de exatamente 3072 MB NÃO é < 3 GB: sem janela"
{ RD 600 3071; RD 700 3071; } > "$W/w13.log"; eq "$(verd "$W/w13.log")" "1 NAO_ATENDIDO VIOLACAO" "livre de 3071 MB já é < 3 GB: 100 min sem ação = NÃO ATENDIDO"
# gate-fix 1: o log TERMINA numa leitura baixa (ou o relógio anda para trás): o fim da janela é desconhecido, então sem nenhuma ação da escada é NÃO VERIFICADO, nunca "tudo bem até agora"
LOWS 600 630 2500 > "$W/e1.log"; rep --log "$W/e1.log"; R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/e1.log")
eq "$RC $(jg acceptance 'windows[].verdict' 'windows[].open')" "1 NAO_VERIFICADO NAO_VERIFICADO True" "30 min baixos e o log acaba, sem ação: janela em aberto = NÃO VERIFICADO (não ATENDIDO), marcada open"
case "$R_TEXT" in *"[NAO_VERIFICADO, em aberto no fim do log]"*) ok "…e o texto diz 'em aberto no fim do log'" ;; *) nope "texto da janela em aberto: $R_TEXT" ;; esac
{ LOWS 600 630 2500; CALL 620 2 2500; OUTL 620 2 0 acted 2500 2600; } > "$W/e2.log"; eq "$(verd "$W/e2.log")" "0 ATENDIDO OK" "…com um degrau que agiu na janela: OK mesmo em aberto"
{ LOWS 600 610 2500; LOWS 540 550 2500; } > "$W/e3.log"; eq "$(verd "$W/e3.log")" "1 NAO_VERIFICADO NAO_VERIFICADO,NAO_VERIFICADO" "relógio para trás no meio de uma janela baixa: a continuidade quebra, as duas ficam em aberto"
# gate-fix 1: o rótulo OK_ADIADA é só para quem adiou (rc 10); chamada que falhou (20), não leu (30) ou morreu sem resultado é OK_TENTOU
{ LOWS 600 670 2500; CALL 620 2 2500; OUTL 620 2 20 failed 2500 2500; RD 675 9000; } > "$W/w14.log"; eq "$(verd "$W/w14.log")" "0 ATENDIDO OK_TENTOU" "70 min baixos com UMA chamada que falhou (rc 20): OK_TENTOU, não OK_ADIADA"
{ LOWS 600 670 2500; CALL 620 3 2500; OUTL 620 3 10 idle 2500 2500; CALL 630 2 2500; OUTL 630 2 30 unknown 2500 2500; RD 675 9000; } > "$W/w15.log"; eq "$(verd "$W/w15.log")" "0 ATENDIDO OK_TENTOU" "adiou (D3) e não leu (D2): OK_TENTOU (qualquer não-adiar vence)"

section "cobertura, silêncio, --since e log rotacionado"
{ HB 600 9000; HB 660 9000; HB 720 9000; } > "$W/c0.log"
"$PY" -I "$REPORT" --min-hours 24 --log "$W/c0.log" > /dev/null; eq "$?" 1 "2 h de log com --min-hours 24: rc 1 (canário incompleto) mesmo com o aceite ATENDIDO"
"$PY" -I "$REPORT" --min-hours 2 --log "$W/c0.log" > /dev/null; eq "$?" 0 "2 h de batimentos de hora em hora com --min-hours 2: rc 0"
# gate-fix 1: silêncio ENTRE duas leituras boas não é "sem problema": sem leitura não se sabe que o disco ficou bom. 28 h de buraco com --min-hours 24 NÃO pode sair rc 0 / ATENDIDO
{ HB 600 9000; HB 720 9000; } > "$W/c1.log"; rep --log "$W/c1.log"; R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/c1.log")
eq "$RC $(jg acceptance silences_over_65min[].min max_silence_min unverified_why[])" "1 NAO_VERIFICADO 120 120 1 silêncio(s) > 65 min" "120 min sem nenhuma linha entre duas leituras boas: apontado e NÃO VERIFICADO (rc 1), com o motivo"
case "$R_TEXT" in *"disk-recovery.off"*"ACEITE"*"NAO VERIFICADO"*"silêncio(s) > 65 min"*) ok "o texto não promete 1 linha por hora sem condição (job rodando e interruptor desligado) e o ACEITE traz o motivo" ;; *) nope "texto do silêncio/aceite: $R_TEXT" ;; esac
{ HB 600 9000; HB 665 9000; } > "$W/c3.log"; rep --log "$W/c3.log"; eq "$RC $(jg acceptance)" "0 ATENDIDO" "silêncio de exatamente 65 min NÃO é > 65"
{ HB 600 9000; HB 666 9000; } > "$W/c4.log"; rep --log "$W/c4.log"; eq "$RC $(jg acceptance)" "1 NAO_VERIFICADO" "66 min já é silêncio"
printf '%s\n' "[2026-11-02 00:30:00] ok: livre=9000MB swap=0MB (sem episódio; batimento 1/h)" "[2026-11-03 04:30:00] ok: livre=9000MB swap=0MB (sem episódio; batimento 1/h)" > "$W/c2.log"
rep --log "$W/c2.log" --min-hours 24; eq "$RC $(jg hours acceptance)" "1 28.0 NAO_VERIFICADO" "duas leituras boas com 28 h de silêncio, --min-hours 24: cobertura 28 h mas NÃO VERIFICADO, rc 1 (era rc 0 / ATENDIDO)"
{ LOWS 600 670 2500; HB 780 9000; } > "$W/s1.log"
rep --log "$W/s1.log" --since '2026-11-02 12:00'; eq "$(jg acceptance readings)" "ATENDIDO 1" "--since corta o que veio antes (a janela ruim fica fora do período)"
{ HB 540 9000; HB 600 9000; HB 660 9000; } > "$W/s2.log"
rep --log "$W/s2.log" --since '2026-11-02 10:00' --until '2026-11-02 11:00'; eq "$(jg readings events)" "2 2" "--since e --until são fechados nas duas pontas: a linha carimbada EXATAMENTE em cada um entra (10:00 e 11:00), a das 09:00 não"
LOWS 600 640 2500 > "$W/r.log.1"; { LOWS 645 670 2500; CALL 660 2 2500; OUTL 660 2 10 idle 2500 2500; } > "$W/r.log"
rep --log "$W/r.log.1" --log "$W/r.log"; eq "$(jg readings 'windows[].minutes' 'windows[].verdict')" "15 70 OK_ADIADA" "log rotacionado (.1 + atual): uma janela de 70 min atravessa a rotação"

section "terceiro estado do arquivo: ausente / sem permissão / diretório / vazio / lixo"
rep --log "$W/nao-existe.log"; case "$(cat "$W/err")" in *"não consegui ler"*"nao-existe.log"*) E=1 ;; *) E=0 ;; esac; eq "$RC $E ${#OUT}" "3 1 0" "log ausente: rc 3, a causa no stderr e NENHUM relatório no stdout"
: > "$W/semperm.log"; chmod 000 "$W/semperm.log"
if [ "$(id -u)" = 0 ]; then ok "log sem permissão (pulado: root lê tudo)"; else rep --log "$W/semperm.log"; eq "$RC ${#OUT}" "3 0" "log sem permissão de leitura: rc 3, nenhum relatório"; fi
mkdir -p "$W/dir.log"; rep --log "$W/dir.log"; eq "$RC ${#OUT}" "3 0" "o caminho é um diretório: rc 3, nenhum relatório"
{ LOWS 600 610 2500; } > "$W/ok1.log"; rep --log "$W/ok1.log" --log "$W/nao-existe.log"; eq "$RC ${#OUT}" "3 0" "UM dos logs pedidos ilegível: rc 3 (o outro não vale sozinho)"
: > "$W/vazio.log"; rep --log "$W/vazio.log"; eq "$RC $(jg acceptance readings events)" "1 NAO_VERIFICADO 0 0" "log vazio: relatório sem leituras, NÃO VERIFICADO, rc 1 (a escada não escreveu nada)"
R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/vazio.log"); case "$R_TEXT" in *"Cobertura:"*) nope "log vazio em texto: imprimiu uma cobertura que não existe: $R_TEXT" ;; *"SEM LEITURAS no período: a escada não escreveu nenhuma leitura"*) ok "log vazio em texto: diz SEM LEITURAS, sem linha de cobertura" ;; *) nope "log vazio em texto: sem a frase SEM LEITURAS: $R_TEXT" ;; esac
{ printf 'lixo A antes de tudo\n'; HB 540 9000; printf 'lixo B\n'; HB 600 9000; printf 'lixo C\n'; HB 660 9000; printf 'lixo D no fim\n'; } > "$W/u1.log"
rep --log "$W/u1.log"; A=$(jg lines_unstamped); rep --log "$W/u1.log" --since '2026-11-02 10:00' --until '2026-11-02 10:30'
eq "$A $(jg lines_unstamped readings)" "4 1 1" "linha sem carimbo vale pela hora da linha de cima: sem período 4; com --since/--until só a que cai dentro (1), não o arquivo inteiro"
{ printf 'lixo sem carimbo\n'; printf '\200\201\202 bytes inválidos\n'; printf '[2026-13-45 99:99:99] mês 13 não é data\n'; HB 600 9000; printf 'cortada no meio [2026-11-02 10:05'; } > "$W/lixo.log"
rep --log "$W/lixo.log"; eq "$RC $(jg lines_unstamped readings)" "0 4 1" "lixo (sem carimbo, bytes inválidos, data impossível, linha cortada): contado à parte, a leitura boa continua valendo, nada quebra"
"$PY" -I "$REPORT" --since 'ontem' --log "$W/ok1.log" > /dev/null 2>&1; eq "$?" 2 "--since que não é data: rc 2 (uso)"
"$PY" -I "$REPORT" --help > "$W/help.out" 2>&1; RC=$?; eq "$RC $(head -c 6 "$W/help.out")" "0 usage:" "--help: rc 0 e o uso no stdout (pedir a ajuda não é uso errado nem relatório vermelho)"
mkdir -p "$W/city/.gc/logs"; LOWS 600 610 2500 > "$W/city/.gc/logs/disk-recovery.log.1"; LOWS 615 620 2500 > "$W/city/.gc/logs/disk-recovery.log"
OUT=$(GC_CITY_PATH="$W/city" "$PY" -I "$REPORT" --min-hours 0 --json 2>/dev/null); eq "$(jg readings)" "5" "sem --log: lê GC_CITY_PATH/.gc/logs/disk-recovery.log e o .1"
mkdir -p "$W/city2"; GC_CITY_PATH="$W/city2" "$PY" -I "$REPORT" > /dev/null 2>&1; eq "$?" 3 "sem --log e sem o log da cidade: rc 3, não 'sem eventos'"

section "bordas ao segundo, campos do JSON e linhas do texto (lastro hq-mutants, ga-pfnzwda)"
# silêncio: 3900 s não é > 3900 (c3), 3901 s é; a graça de 300 s conta (g2), 301 s não; e um relógio que repete o segundo (gap 0) NÃO anda para trás
{ HB 10:00:00 9000; HB 11:05:01 9000; } > "$W/x1.log"; rep --log "$W/x1.log"; eq "$RC $(jg acceptance)" "1 NAO_VERIFICADO" "silêncio de 3901 s (1 s além dos 65 min) já é silêncio"
{ LOWS 600 670 2500; CALL 11:15:01 2 2500; RD 680 9000; } > "$W/x2.log"; eq "$(verd "$W/x2.log")" "1 NAO_ATENDIDO VIOLACAO" "ação 301 s depois da última leitura baixa NÃO vale (a de 300 s vale, g2): a graça padrão é de 300 s"
{ RD 600 2500; RD 600 2500; RD 610 9000; } > "$W/x3.log"; rep --log "$W/x3.log"
eq "$(jg 'windows[].readings' 'windows[].open')" "2 False" "duas leituras baixas no MESMO segundo: uma janela só (gap 0 não é carimbo para trás), fechada pela leitura boa"
# o que conta como ação: só o D4 que reinicia vale SEM linha de resultado; um D4 que adiou (rc 10) não agiu
{ LOWS 600 670 2500; CALL 620 2 2500; RD 675 9000; } > "$W/x4.log"; rep --log "$W/x4.log"
eq "$(jg 'windows[].acted' 'windows[].verdict')" "0 OK_TENTOU" "um D2 que ficou sem linha de resultado NÃO é ação (agiu 0, OK_TENTOU)"
{ LOWS 600 670 2500; CALL 620 4 2500; OUTL 620 4 10 idle 2500 2500; RD 675 9000; } > "$W/x5.log"; rep --log "$W/x5.log"
eq "$(jg 'windows[].acted' 'windows[].verdict')" "0 OK_ADIADA" "um D4 que adiou (rc 10) NÃO agiu: agiu 0, OK_ADIADA"
# o JSON como dado: chaves em ordem e recuo de 1 (comparável com diff entre dois dias), e os campos nas pontas
{ HB 600 9000; } > "$W/x6.log"; R_JSON=$("$PY" -I "$REPORT" --min-hours 0 --json --log "$W/x6.log")
eq "$(printf '%s\n' "$R_JSON" | sed -n '1,2p' | tr '\n' '|')" '{| "acceptance": "ATENDIDO",|' "o JSON sai com as chaves em ordem alfabética e recuo de 1 espaço (saída estável, comparável com diff)"
rep --log "$W/x6.log"; eq "$(jg events max_silence_min hours)" "1 0 0.0" "log de uma linha só: 1 evento, nenhum silêncio a medir (0 min) e 0.0 h"
rep --log "$W/vazio.log"; eq "$(jg hours max_silence_min)" "0 0" "log vazio: 0 h de cobertura e 0 min de silêncio (nada a medir, não 1)"
{ HB 10:00:00 9000; HB 11:00:10 9000; } > "$W/x7.log"; rep --log "$W/x7.log"; eq "$(jg hours)" "1.0" "3610 s = 1,0028 h: as horas saem com 2 casas (1.0), não 3"
{ HB 600 9000; HB 670 9000; HB 740 9000; HB 810 9000; HB 880 9000; HB 950 9000; HB 1020 9000; } > "$W/x8.log"; rep --log "$W/x8.log"
eq "$(jg 'silences_over_65min[].after' 'silences_over_65min[].min' max_silence_min)" "2026-11-02 11:10:00,2026-11-02 12:20:00,2026-11-02 13:30:00,2026-11-02 14:40:00,2026-11-02 15:50:00 70,70,70,70,70 70" "6 silêncios de 70 min: a lista traz os 5 ÚLTIMOS, cada um com a hora da linha de ANTES do buraco"
LONG=$(printf '%0100d' 0); { HB 600 9000; L 601 "WARN: $LONG"; HB 660 9000; } > "$W/x10.log"; rep --log "$W/x10.log"; A=$(jg 'alerts[]'); eq "${#A}" "90" "aviso de 106 caracteres: o relatório guarda os 90 primeiros"
# o texto da janela: sem chamada diz "nenhuma", com chamada lista os degraus
{ RD 600 2500; CALL 601 2 2500; OUTL 601 2 10 idle 2500 2500; RD 610 9000; HB 660 9000; RD 700 2500; RD 705 9000; HB 760 9000; } > "$W/x9.log"
R_TEXT=$("$PY" -I "$REPORT" --min-hours 0 --log "$W/x9.log"); case "$R_TEXT" in *"chamadas: D2  agiu: 0  [OK_ADIADA]"*"chamadas: nenhuma  agiu: 0  [OK]"*) ok "o texto de cada janela lista os degraus chamados (D2) ou diz 'nenhuma'" ;; *) nope "linhas das janelas sem 'chamadas: D2' / 'chamadas: nenhuma': $R_TEXT" ;; esac
# o aceite diz se a escada foi exercitada: disco ≤ 5120 MB (borda de cima) OU uma chamada --run; um --dry-run não conta
exer() { rep --log "$1"; jg exercised; }
{ HB 600 5120; HB 660 5120; } > "$W/q1.log"; { HB 600 5121; HB 660 5121; } > "$W/q2.log"; { HB 600 9000; CALL 601 2 9000; HB 660 9000; } > "$W/q3.log"; { HB 600 4000; HB 660 9000; } > "$W/q4.log"
{ HB 600 9000; L 601 "degrau D2: chamando /x/disk-recovery-d2.sh --dry-run (livre=9000MB swap=0MB; abaixo do limiar há 0s; leituras < 1536MB seguidas=0)"; HB 660 9000; } > "$W/q5.log"
eq "$(exer "$W/q1.log") $(exer "$W/q2.log") $(exer "$W/q3.log") $(exer "$W/q4.log") $(exer "$W/q5.log")" "True False True True False" "exercitou a escada? 5120 MB (borda) sim, 5121 não; chamada --run sem disco baixo sim; disco ≤ 5 GB sem chamada sim; só --dry-run não"
# a causa do erro de leitura é a do sistema (strerror), não o nome da exceção
rep --log "$W/nao-existe.log"; E=$(cat "$W/err"); case "$E" in *FileNotFoundError*|*None*) nope "log ausente: a mensagem traz o nome da exceção em vez da causa: $E" ;; *"nao-existe.log: "?*) ok "log ausente: a mensagem traz a causa dada pelo sistema, não o nome da exceção" ;; *) nope "log ausente: mensagem sem a causa: $E" ;; esac
rep --log "$W/dir.log"; E=$(cat "$W/err"); case "$E" in *IsADirectoryError*|*None*) nope "diretório: a mensagem traz o nome da exceção em vez da causa: $E" ;; *"dir.log: "?*) ok "o caminho é um diretório: a mensagem traz a causa dada pelo sistema, não o nome da exceção" ;; *) nope "diretório: mensagem sem a causa: $E" ;; esac

printf '\n%s passaram, %s falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
