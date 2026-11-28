#!/usr/bin/env bash
# Selftest de agent-battery-alert.py (ga-hyp55ss.4, fatia 4). E-mail, bd, ssh e cofre de mentira; nada toca a cidade, o nó, a rede nem o claude.
# A varredura roda sobre jsonl montado aqui e sobre um repositório git sintético (commits que tocam ou não a configuração de cada papel); o controle roda o driver REAL
# (agent-battery-night.py) contra um ssh de mentira que executa o comando remoto de verdade e um executor de mentira. Sai 0 = tudo passou.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${ABA_UNDER_TEST:-$HERE/agent-battery-alert.py}"
W="$(mktemp -d "${TMPDIR:-/tmp}/aba-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', veio '$2')"; fi; }
unset GC_CITY_PATH; for v in $(env | grep -E '^(ABA|ABN)_' | cut -d= -f1); do unset "$v"; done
export FAKE_LOG="$W/log" CITY="$W/repo/.city" TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
JSONL="$CITY/.gc/logs/agent-battery.jsonl"; STATE="$CITY/.gc/agent-battery/alert-state.json"; AUDIT="$CITY/.gc/logs/agent-battery-alert.jsonl"
rep() { printf "$1%.0s" $(seq "$2"); } # o caractere $1 repetido $2 vezes
AC=$(rep b 64); AC2=$(rep c 64); H1=$(rep 1 64); H2=$(rep 2 64); H3=$(rep 3 64); FAKE_REF=$(rep e 40)

# repositório sintético: a cidade é .city/; cada commit toca um conjunto diferente de caminhos (o do prompt do dog, o do reviewer, o CLAUDE.md da cidade, uma skill, um script que NÃO é configuração)
G() { git -C "$W/repo" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$W/repo/.city/agents/dog-remote" "$W/repo/.city/agents/gate-reviewer" "$W/repo/.city/agents/wa-worker" "$W/repo/.city/scripts" "$W/repo/.claude/skills"
for f in .city/agents/dog-remote/prompt.template.md .city/agents/gate-reviewer/prompt.template.md .city/agents/wa-worker/prompt.template.md .city/CLAUDE.md .city/scripts/foo.sh .claude/skills/x.md; do echo base >"$W/repo/$f"; done
G init -q -b main && echo '.gc/' >"$W/repo/.git/info/exclude" && G add -A && G commit -qm "chore: base" && R0=$(G rev-parse HEAD)
touch_commit() { echo "$2" >>"$W/repo/$1"; G add -A; G commit -qm "$3"; G rev-parse HEAD; }
R1=$(touch_commit .city/agents/dog-remote/prompt.template.md x1 "feat(ga-aaa1): prompt do dog")
R2=$(touch_commit .city/scripts/foo.sh x2 "fix(ga-bbb2): script que não é configuração")
R3=$(touch_commit .city/CLAUDE.md x3 "docs(ga-ccc3): CLAUDE.md da cidade")
R4=$(touch_commit .claude/skills/x.md x4 "chore: skill sem bead no assunto")
R5=$(touch_commit .city/agents/gate-reviewer/prompt.template.md x5 "fix(ga-ddd4.2): prompt do reviewer")
R6=$(touch_commit .city/agents/dog-remote/prompt.template.md x6 "fix(wa-eee5): prompt do dog, bead de outro rig")
R7=$(touch_commit .city/agents/dog-remote/prompt.template.md x7 "fix(ga-fff6): prompt do dog")

printf '#!/usr/bin/env bash\n[ -e "$FAKE_LOG/mail-fail" ] && exit 1\n[ -e "$FAKE_LOG/mail-fail-2nd" ] && [ -e "$FAKE_LOG/mail-subj" ] && exit 1\nprintf "%%s\\n" "$2" >>"$FAKE_LOG/mail-subj"; printf "%%s\\n" "$4" >"$FAKE_LOG/mail-body"; printf "%%s\\n----\\n" "$4" >>"$FAKE_LOG/mail-bodies"; printf "%%s\\n" "$PATH" >"$FAKE_LOG/mail-path"; [ "$1$3" = "-s-m" ] || echo "forma errada: $*" >>"$FAKE_LOG/mail-bad"\n' >"$W/fake-mail"
printf '#!/usr/bin/env bash\nif [ "$3" = comment ]; then echo "$1 $2 $3 $4" >>"$FAKE_LOG/bd"; else echo "$*" >>"$FAKE_LOG/bd"; fi\ncase "$3" in label) [ -e "$FAKE_LOG/bd-fail-label" ] && { [ ! -s "$FAKE_LOG/bd-fail-label" ] || [ "$5" = "$(cat "$FAKE_LOG/bd-fail-label")" ]; } && { echo "bd: sem rótulo" >&2; exit 1; } ;; comment) [ -e "$FAKE_LOG/bd-fail-comment" ] && exit 1; printf "%%s\\n" "$5" >>"$FAKE_LOG/bd-comments" ;; esac\nexit 0\n' >"$W/fake-bd"
chmod +x "$W/fake-mail" "$W/fake-bd"
mkdir -p "$W/bin"; printf '#!/usr/bin/env bash\necho "$*" >>"$FAKE_LOG/gc-calls"\n' >"$W/bin/gc"; chmod +x "$W/bin/gc"; export PATH="$W/bin:$PATH" # um gc de mentira: quem o chamar deixa a linha de comando
cnt() { [ -e "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0; }
mails() { cnt "$FAKE_LOG/mail-subj"; }
bds() { cnt "$FAKE_LOG/bd"; }
reset() { rm -rf "$FAKE_LOG" "$CITY"; mkdir -p "$FAKE_LOG" "$CITY/.gc/logs" "$CITY/.gc/agent-battery"; N=0; }
# L papel modo ok n [cfg] [ref] [acervo] [cat]: acrescenta uma linha de rodada ao jsonl (o ts cresce a cada chamada); "" em acervo = linha sem o campo
L() {
  N=$((N + 1)); local ts; ts=$(printf '2026-11-%02dT%02d:%02d:00Z' $((N / 1440 + 1)) $((N % 1440 / 60)) $((N % 60)))
  jq -nc --arg ts "$ts" --arg mode "$2" --arg role "$1" --argjson k "$3" --argjson n "$4" --arg cfg "${5-$H1}" --arg ref "${6-$R0}" --arg ac "${7-$AC}" --arg cat "${8-ok}" \
    '{ts:$ts, mode:$mode, dia:($ts|.[0:10]), verdict:"COMPLETO", reason:"", papeis:{($role):{cat:$cat, ok:$k, medidas:$n, taxa:(if $n == 0 then null else $k/$n end), acervo:(if $ac=="" then null else $ac end), config_sha:$cfg, config_ref_sha:$ref}}}' >>"$JSONL"
}
nights() { local c=$1; shift; local i; for i in $(seq "$c"); do L "$@"; done; } # quantas papel modo ok n ...
sw() { python3 -I "$TOOL" sweep --city "$CITY" --mail "$W/fake-mail" --bd "$W/fake-bd" "$@" >"$W/out" 2>&1; RC=$?; }
kinds() { jq -r '[.papel, .kind] | join(":")' "$AUDIT" 2>/dev/null | tr '\n' ' '; }
lastkind() { tail -n 1 "$AUDIT" | jq -r .kind; }
st() { jq -r "$1" "$STATE"; }
base() { nights 3 dog night 8 10 "$@"; sw; } # 3 noites de base do dog (80%) e a 1a varredura, que só grava a base
RAW() { jq -nc --arg ac "$AC" --arg h "$H2" --arg r "$R5" --argjson k "$1" --argjson n "$2" '{ts:"2026-12-01T00:00:00Z", mode:"night", papeis:{dog:{cat:"ok", ok:$k, medidas:$n, acervo:$ac, config_sha:$h, config_ref_sha:$r}}}' >>"$JSONL"; } # linha crua: acertos e medidas como vierem (true, 12 de 10, -1)
badstate() { echo "$RC $(mails) $(grep -c Traceback "$W/out") $(grep -c 'ilegível: nada avaliado' "$W/out")"; } # estado torto: exit 1, nada avisado, SEM traceback e com o aviso dito
pyrun() { python3 -I -c 'import importlib.util,sys,time; s = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); t0 = time.time(); r = m.run(sys.argv[2:], 1); print(r[0], round(time.time() - t0) < 3)' "$TOOL" "$@"; }
psorte() { python3 -I -c 'import importlib.util,sys; s = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.p_sorte(int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])))' "$TOOL" "$@"; }

check "a chance de ser sorte: 0 acertos de 5 com p=0,8 = 0,2^5" "$(python3 -I -c "print(round($(psorte 0 5 0.8), 6))")" "0.00032"
check "a chance de ser sorte: 2 acertos de 5 com p=0,8 = 0,05792" "$(python3 -I -c "print(round($(psorte 2 5 0.8), 6))")" "0.05792"
check "a chance de ser sorte: p=1,0 é preso a 0,95 (4 de 5 não é raro)" "$(python3 -I -c "print(round($(psorte 4 5 1.0), 4))")" "0.2262"
check "run: prazo estourado devolve rc None (nunca 0), mata o processo e volta no prazo" "$(pyrun sleep 5)" "None True"
check "run: programa que não existe devolve rc None e sucesso devolve 0" "$(pyrun /nao/existe/x | cut -d' ' -f1) $(pyrun true | cut -d' ' -f1)" "None 0"

reset; sw
check "sem jsonl: exit 0 e a base fica gravada com 0 linhas" "$RC $(st .linhas)" "0 0"
L dog night 0 10; sw
check "linha que aparece depois da 1a varredura é avaliada (sem base: não avisa)" "$RC $(mails) $(kinds)" "0 0 dog:sem_base "
reset; nights 3 dog night 8 10; L dog night 0 10; sw
check "1a varredura: grava a base e NÃO avalia o histórico (nem a queda que já estava lá)" "$RC $(mails) $(st .linhas) $(cnt "$AUDIT")" "0 0 4 0"
sw; check "varredura repetida sem linha nova: nada acontece (e não diz que o jsonl encolheu)" "$RC $(mails) $(cnt "$AUDIT") $(grep -c 'menos linhas' "$W/out")" "0 0 0 0"

reset; base; L dog night 3 10 "$H2" "$R5"; sw
check "queda grande e significativa: exit 0 e UM e-mail" "$RC $(mails)" "0 1"
check "e-mail: assunto com papel, mediana e taxa" "$(head -n 1 "$FAKE_LOG/mail-subj")" "[agent-battery] QUEDA 2026-11-01 (night): dog 80%→30%"
check "e-mail: números, variação e chance de ser sorte" "$(grep -c -E 'dog: 30% \(3/10 tarefas\) contra 80% de mediana das últimas 3 noites do mesmo acervo: -50 pp; chance de ser sorte <0\.1%' "$FAKE_LOG/mail-body")" 1
check "e-mail: -s e -m na forma do gc mail send" "$(ls "$FAKE_LOG" | grep -c mail-bad)" 0
check "o PATH do launchd é completado (homebrew e /usr/local na frente) para gc, bd e git" "$(cut -d: -f1,2 "$FAKE_LOG/mail-path")" "/opt/homebrew/bin:/usr/local/bin"
reset; base; L dog night 0 10 "$H2" "$R5"; python3 -I "$TOOL" sweep --city "$CITY" --bd "$W/fake-bd" >"$W/out" 2>&1
check "sem --mail: o aviso sai por gc --city <cidade> mail send mayor -s ... -m ..." "$(cut -d' ' -f1-6 "$FAKE_LOG/gc-calls" | head -n 1)" "--city $CITY mail send mayor -s"
reset; base; L dog night 3 10 "$H2" "$R5"; sw
check "o log de decisões traz o veredito, a base e as noites" "$(tail -n 1 "$AUDIT" | jq -r '[.papel, .kind, .taxa, .base, .noites, .queda] | map(tostring) | join(" ")')" "dog queda 0.3 0.8 3 0.5"
check "o estado guarda a queda do papel com o sha da configuração" "$(st '.papeis.dog | [.alerta, (.sha | .[0:4])] | map(tostring) | join(" ")') $(st .linhas)" "true 2222 4"
sw; check "varredura repetida: não repete o e-mail" "$(mails) $(bds)" "1 4"

reset; base; L dog night 6 10 "$H2" "$R5"; sw
check "queda do tamanho do limiar (20 pp, igual) mas que cabe na sorte: ruído, sem e-mail" "$(mails) $(lastkind)" "0 ruido"
reset; base; L dog night 12 20 "$H2" "$R5"; sw
check "fronteira: exatamente o limiar com significância: avisa" "$(mails) $(lastkind)" "1 queda"
check "a chance de ser sorte sai com uma casa quando passa de 0,1% (12 de 20 contra 80% = 3,2%)" "$(grep -c 'chance de ser sorte 3\.2%' "$FAKE_LOG/mail-body")" 1
reset; base; L dog night 13 20 "$H2" "$R5"; sw
check "um pouco abaixo do limiar: ok, sem e-mail" "$(mails) $(lastkind)" "0 ok"
reset; base; L dog night 6 10 "$H2" "$R5"; sw --alfa "$(psorte 6 10 0.8)"
check "fronteira da significância: p igual ao alfa avisa" "$(mails) $(lastkind)" "1 queda"
reset; base; L dog night 6 10 "$H2" "$R5"; sw --limiar 0.21
check "--limiar acima da queda: ok" "$(mails) $(lastkind)" "0 ok"
reset; base; L dog night 6 10 "$H2" "$R5"; ABA_ALFA=0.5 sw
check "a opção também vem de ABA_<NOME>" "$(mails) $(lastkind)" "1 queda"
reset; nights 3 dog night 5 5; sw; L dog night 4 5 "$H2" "$R5"; sw
check "base de 100%: 4 de 5 é ruído (a mediana presa a 95% evita p=0)" "$(mails) $(lastkind)" "0 ruido"
reset; base; L dog night 0 5 "$H2" "$R5"; sw
check "amostra pequena mas colapso total (0 de 5): avisa" "$(mails) $(lastkind)" "1 queda"
reset; base; L dog night 9 10 "$H2" "$R5"; sw
check "taxa maior que a base: ok" "$(mails) $(lastkind)" "0 ok"

reset; nights 2 dog night 8 10; sw; L dog night 0 10; sw
check "só 2 noites de base: sem base, não avisa" "$(mails) $(lastkind)" "0 sem_base"
reset; nights 2 dog night 8 10; sw; L dog night 0 10; sw --min-noites 2
check "--min-noites 2: 2 noites bastam" "$(mails) $(lastkind)" "1 queda"
reset; nights 3 dog night 8 10 "$H1" "$R0" "$AC2"; sw; L dog night 0 10; sw
check "noites de OUTRO acervo não entram na base" "$(mails) $(lastkind)" "0 sem_base"
reset; nights 2 dog night 8 10 "$H1" "$R0" "$AC2"; nights 2 dog night 8 10; sw; L dog night 0 10; sw
check "2 noites do mesmo acervo + 2 de outro: 2 de base, sem base" "$(lastkind)" "sem_base"
reset; nights 3 dog night 8 10 "$H1" "$R0" ""; sw; L dog night 0 10; sw
check "noites de formato antigo (sem acervo) não são base" "$(mails) $(lastkind)" "0 sem_base"
reset; base; L dog night 0 10 "$H2" "$R5" ""; sw
check "linha sem acervo não se compara: sem_acervo, não avisa" "$(mails) $(lastkind)" "0 sem_acervo"
reset; nights 3 dog merge 8 10; sw; L dog night 0 10; sw
check "medida de merge não entra na base da noite" "$(mails) $(lastkind)" "0 sem_base"
reset; nights 2 dog night 8 10; L dog night 8 10 "$H1" "$R0" "$AC" falhou; sw; L dog night 0 10; sw
check "noite do papel que FALHOU (poucas medidas) não é base" "$(lastkind)" "sem_base"
reset; base; L dog night 0 10 "$H2" "$R5" "$AC" falhou; sw
check "papel que não foi medido (cat falhou): nada é avaliado, nem a taxa que ele traz, e nenhum log de decisões vazio nasce" "$(mails) $([ -e "$AUDIT" ] && echo log || echo sem-log)" "0 sem-log"
reset; base; RAW true 10; sw
check "acertos booleanos (true) não são uma contagem: nada é avaliado" "$(mails) $([ -e "$AUDIT" ] && echo log || echo sem-log)" "0 sem-log"
reset; base; RAW 12 10; RAW -1 10; sw
check "acertos maiores que as medidas (12 de 10) ou negativos não são medida: nada é avaliado" "$(mails) $([ -e "$AUDIT" ] && echo log || echo sem-log)" "0 sem-log"
reset; base; L dog night 0 10 "$H2" "$R5" xyz; sw
check "acervo que não é um sha256: sem_acervo (não compara strings quaisquer)" "$(mails) $(lastkind)" "0 sem_acervo"
reset; base; L dog night 0 0 "$H2" "$R5"; sw
check "medidas 0 não é taxa 0 (e não divide por zero): nada é avaliado" "$RC $(mails) $(cnt "$AUDIT")" "0 0 0"
reset; nights 4 dog night 9 10; nights 3 dog night 5 10; sw; L dog night 5 10; sw
check "só as últimas --janela noites contam: a mediana das 5 últimas (50%) não vê queda onde a das 7 (90%) veria" "$(mails) $(lastkind)" "0 ok"
reset; nights 4 dog night 9 10; nights 3 dog night 5 10; sw; L dog night 5 10; sw --janela 7
check "controle da janela: o MESMO jsonl com --janela 7 avisa" "$(mails) $(lastkind)" "1 queda"
reset; nights 3 dog night 6 10; sw; L dog night 4 10 "$H2" "$R5"; sw --alfa 0.2
check "fronteira em ponto flutuante: 60% → 40% é exatamente 20 pp (0,6-0,4 dá 0,19999…): a queda é arredondada antes de comparar" "$(mails) $(lastkind)" "1 queda"
reset; nights 1 dog night 6 10; nights 2 dog night 8 10; sw; L dog night 12 20 "$H2" "$R5"; sw
check "é a MEDIANA, não a média (60%, 80%, 80% → 80%, e a média daria 73%)" "$(lastkind) $(tail -n 1 "$AUDIT" | jq -r .base)" "queda 0.8"
reset; nights 2 dog night 6 8; nights 2 dog night 2 8; sw; L dog night 0 8; sw --janela 4 --min-noites 4
check "mediana de número par de noites é a média das duas do meio (75% e 25% dão 50%)" "$(tail -n 1 "$AUDIT" | jq -r '.base')" "0.5"
reset; nights 3 dog night 8 10; L dog merge 0 10 "$H2" "$R5"; sw; L dog merge 0 10 "$H3" "$R5"; sw
check "linha de MERGE é avaliada contra a base das noites e avisa" "$(mails) $(lastkind)" "1 queda"

reset; base; L dog night 0 10 "$H2" "$R5"; sw; L dog night 0 10 "$H2" "$R5"; sw
check "mesma configuração ainda baixa na noite seguinte: persistente, sem 2o e-mail" "$(mails) $(lastkind)" "1 persistente"
L dog night 0 10 "$H3" "$R5"; sw
check "outra configuração, também baixa: avisa de novo" "$(mails) $(lastkind)" "2 queda"
reset; nights 5 dog night 8 10; sw; L dog night 0 10 "$H2" "$R5"; sw; L dog night 8 10 "$H2" "$R5"; sw
check "taxa recuperada: o estado volta a 'sem alerta'" "$(mails) $(st '.papeis.dog.alerta')" "1 false"
L dog night 0 10 "$H2" "$R5"; sw
check "depois de recuperar, a MESMA configuração que já avisou avisa de novo" "$(mails) $(lastkind)" "2 queda"
reset; nights 3 dog night 8 10; nights 3 dog night 0 10; sw; L dog night 0 10 "$H2" "$R5"; sw
check "limite que fica: depois de 3 noites baixas a mediana anda e a queda deixa de ser vista (ok, não avisa)" "$(mails) $(lastkind)" "0 ok"
reset; base; L dog night 0 10 "$H2" "$R5"; sw; L dog night 6 10 "$H2" "$R5"; sw; L dog night 0 10 "$H2" "$R5"; sw
check "uma noite 'ruído' (6 de 10: 20 pp mas cabe na sorte) no meio de uma queda não conta como recuperação: a seguinte é persistente" "$(mails) $(kinds)" "1 dog:queda dog:ruido dog:persistente "

# o merge causador: o dog tinha a configuração H1 no commit R0 e agora H2 em R5; só os commits que tocam a configuração DO DOG entram
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; sw
check "merge causador: marca as 2 beads cujos commits tocam a configuração do dog (prompt do dog e CLAUDE.md da cidade)" "$(grep -c -E '^-C '"$CITY"' label add ga-(aaa1|ccc3) audit:bateria-queda$' "$FAKE_LOG/bd") $(grep -c ' comment ' "$FAKE_LOG/bd") $(bds)" "2 2 4"
check "merge causador: o script que não é configuração e o prompt do reviewer ficam de fora" "$(grep -c -E 'ga-bbb2|ga-ddd4' "$FAKE_LOG/bd") $(grep -c -E 'ga-bbb2|ga-ddd4' "$FAKE_LOG/mail-body")" "0 0"
check "merge causador: o e-mail lista os commits e diz que o commit sem bead do HQ não foi marcado" "$(grep -c -E '^    - [0-9a-f]{12} (ga-aaa1|ga-ccc3|\(sem bead do HQ no assunto\)): ' "$FAKE_LOG/mail-body")" 3
check "merge causador: o e-mail diz as marcas que VAI pôr (nunca que já pôs: o bd ainda não respondeu) e como ver e tirar" "$(grep -c 'Marcas a pôr logo depois deste e-mail (rótulo audit:bateria-queda .*): ga-aaa1, ga-ccc3\.' "$FAKE_LOG/mail-body") $(grep -c 'Marquei' "$FAKE_LOG/mail-body") $(grep -c 'bd list --label audit:bateria-queda --limit 0' "$FAKE_LOG/mail-body")" "1 0 1"
check "merge causador: o comentário traz os números e a medição" "$(grep -c 'dog: 0% (0/10 tarefas) contra 80%' "$FAKE_LOG/bd-comments")" 2
check "merge causador: o comentário diz de qual medição vem e como tirar a marca" "$(grep -c '(medição 2026-11-01T00:04:00Z)' "$FAKE_LOG/bd-comments") $(grep -c 'bd label remove ga-aaa1 audit:bateria-queda' "$FAKE_LOG/bd-comments")" "2 1"
check "merge causador: o e-mail traz os 12 primeiros caracteres do sha de configuração e do commit medido, e a noite da base de onde a configuração mudou" "$(grep -c "configuração ${H2:0:12} (commit medido ${R5:0:12}): mudou desde a noite de 2026-11-01T00:03:00Z da linha de base" "$FAKE_LOG/mail-body")" 1
check "merge causador: o log de decisões diz quais beads foram marcadas" "$(tail -n 1 "$AUDIT" | jq -r '.marcadas | join(",")')" "ga-aaa1,ga-ccc3"
reset; base "$H1" "$R1"; L dog night 0 10 "$H2" "$R2"; sw
check "só um commit que NÃO é configuração no intervalo: o aviso sai, ninguém é marcado, e o motivo é dito" "$(mails) $(bds) $(grep -c 'nenhum commit entre' "$FAKE_LOG/mail-body")" "1 0 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; sw --max-marcar 2
check "exatamente --max-marcar candidatas: marca as duas" "$(mails) $(bds)" "1 4"
reset; nights 2 dog night 8 10 "$H1" "$R0"; L dog night 8 10 "$H1" "$R1"; sw; L dog night 0 10 "$H2" "$R5"; sw
check "a noite da base com outra configuração é a ÚLTIMA (não a primeira): só os commits depois dela entram" "$(grep -c 'label add ga-aaa1' "$FAKE_LOG/bd") $(grep -c 'label add ga-ccc3' "$FAKE_LOG/bd")" "0 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; sw --max-marcar 1
check "mais beads candidatas que --max-marcar: o aviso sai e NINGUÉM é marcado" "$(mails) $(bds) $(grep -c 'são 2 beads candidatas (máximo 1)' "$FAKE_LOG/mail-body")" "1 0 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H1" "$R5"; sw
check "a linha de base inteira já tinha a configuração de agora: nenhum merge explica a queda, nada é marcado e o aviso diz isso, com quantas noites" "$(mails) $(bds) $(grep -c 'a configuração do papel é a mesma de toda a linha de base (3 noites)' "$FAKE_LOG/mail-body")" "1 0 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$(rep f 40)"; sw
check "commit medido que o clone não tem: aviso sem marca, com o 'não sei' dito (não 'nenhum commit')" "$RC $(mails) $(bds) $(grep -c 'não consegui listar os commits' "$FAKE_LOG/mail-body")" "0 1 0 1"
reset; base "$H1" "x"; L dog night 0 10 "$H2" "$R5"; sw
check "noite da base com outra configuração mas sem commit legível: sem marca, e o aviso diz que NÃO SABE desde quando (e de que noite)" "$(mails) $(bds) $(grep -c 'não sei desde quando a configuração mudou: a noite de 2026-11-01T00:03:00Z da linha de base' "$FAKE_LOG/mail-body")" "1 0 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "x"; sw
check "linha sem o commit medido: sem marca" "$(mails) $(bds) $(grep -c 'não traz o sha' "$FAKE_LOG/mail-body")" "1 0 1"
reset; base "$H1" "$R0"; L dog merge 0 10 "$H2" "$R1"; sw
check "a linha que cai pode ser de merge (não só de noite): o merge medido logo após o commit aponta só o commit do dog" "$(grep -c 'label add ga-aaa1 ' "$FAKE_LOG/bd") $(grep -c 'label add ga-ccc3' "$FAKE_LOG/bd")" "1 0"
# a janela do merge causador nasce na LINHA DE BASE (as noites da mediana), não na medição anterior: o merge que ficou em ruído (6 de 10: p=0,12) já era da configuração nova (gate-fix 1)
reset; base "$H1" "$R0"; L dog merge 6 10 "$H2" "$R5"; sw; L dog night 4 10 "$H2" "$R5"; sw
check "merge em ruído e depois a queda da noite, com a MESMA configuração nova: ruído e queda, UM aviso" "$(mails) $(kinds)" "1 dog:ruido dog:queda "
check "...a janela parte da linha de base: marca as 2 beads do dog, não diz que a configuração não mudou e diz de que noite da base ela mudou" "$(grep -c -E '^-C '"$CITY"' label add ga-(aaa1|ccc3) audit:bateria-queda$' "$FAKE_LOG/bd") $(grep -c -E 'não mudou|a mesma de toda' "$FAKE_LOG/mail-body") $(grep -c 'mudou desde a noite de 2026-11-01T00:03:00Z da linha de base' "$FAKE_LOG/mail-body")" "2 0 1"
reset; base "$H1" "$R0"; L dog merge 6 10 "$H3" "$R1"; sw; L dog merge 6 10 "$H2" "$R3"; sw; L dog night 4 10 "$H2" "$R5"; sw
check "dois merges em ruído com configurações DIFERENTES no meio: a janela vai até a noite da base e aponta os dois commits (não só os depois do último merge de outra configuração)" "$(kinds) $(grep -c 'label add ga-aaa1 ' "$FAKE_LOG/bd") $(grep -c 'label add ga-ccc3 ' "$FAKE_LOG/bd")" "dog:ruido dog:ruido dog:queda  1 1"
reset; L dog night 8 10 "$H3" "$R0"; nights 3 dog night 8 10 "$H1" "$R1"; sw --janela 3; L dog night 0 10 "$H1" "$R5"; sw --janela 3
check "outra configuração só numa noite ANTERIOR à linha de base (fora da janela de 3): nenhum merge explica a queda, ninguém é marcado e o aviso diz 'a mesma de toda a linha de base'" "$(lastkind) $(mails) $(bds) $(grep -c 'a configuração do papel é a mesma de toda a linha de base (3 noites)' "$FAKE_LOG/mail-body")" "queda 1 0 1"
reset; nights 2 dog night 8 10 "$H1" "$R0"; L dog night 8 10 "" "$R0"; sw; L dog night 0 10 "$H2" "$R5"; sw
check "a noite da base mais recente SEM SHA de configuração (o commit é legível): 'não sei desde quando' (nem 'não mudou', nem a janela de uma noite mais velha), sem marca" "$(lastkind) $(mails) $(bds) $(grep -c 'não sei desde quando a configuração mudou: a noite de 2026-11-01T00:03:00Z da linha de base' "$FAKE_LOG/mail-body")" "queda 1 0 1"
# só id do HQ (ga-) vira marca: o store do HQ não acha id de outro rig (medido com bd show, não com label add), e cada marca que falha gasta o teto de --max-marcar
reset; base "$H1" "$R5"; L dog night 0 10 "$H2" "$R7"; sw --max-marcar 1
check "commit com bead de OUTRO rig no assunto (wa-): não é marcado nem conta para o teto: com --max-marcar 1 só a ga- entra" "$(grep -c 'label add' "$FAKE_LOG/bd") $(grep -c 'label add ga-fff6 ' "$FAKE_LOG/bd") $(grep -c 'wa-eee5' "$FAKE_LOG/bd")" "1 1 0"
check "...e o e-mail o lista como commit sem bead do HQ, com o assunto (que traz o id) para quem quiser marcar à mão" "$(grep -c -E '^    - [0-9a-f]{12} \(sem bead do HQ no assunto\): fix\(wa-eee5\)' "$FAKE_LOG/mail-body")" 1
reset; rm -rf "$CITY"; mkdir -p "$W/plain/.gc/logs" "$W/plain/.gc/agent-battery"; CITY0=$CITY; CITY="$W/plain"; JSONL="$CITY/.gc/logs/agent-battery.jsonl"; FAKE_LOG="$W/log"
base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; sw
check "cidade fora de um repositório git: o aviso sai sem marca e diz que não montou os caminhos" "$RC $(mails) $(bds) $(grep -c 'não consegui montar os caminhos' "$FAKE_LOG/mail-body")" "0 1 0 1"
CITY=$CITY0; JSONL="$CITY/.gc/logs/agent-battery.jsonl"
two() { # 3 noites de base dos dois papéis e, em seguida, uma linha em que os dois caem (ainda por varrer)
reset; nights 3 dog night 8 10 "$H1" "$R0"; nights 3 reviewer night 8 10 "$H1" "$R0"; sw
jq -nc --arg ac "$AC" --arg h1 "$H1" --arg h2 "$H2" --arg r0 "$R0" --arg r5 "$R5" '{ts:"2026-12-01T00:00:00Z", mode:"night", dia:"2026-12-01", papeis:{dog:{cat:"ok", ok:0, medidas:10, acervo:$ac, config_sha:$h2, config_ref_sha:$r5}, reviewer:{cat:"ok", ok:0, medidas:10, acervo:$ac, config_sha:$h2, config_ref_sha:$r5}}}' >>"$JSONL"
}
two; sw
check "dois papéis na mesma linha: UM e-mail com os dois, as beads sem repetição" "$(mails) $(grep -c '^\[agent-battery\] QUEDA .*dog 80%→0%, reviewer 80%→0%' "$FAKE_LOG/mail-subj") $(grep -c 'label add' "$FAKE_LOG/bd")" "1 1 3"
check "dois papéis: a bead que afeta os dois (CLAUDE.md) leva os dois no comentário" "$(grep -c -E '^- (dog|reviewer): 0%' "$FAKE_LOG/bd-comments")" 4
check "dois papéis: a bead com número depois do ponto (ga-ddd4.2) entra inteira" "$(grep -c 'label add ga-ddd4.2 ' "$FAKE_LOG/bd")" 1
check "dois papéis: o log divide as marcadas por papel (a do CLAUDE.md está nas duas linhas)" "$(jq -c 'select(.papel == "dog") | .marcadas' "$AUDIT") $(jq -c 'select(.papel == "reviewer") | .marcadas' "$AUDIT")" '["ga-aaa1","ga-ccc3"] ["ga-ccc3","ga-ddd4.2"]'
two; echo ga-ddd4.2 >"$FAKE_LOG/bd-fail-label"; sw
check "dois papéis e uma bead que falha (só a do reviewer): a falha só na linha do reviewer, que perde a bead dela das marcadas; a do CLAUDE.md segue nas duas" "$(jq -c 'select(.papel == "dog") | [.marcadas, .marcas_falhas]' "$AUDIT") $(jq -c 'select(.papel == "reviewer") | [.marcadas, (.marcas_falhas | keys)]' "$AUDIT")" '[["ga-aaa1","ga-ccc3"],{}] [["ga-ccc3"],["ga-ddd4.2"]]'
reset; nights 3 outro night 8 10 "$H1" "$R0"; sw; L outro night 0 10 "$H2" "$R5"; sw
check "papel que a tabela do executor não conhece: o aviso sai sem marca e sem erro" "$RC $(mails) $(bds) $(grep -c 'não consegui montar os caminhos' "$FAKE_LOG/mail-body")" "0 1 0 1"
mkdir -p "$W/lonely"; cp "$TOOL" "$W/lonely/agent-battery-alert.py"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; TOOL="$W/lonely/agent-battery-alert.py" sw
check "sem o executor ao lado (o módulo não carrega): o aviso sai sem marca e diz que não montou os caminhos" "$RC $(mails) $(bds) $(grep -c 'não consegui montar os caminhos' "$FAKE_LOG/mail-body")" "0 1 0 1"

# falhas
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; touch "$FAKE_LOG/mail-fail"; sw
check "e-mail que falha: exit 1, NADA é marcado e a linha não é dada como vista" "$RC $(bds) $(st .linhas) $(grep -c 'fica para a próxima' "$W/out")" "1 0 3 1"
rm "$FAKE_LOG/mail-fail"; sw
check "na volta seguinte o e-mail sai UMA vez e as marcas entram" "$RC $(mails) $(bds) $(st .linhas)" "0 1 4 4"
sw; check "e depois disso nada se repete" "$(mails) $(bds)" "1 4"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; touch "$FAKE_LOG/bd-fail-label"; sw
check "bd que falha no rótulo: exit 1, o comentário não é tentado e a varredura diz, por bead, que NÃO marcou e por quê" "$RC $(bds) $(grep -c 'não marquei ga-aaa1 (rótulo: bd: sem rótulo)' "$W/out") $(grep -c 'não marquei ga-ccc3 (rótulo: bd: sem rótulo)' "$W/out")" "1 2 1 1"
check "bd que falha no rótulo: o 1o e-mail só PEDE as marcas (nunca 'Marquei') e um 2o, MARCA FALHOU, diz quais não entraram" "$(mails) $(grep -c 'Marquei' "$FAKE_LOG/mail-bodies") $(sed -n 2p "$FAKE_LOG/mail-subj" | grep -c -x '\[agent-battery\] MARCA FALHOU: ga-aaa1, ga-ccc3') $(grep -c -E '^- não marquei (ga-aaa1|ga-ccc3) \(rótulo: bd: sem rótulo\)$' "$FAKE_LOG/mail-bodies")" "2 0 1 2"
check "bd que falha no rótulo: o log durável NÃO diz que marcou (marcadas vazio) e traz as falhas por bead" "$(tail -n 1 "$AUDIT" | jq -c '[.kind, .marcadas, (.marcas_falhas | keys)]')" '["queda",[],["ga-aaa1","ga-ccc3"]]'
sw; check "bd que falha: o estado avançou e nada se repete (nem a marca, nem os e-mails)" "$RC $(mails) $(bds)" "0 2 2"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; touch "$FAKE_LOG/bd-fail-label" "$FAKE_LOG/mail-fail-2nd"; sw
check "o e-mail MARCA FALHOU que também falha: a varredura diz, segue e sai 1 (o aviso da queda já tinha saído)" "$RC $(mails) $(grep -c 'o e-mail das marcas que falharam também falhou' "$W/out")" "1 1 1"
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; touch "$FAKE_LOG/bd-fail-comment"; sw
check "bd que falha no comentário: exit 1, o rótulo ENTROU nas 2 e a falha é dita como comentário, nunca como 'não marquei'" "$RC $(grep -c 'label add' "$FAKE_LOG/bd") $(grep -c 'marquei ga-aaa1, mas SEM o comentário com os números' "$W/out") $(grep -c 'não marquei' "$W/out")" "1 2 1 0"
check "bd que falha no comentário: o log traz a bead entre as marcadas (rótulo entrou) E entre as falhas (comentário não), e o 2o e-mail sai" "$(tail -n 1 "$AUDIT" | jq -c '[.marcadas, (.marcas_falhas | keys)]') $(mails)" '[["ga-aaa1","ga-ccc3"],["ga-aaa1","ga-ccc3"]] 2'
reset; base; L dog night 0 10 "$H2" "$R5"; echo 'isto não é json' >"$STATE"; sw
check "estado ilegível: exit 1, nada é avaliado, sem traceback, e o arquivo fica como estava" "$(badstate) $(cnt "$AUDIT") $(cat "$STATE")" "1 0 0 1 0 isto não é json"
reset; base; L dog night 0 10 "$H2" "$R5"; echo '{"linhas":"3","papeis":{}}' >"$STATE"; sw
check "estado com a forma errada (linhas como texto): o mesmo" "$(badstate)" "1 0 0 1"
reset; base; L dog night 0 10 "$H2" "$R5"; echo '{"linhas":-1,"papeis":{}}' >"$STATE"; sw
check "estado com linhas negativas: o mesmo" "$(badstate)" "1 0 0 1"
reset; base; L dog night 0 10 "$H2" "$R5"; echo '{"linhas":3}' >"$STATE"; sw
check "estado sem o campo papeis: o mesmo (e sem KeyError)" "$(badstate)" "1 0 0 1"
if [ "$(id -u)" != 0 ]; then
  reset; chmod 555 "$CITY/.gc/agent-battery"; L dog night 0 10; sw; chmod 755 "$CITY/.gc/agent-battery"
  check "1a varredura que não consegue gravar a base: exit 1" "$RC" 1
  reset; base; chmod 555 "$CITY/.gc/agent-battery"; L dog night 0 10 "$H2" "$R5"; sw
  check "estado que não grava no meio da varredura: exit 1 (o e-mail já tinha saído)" "$RC $(mails)" "1 1"
  sw; check "...e enquanto ele não grava a linha não é dada como vista: o MESMO aviso sai de novo (entrega pelo menos uma vez, dito no runbook)" "$RC $(mails)" "1 2"
  chmod 755 "$CITY/.gc/agent-battery"
fi
if [ "$(id -u)" != 0 ]; then
  reset; base; chmod 000 "$JSONL"; sw
  check "jsonl que existe e não lê: exit 1, nunca 'sem linhas'" "$RC $(grep -c 'não consegui ler' "$W/out")" "1 1"
  chmod 600 "$JSONL"
fi
reset; base; L dog night 0 10 "$H2" "$R5"; head -n 2 "$JSONL" >"$W/short"; cp "$W/short" "$JSONL"; sw
check "jsonl que encolheu: regrava a base, não reavalia e mantém o estado dos papéis" "$RC $(mails) $(st .linhas)" "0 0 2"
reset; base; printf '%s' "$(jq -nc --arg ac "$AC" --arg h "$H2" --arg r "$R5" '{ts:"2026-12-01T00:00:00Z", mode:"night", papeis:{dog:{cat:"ok", ok:0, medidas:10, acervo:$ac, config_sha:$h, config_ref_sha:$r}}}')" >>"$JSONL"; sw
check "última linha ainda sem quebra de linha (sendo gravada): fica para a próxima varredura" "$(mails) $(st .linhas)" "0 3"
echo >>"$JSONL"; sw; check "...e quando completa, é avaliada" "$(mails) $(st .linhas)" "1 4"
reset; base; echo 'lixo' >>"$JSONL"; echo '[1]' >>"$JSONL"; L dog night 0 10 "$H2" "$R5"; sw
check "linhas que não são uma rodada ficam no meio: a seguinte é avaliada e o aviso diz quantas foram ignoradas" "$(mails) $(st .linhas) $(grep -c '2 linha(s) nova(s)' "$W/out")" "1 6 1"
reset; base; printf '\xff\xfe lixo\n' >>"$JSONL"; L dog night 0 10 "$H2" "$R5"; sw
check "bytes que não são UTF-8 numa linha do jsonl: não quebra (sem traceback), a linha é ignorada e a seguinte é avaliada" "$RC $(mails) $(st .linhas) $(grep -c Traceback "$W/out") $(grep -c '1 linha(s) nova(s)' "$W/out")" "0 1 5 0 1"
withrp() { sed '$d' "$JSONL" >"$JSONL.tmp"; tail -n 1 "$JSONL" | jq -c '. + {role_prompt: "dog=scripts/ruim.md"}' >>"$JSONL.tmp"; mv "$JSONL.tmp" "$JSONL"; } # a última linha vira uma medida com o prompt de um papel trocado
reset; base "$H1" "$R0"; L dog night 0 10 "$H2" "$R5"; withrp; sw
check "medida com o prompt trocado (--role-prompt) NÃO é rodada: nada é avaliado, avisado nem marcado, e o aviso diz que a ignorou" "$RC $(mails) $(bds) $([ -e "$AUDIT" ] && echo log || echo sem-log) $(grep -c '1 linha(s) nova(s)' "$W/out")" "0 0 0 sem-log 1"
reset; nights 2 dog night 8 10; L dog night 8 10; withrp; sw; L dog night 0 10 "$H2" "$R5"; sw
check "...e nunca entra na base: 2 noites de verdade e 1 com o prompt trocado ainda é sem_base" "$(mails) $(lastkind)" "0 sem_base"
reset; sw --janela 0; check "--janela 0: exit 2" "$RC" 2
sw --min-noites 6; check "--min-noites maior que --janela: exit 2" "$RC" 2
sw --limiar 0; check "--limiar 0: exit 2" "$RC" 2
sw --alfa 1; check "--alfa 1: exit 2" "$RC" 2
sw --max-marcar -1; check "--max-marcar negativo: exit 2" "$RC" 2
sw --control-timeout-s 0; check "--control-timeout-s 0: exit 2" "$RC" 2
sw --limiar 1; check "--limiar 1 (o teto) é válido" "$RC" 0
sw --janela 3 --min-noites 3; check "--min-noites igual a --janela é válido" "$RC" 0
ABA_LIMIAR=abc sw; check "valor de ABA_<NOME> que não é número: exit 2, sem traceback" "$RC $(grep -c Traceback "$W/out")" "2 0"
check "o executor da fatia 2 é a fonte dos caminhos: os 3 papéis medidos têm prompt" "$(python3 -I -c 'import importlib.util,sys; s = importlib.util.spec_from_file_location("e", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); print(" ".join(str(r in m.ROLE_PROMPTS) for r in ("dog", "wa-worker", "reviewer")), m.CONFIG_PATHS)' "$HERE/agent-battery-run.py")" "True True True ('.claude', 'CLAUDE.md')"

# o controle negativo: o driver REAL contra um ssh que executa o comando remoto de verdade e um executor de mentira que devolve o resumo no formato do real (o sha do acervo sai do --tasks recebido)
mkdir -p "$W/node/.city/scripts" "$W/bin"
cat >"$W/node/.city/scripts/agent-battery-run.py" <<'EOF'
import hashlib, json, os, sys
a = sys.argv[1:]
arg = lambda k: a[a.index(k) + 1] if k in a else ""
role, L = arg("--as-role"), os.environ["FAKE_LOG"]
with open(L + "/exec.log", "a") as f:
    f.write(json.dumps(a) + "\n")
if os.path.exists(L + "/mode-garbage"):
    print("isto não é json"); sys.exit(0)
k = int(open(L + "/ok").read()) if os.path.exists(L + "/ok") else 0
print(json.dumps({"config_sha": {role: "d" * 64}, "config_ref_sha": "e" * 40, "tasks_sha256": "f" * 64 if os.path.exists(L + "/acervo-other") else hashlib.sha256(open(arg("--tasks"), "rb").read()).hexdigest(), "por_estado": {"medida": 8},
                  "por_papel": {role: {"medidas": 8, "ok": k, "taxa": k / 8}}, "descartes": {}, "freio": None, "tokens_noite_antes": 0, "tokens_noite_depois": 8000}))
EOF
git -C "$W/node" init -q -b main && git -C "$W/node" -c user.email=t@t -c user.name=t add -A && git -C "$W/node" -c user.email=t@t -c user.name=t commit -qm base && git -C "$W/node" update-ref refs/remotes/origin/main HEAD
printf '#!/usr/bin/env bash\nwhile [ "${1:-}" = -o ]; do shift 2; done\nshift\nexec bash -c "$1"\n' >"$W/fake-ssh"
printf '#!/usr/bin/env bash\n[ -e "$FAKE_LOG/token-fail" ] && exit 1\necho sk-ant-oat01-FAKETOKEN0123456789abcdefXYZ\n' >"$W/fake-token"
chmod +x "$W/fake-ssh" "$W/fake-token"
if ! command -v timeout >/dev/null 2>&1; then # o comando remoto usa `timeout` (Linux do nó); o mini (macOS) não o tem: um shim com a mesma forma (-k N DURAÇÃO cmd, 124 no prazo)
  printf '#!/usr/bin/env python3\nimport subprocess, sys\na = sys.argv[1:]\na = a[2:] if a[0] == "-k" else a\ntry:\n    sys.exit(subprocess.run(a[1:], timeout=float(a[0])).returncode)\nexcept subprocess.TimeoutExpired:\n    sys.exit(124)\n' >"$W/bin/timeout"
  chmod +x "$W/bin/timeout"; export PATH="$W/bin:$PATH"
fi
cset() { # acertos [noites] [acertos da base de 10]: acervo e nó ligados na cidade, N noites de base do dog (80%) no acervo de hoje; o executor de mentira acerta $1 de 8
  reset; printf '{"task_id":"ga-x","title":"t"}\n' >"$CITY/.gc/agent-battery/tasks.jsonl"; echo '{"sha256":"x"}' >"$CITY/.gc/agent-battery/tasks.jsonl.meta.json"; touch "$CITY/.gc/hetzner-node.on"
  ACT=$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$CITY/.gc/agent-battery/tasks.jsonl")
  nights "${2-3}" dog night "${3-8}" 10 "$H1" "$R0" "$ACT"; echo "$1" >"$FAKE_LOG/ok"; cp "$JSONL" "$W/jsonl-before"
}
ctl() { ABN_SSH="$W/fake-ssh" ABN_TOKEN_CMD="$W/fake-token" ABN_PREFIX=.city ABN_NODE_REPO="$W/node" ABN_NODE_STATE="$W/ns" ABN_RUN_TIMEOUT_S=30 \
  python3 -I "$TOOL" control --city "$CITY" --mail "$W/fake-mail" --bd "$W/fake-bd" "$@" >"$W/out" 2>&1; RC=$?; }
ran() { [ -e "$FAKE_LOG/exec.log" ] && echo rodou || echo nao-rodou; }
TODAY=$(date -u +%Y-%m-%d)
cset 0; ctl
check "controle: prompt ruim derruba a taxa e o aviso dispara: PASSOU, exit 0" "$RC $(tail -n 1 "$W/out")" "0 CONTROLE: PASSOU"
check "controle: UM e-mail ao Mayor, com o veredito e o papel" "$(mails) $(head -n 1 "$FAKE_LOG/mail-subj")" "1 [agent-battery] CONTROLE NEGATIVO $TODAY: PASSOU (dog)"
check "controle: o corpo traz a taxa contra a base e diz que a main e o jsonl real não mudam" "$(grep -c -E 'dog: 0% \(0/8 tarefas\) contra 80%' "$FAKE_LOG/mail-body") $(grep -c 'a main e o jsonl real não mudam' "$FAKE_LOG/mail-body")" "1 1"
check "controle: o executor leu o prompt ruim no lugar do prompt do papel, com estado e papel próprios" "$(jq -r 'join(" ")' "$FAKE_LOG/exec.log")" "--repo $W/node --prefix .city --config-ref origin/main --state-dir $W/ns-control/night/dog --tasks $W/ns-control/tasks.jsonl --as-role dog --token-cap 1200000 --role-prompt dog=scripts/agent-battery-control-prompt.md"
check "controle: o jsonl real não foi tocado e nenhum relatório nasceu na cidade real" "$(cmp "$JSONL" "$W/jsonl-before" && echo igual) $(ls "$CITY/.gc/logs" | tr '\n' ' ')" "igual agent-battery.jsonl "
check "controle: não marca bead, não grava estado de aviso e não deixa a cidade descartável" "$(bds) $([ -e "$STATE" ] && echo estado || echo sem-estado) $(ls "$TMPDIR" | grep -c aba-control)" "0 sem-estado 0"
check "controle: o relatório da noite do driver NÃO vai ao Mayor (o driver recebe --mail true; só o e-mail do controle sai)" "$([ -e "$FAKE_LOG/gc-calls" ] && echo chamou || echo calado)" calado
cset 7; ctl
check "controle: taxa que NÃO caiu = a bateria não enxerga a regressão: FALHOU, exit 1, e o Mayor sabe" "$RC $(tail -n 1 "$W/out") $(mails) $(grep -c 'NÃO enxergou' "$FAKE_LOG/mail-body") $(grep -c 'chance de ser sorte' "$FAKE_LOG/mail-body")" "1 CONTROLE: FALHOU 1 1 0"
cset 4 3 7; ctl
check "controle com queda que cabe na sorte (70% → 50% em 8 tarefas): FALHOU, o aviso NÃO teria disparado" "$RC $(tail -n 1 "$W/out") $(grep -c 'a queda coube na sorte' "$FAKE_LOG/mail-body")" "1 CONTROLE: FALHOU 1"
cset 0 2; ctl
check "controle sem base (2 noites): INERTE, exit 0 e o executor NEM rodou (não gasta token sem poder julgar)" "$RC $(tail -n 1 "$W/out") $(ran) $(grep -c 'mínimo 3' "$FAKE_LOG/mail-body")" "0 CONTROLE: INERTE nao-rodou 1"
cset 0; rm "$CITY/.gc/agent-battery/tasks.jsonl"; ctl
check "controle sem acervo: INERTE e nada rodou" "$RC $(tail -n 1 "$W/out") $(ran)" "0 CONTROLE: INERTE nao-rodou"
cset 0; touch "$FAKE_LOG/token-fail"; ctl
check "controle sem credencial (o driver diz INERTE): INERTE, exit 0" "$RC $(tail -n 1 "$W/out") $(ran) $(grep -c 'o driver disse INERTE' "$FAKE_LOG/mail-body")" "0 CONTROLE: INERTE nao-rodou 1"
cset 0; rm "$CITY/.gc/hetzner-node.on"; ctl
check "controle com o nó desligado (o driver diz PULADO): INERTE" "$(tail -n 1 "$W/out") $(ran)" "CONTROLE: INERTE nao-rodou"
cset 0; touch "$FAKE_LOG/mode-garbage"; ctl
check "controle em que o executor devolve lixo (o driver diz FALHOU): FALHOU, exit 1" "$RC $(tail -n 1 "$W/out") $(grep -c 'o driver disse FALHOU' "$FAKE_LOG/mail-body")" "1 CONTROLE: FALHOU 1"
cset 0; nights 3 reviewer night 8 10 "$H1" "$R0" "$ACT"; ctl --role reviewer
check "controle de outro papel: o executor recebe esse papel e o prompt ruim dele" "$(tail -n 1 "$W/out") $(jq -r 'join(" ")' "$FAKE_LOG/exec.log" | grep -c -- '--as-role reviewer --token-cap 1200000 --role-prompt reviewer=scripts/agent-battery-control-prompt.md$')" "CONTROLE: PASSOU 1"
cset 0; ctl --prompt scripts/outro.md
check "--prompt troca o arquivo do prompt ruim" "$(jq -r 'join(" ")' "$FAKE_LOG/exec.log" | grep -c -- '--role-prompt dog=scripts/outro.md$')" 1
cset 0; ctl --role nao-existe
check "papel que não existe: sem base, INERTE e nada rodou" "$RC $(tail -n 1 "$W/out") $(ran)" "0 CONTROLE: INERTE nao-rodou"
cset 0; touch "$FAKE_LOG/mail-fail"; ctl
check "controle PASSOU mas o e-mail falhou: exit 1 (ninguém acha que o Mayor foi avisado), o veredito sai mesmo assim" "$RC $(tail -n 1 "$W/out") $(grep -c 'WARN: o e-mail ao Mayor falhou' "$W/out")" "1 CONTROLE: PASSOU 1"
cset 0; touch "$FAKE_LOG/acervo-other"; ctl
check "controle em que o executor mediu OUTRO acervo (o acervo mudou no meio): INERTE, não FALHOU" "$RC $(tail -n 1 "$W/out") $(grep -c 'sem linha de base real para julgar a queda' "$FAKE_LOG/mail-body")" "0 CONTROLE: INERTE 1"
cset 0; ABN_MIN_MEDIDAS=0 ctl
check "driver que nem chega a medir (uso errado, rc 2): FALHOU e o motivo traz o rc" "$RC $(tail -n 1 "$W/out") $(grep -c 'o driver não deixou linha no jsonl (rc 2)' "$FAKE_LOG/mail-body")" "1 CONTROLE: FALHOU 1"
cset 0; TOOL="$W/lonely/agent-battery-alert.py" ctl
check "sem o driver ao lado: o controle FALHOU dizendo o motivo, e nada rodou" "$RC $(tail -n 1 "$W/out") $(grep -c 'não consegui carregar o driver' "$FAKE_LOG/mail-body") $(ran)" "1 CONTROLE: FALHOU 1 nao-rodou"
if [ "$(id -u)" != 0 ]; then
  cset 0; chmod 000 "$JSONL"; ctl; chmod 600 "$JSONL"
  check "controle sem conseguir ler o jsonl real: FALHOU e nada rodou" "$RC $(tail -n 1 "$W/out") $(ran)" "1 CONTROLE: FALHOU nao-rodou"
  cset 0; chmod 000 "$CITY/.gc/agent-battery/tasks.jsonl"; ctl; chmod 600 "$CITY/.gc/agent-battery/tasks.jsonl"
  check "controle sem conseguir ler o acervo: FALHOU e nada foi gasto" "$RC $(tail -n 1 "$W/out") $(ran)" "1 CONTROLE: FALHOU nao-rodou"
fi
cset 0; ctl --city "$W/plain-sem-nada"
check "cidade que não existe: INERTE (sem acervo), nunca traceback" "$RC $(tail -n 1 "$W/out") $(grep -c Traceback "$W/out")" "0 CONTROLE: INERTE 0"
cset 0; python3 -I -c 'import importlib.util,sys; s = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); m.tempfile.mkdtemp = lambda **k: (_ for _ in ()).throw(OSError(28, "No space left on device")); sys.argv = ["t", "control", "--city", sys.argv[2], "--mail", sys.argv[3]]; sys.exit(m.main())' "$TOOL" "$CITY" "$W/fake-mail" >"$W/out" 2>&1; RC=$?
check "disco cheio ao criar a cidade descartável (mkdtemp): FALHOU e e-mail ao Mayor, sem traceback e sem rodar o executor" "$RC $(tail -n 1 "$W/out") $(grep -c Traceback "$W/out") $(grep -c 'não consegui preparar a cidade descartável (\[Errno 28\] No space left on device)' "$FAKE_LOG/mail-body") $(ran)" "1 CONTROLE: FALHOU 0 1 nao-rodou"

# o arquivo do prompt ruim e a ordem
PROMPT="$HERE/agent-battery-control-prompt.md"
check "prompt ruim: o executor o aceita em --role-prompt (raiz scripts/), não é prompt de nenhum papel nem caminho de configuração" "$(python3 -I -c 'import importlib.util,sys; s = importlib.util.spec_from_file_location("e", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); p = "scripts/agent-battery-control-prompt.md"; print(m.good_path(p, m.PATH_RE, ("agents/", "packs/", "scripts/")), p in m.ROLE_PROMPTS.values(), any(p.startswith(c) for c in m.CONFIG_PATHS))' "$HERE/agent-battery-run.py")" "True False False"
check "prompt ruim: curto (cabe sem índice) e sem cara de explicação: tudo o que está no arquivo chega ao claude" "$([ "$(wc -c <"$PROMPT" | tr -d ' ')" -lt 300 ] && echo curto) $(grep -c -i -E 'controle|bateria|teste' "$PROMPT")" "curto 0"
ORD="$HERE/../packs/town-deltas/orders/hetzner-agent-battery-alert.toml"
check "ordem: cooldown de 20 min e o exec chama a varredura" "$(grep -c -E '^trigger = "cooldown"$' "$ORD") $(grep -c -E '^interval = "20m"$' "$ORD") $(grep -c -F 'exec = "python3 -I $PACK_DIR/../../scripts/agent-battery-alert.py sweep"' "$ORD")" "1 1 1"

[ "$FAILS" -eq 0 ] && echo "TUDO OK" || echo "$FAILS falha(s)"
[ "$FAILS" -eq 0 ]
