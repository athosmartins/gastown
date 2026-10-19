#!/usr/bin/env bash
# gate-done-remote.selftest.sh — prova hermética de scripts/gate-done-remote.py (ga-2hd02v.1.13): cidade, origin e espelho FALSOS em tmp, `bd`/`gc` falsos,
# e o commands/gate-done.md DE VERDADE (a fonte única que o executável reaproveita: se ele mudar de forma, este teste quebra). Uma seção final roda a cadeia
# pelo remote-shim-wrapper.py real (ambiente montado do zero, cwd = cidade) e outra mata 5 mutantes. Nada toca a cidade nem o origin de verdade.
# Uso: bash scripts/gate-done-remote.selftest.sh   (FAILFAST=1 para no 1º caso que reprova)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HQ="$(cd "$HERE/.." && pwd)"
EXE_SRC="${EXE_UNDER_TEST:-$HERE/gate-done-remote.py}"
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gdr-selftest.XXXXXX")" && pwd -P)
trap 'chmod -R u+rwX "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
n=0; fails=0
ok() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok   $2"; return; fi; echo "FAIL $2"; fails=$((fails+1)); [ -s "$T/err" ] && echo "     (stderr: $(head -c 400 "$T/err" | tr '\n' ' '))"
  [ -n "${FAILFAST:-}" ] && { echo "FAILFAST: parei no caso $n"; exit 1; }; return 0; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
eqs() { [ "$1" = "$2" ]; }

BIN="$T/bin"; ORIGIN="$T/origin.git"; OUTER="$T/outer"; CITY="$OUTER/city"; MIRROR="$CITY/.gc/hetzner-mirror/repos/gascity.git"; DB="$T/db.json"; BDLOG="$T/bd.log"
SESS="dog-remote-abc123"; ALIAS="dog-remote-1"; SLUG="remoto-teste-do-atalho"; BR="fix/ga-t1-$SLUG"
mkdir -p "$BIN" "$T/home"

# ── bd e gc falsos: o "banco" é um JSON; cada chamada vai para bd.log ──────────────────────────────────────────────────────────────────────────────
cat > "$BIN/bd" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]; T = os.path.dirname(os.path.dirname(os.path.realpath(__file__))); db_path = T + "/db.json"; env = os.environ.get
with open(T + "/bd.log", "a") as f: f.write(" ".join(a) + "\n")
if a[:1] == ["-C"]: a = a[2:]
db = json.load(open(db_path)); beads = db["beads"]
def save(): json.dump(db, open(db_path, "w"))
def flag(name, default=None):
    for i, x in enumerate(a):
        if x == name and i + 1 < len(a): return a[i + 1]
        if x.startswith(name + "="): return x.split("=", 1)[1]
    return default
def multi(name): return [a[i + 1] for i, x in enumerate(a) if x == name and i + 1 < len(a)]
cmd = a[0] if a else ""
if env("FAKE_BD_FAIL") == cmd: sys.stderr.write("fake: bd falhou\n"); sys.exit(1)
if cmd == "list":
    if env("FAKE_BD_BADJSON") == "list": print("isto nao e json"); sys.exit(0)
    st, asg, labels = flag("--status"), flag("--assignee"), multi("--label") + multi("-l")
    rows = [b for b in beads.values() if (not st or b["status"] == st) and (asg is None or b.get("assignee", "") == asg) and all(l in b["labels"] for l in labels)]
    print(json.dumps(rows)); sys.exit(0)
if cmd == "show":
    i = [x for x in a[1:] if not x.startswith("-")][0]
    if i not in beads: sys.stderr.write("not found\n"); sys.exit(1)
    if env("FAKE_BD_BADJSON") == "show:" + i: print("{nao e json"); sys.exit(0)
    print(json.dumps([beads[i]]) if "--json" in a else i); sys.exit(0)
if cmd == "create":
    if env("FAKE_BD_NOMARKER"): sys.exit(1)
    db["n"] += 1; mid = "ga-mk%d" % db["n"]
    beads[mid] = {"id": mid, "title": a[1], "status": "open", "labels": multi("-l"), "description": flag("-d"), "metadata": {}, "issue_type": "chore"}
    save(); print(json.dumps({"id": mid})); sys.exit(0)
if cmd == "label" and a[1] == "add":
    beads[a[2]]["labels"].append(a[3]); save(); sys.exit(0)
if cmd == "update":
    b = beads[a[1]]
    if flag("--if-assignee") is not None and b.get("assignee", "") != flag("--if-assignee"): sys.exit(13)
    for kv in multi("--set-metadata"):
        k, v = kv.split("=", 1)
        if not (env("FAKE_BD_NO_SUBMITTED_BY") and k == "gate.submitted_by"): b["metadata"][k] = v
    for k in multi("--unset-metadata"):
        b["metadata"].pop(k, None)
        if env("FAKE_BD_STEAL"): b["assignee"] = "outro-dono"
    if "-a" in a: b["assignee"] = flag("-a")
    save(); sys.exit(0)
if cmd == "close":
    beads[a[1]]["status"] = "closed"; save(); sys.exit(0)
sys.stderr.write("fake bd: comando nao previsto: %s\n" % a); sys.exit(64)
EOF
cat > "$BIN/gc" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
if "rig" in a and "list" in a: print(json.dumps({"rigs": [{"name": "gascity", "path": os.path.dirname(os.path.dirname(os.path.realpath(__file__))) + "/outer/city", "prefix": "ga"}]})); sys.exit(0)
sys.stderr.write("fake gc: comando nao previsto: %s\n" % a); sys.exit(64)
EOF
chmod +x "$BIN/bd" "$BIN/gc"

# ── repositórios: origin (main), "~/gt" (outer, com a cidade dentro), espelho bare com worker/<sessão> ─────────────────────────────────────────────
G() { git -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false "$@"; }
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$OUTER" 2>/dev/null
mkdir -p "$CITY/scripts" "$CITY/commands" "$CITY/packs/town-deltas/assets"
cp "$HQ/commands/gate-done.md" "$CITY/commands/gate-done.md"
printf '#!/bin/sh\nexit 5\n' > "$CITY/packs/town-deltas/assets/pre-gate-review.sh"   # programa do pre-gate FECHADO (rc 5, nada no stdout): é o estado real desde 03/10
printf 'base\n' > "$CITY/base.txt"
G -C "$OUTER" add city/base.txt city/commands city/packs >/dev/null && G -C "$OUTER" commit -qm "base" && G -C "$OUTER" push -q origin HEAD:main 2>/dev/null
git clone -q --bare "$ORIGIN" "$MIRROR"
G -C "$OUTER" checkout -q -b work-tmp && printf 'trabalho do dog remoto\n' > "$CITY/trabalho.txt" && G -C "$OUTER" add city/trabalho.txt >/dev/null \
  && G -C "$OUTER" commit -qm "feat(ga-t1): trabalho do dog remoto" && SHA=$(git -C "$OUTER" rev-parse HEAD) \
  && git -C "$OUTER" push -q "$MIRROR" "HEAD:refs/heads/worker/$SESS" && G -C "$OUTER" checkout -q main && git -C "$OUTER" branch -q -D work-tmp
cp -p "$EXE_SRC" "$CITY/scripts/gate-done-remote.py"; chmod +x "$CITY/scripts/gate-done-remote.py"
MAINSHA=$(git -C "$OUTER" rev-parse main)

reset_db() {  # estado inicial: ga-t1 atribuída ao alias, com rota de pool
  python3 -I - "$DB" "$ALIAS" <<'EOF'
import json, sys
db, alias = sys.argv[1:]
json.dump({"n": 0, "beads": {"ga-t1": {"id": "ga-t1", "title": "Remoto: teste do atalho", "status": "in_progress", "assignee": alias, "issue_type": "bug",
           "labels": ["story:approved"], "metadata": {"gc.routed_to": "dog-remote"}, "created_by": "gastown.mayor", "owner": "x@y"}}}, open(db, "w"))
EOF
  : > "$BDLOG"
}
dbq() { jq -r "$1" "$DB"; }   # lê o banco falso com um programa jq
run_exe() {  # run_exe [VAR=valor ...] → RC, $T/out, $T/err. Ambiente do zero, como o wrapper o monta; cwd = cidade
  ( cd "$CITY" && env -i HOME="$T/home" USER=t LOGNAME=t LANG=en_US.UTF-8 PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      BEADS_ACTOR="$ALIAS" GC_ALIAS="$ALIAS" GC_SESSION_NAME="$SESS" GC_TEMPLATE=dog-remote "$@" \
      "$CITY/scripts/gate-done-remote.py" ) > "$T/out" 2> "$T/err"; RC=$?
}
origin_has() { git --git-dir="$ORIGIN" rev-parse --verify -q "refs/heads/$1" 2>/dev/null; }
mut_count() { grep -cE '^(-C [^ ]+ )?(create|update|label|close) ' "$BDLOG"; }   # quantas chamadas que ESCREVEM no banco
clean_after() {  # nada do que a execução criou sobra
  [ ! -e "$CITY/.gc/gate-done-remote/wt-ga-t1" ] && ! git -C "$OUTER" show-ref -q --verify "refs/heads/$BR" && [ -z "$(git -C "$OUTER" for-each-ref refs/gt-remote)" ] \
    && [ "$(git -C "$OUTER" worktree list | wc -l | tr -d ' ')" = 1 ]
}

# ── 1. ensaio: resolve tudo e não escreve nada ──────────────────────────────────────────────────────────────────────────────────────────────────────
reset_db; run_exe GATE_DONE_REMOTE_DRY_RUN=1
ok $((RC != 0)) "ensaio sai 0"
has "$T/out" "bead=ga-t1 worker/$SESS@${SHA:0:12} → $BR" ; ok $? "ensaio diz alias, bead, sha e branch"
has "$T/out" "ensaio: nada foi escrito"; ok $? "ensaio diz que nada foi escrito"
[ "$(mut_count)" = 0 ]; ok $? "ensaio: nenhuma escrita no banco"
! origin_has "$BR" >/dev/null; ok $? "ensaio: nada foi empurrado ao origin"
[ ! -e "$CITY/.gc/gate-done-remote" ]; ok $? "ensaio: nem a pasta de trabalho foi criada"

# ── 2. caminho feliz: o gate-done de verdade, do branch renomeado, até o marcador e a bead solta ─────────────────────────────────────────────────────
reset_db; FH_BEFORE=$(ls -l "$OUTER/.git/FETCH_HEAD" 2>&1); run_exe
ok $((RC != 0)) "feliz: sai 0"
[ "$(origin_has "$BR")" = "$SHA" ]; ok $? "feliz: o origin tem $BR no MESMO sha do espelho"
has "$T/out" "Marker created: ga-mk1"; ok $? "feliz: o marcador foi criado (linha do gate-done.md)"
[ "$(dbq '.beads["ga-mk1"].metadata["gate.submitted_by"] // ""')" = "$ALIAS" ]; ok $? "feliz: gate.submitted_by = alias remoto"
[ "$(dbq '[.beads["ga-mk1"].labels[] | select(startswith("branch:") or startswith("source-bead:") or startswith("type:") or startswith("gate-status:"))] | sort | join(",")')" = "branch:$BR,gate-status:ready,source-bead:ga-t1,type:quality-gate-marker" ]; ok $? "feliz: o marcador leva branch, source-bead, type e gate-status:ready"
has_desc() { dbq '.beads["ga-mk1"].description' | grep -qF -- "$1"; }
has_desc "base_commit: $MAINSHA"; ok $? "feliz: base_commit = main do origin (busca fresca)"
has_desc "author: $ALIAS"; ok $? "feliz: author = alias remoto"
has_desc "NAO verificada aqui"; ok $? "feliz: a auto-auditoria aparece como NÃO verificada, não calada"
[ "$(dbq '.beads["ga-t1"].labels | index("gate:queued") != null')" = true ]; ok $? "feliz: gate:queued na bead-fonte"
[ -z "$(dbq '.beads["ga-t1"].assignee // ""')" ] && [ "$(dbq '.beads["ga-t1"].metadata | has("gc.routed_to")')" = false ]; ok $? "feliz: a bead foi SOLTA (sem assignee e sem gc.routed_to)"
[ "$(dbq '.beads["ga-t1"].status')" = in_progress ]; ok $? "feliz: a bead segue in_progress (o gate a fecha)"
has "$T/out" "bead solta: ga-t1"; ok $? "feliz: a saída diz que soltou"
has "$T/out" "submetido: $BR @ $SHA"; ok $? "feliz: a saída imprime o sha submetido"
clean_after; ok $? "feliz: worktree, branch local e ref temporária foram recolhidos"
eqs "$FH_BEFORE" "$(ls -l "$OUTER/.git/FETCH_HEAD" 2>&1)"; ok $? "feliz: o FETCH_HEAD do repositório compartilhado não foi tocado"
[ "$(git -C "$OUTER" rev-parse main)" = "$MAINSHA" ] && [ "$(git -C "$OUTER" branch --show-current)" = main ]; ok $? "feliz: a árvore principal (main) ficou onde estava"

# ── 3. reenvio: o mesmo branch avança (FF) e passa; histórico reescrito é recusado sem força ──────────────────────────────────────────────────────────
reset_db; G -C "$OUTER" checkout -q -b work-tmp "$SHA" && printf 'mais\n' > "$CITY/mais.txt" && G -C "$OUTER" add city/mais.txt >/dev/null && G -C "$OUTER" commit -qm "feat(ga-t1): mais" \
  && SHA2=$(git -C "$OUTER" rev-parse HEAD) && git -C "$OUTER" push -q -f "$MIRROR" "HEAD:refs/heads/worker/$SESS" && G -C "$OUTER" checkout -q main && git -C "$OUTER" branch -q -D work-tmp
run_exe; ok $((RC != 0)) "reenvio (avanço FF): sai 0"
[ "$(origin_has "$BR")" = "$SHA2" ]; ok $? "reenvio: o origin avançou para o sha novo"
reset_db; G -C "$OUTER" checkout -q -b work-tmp main && printf 'outra historia\n' > "$CITY/outra.txt" && G -C "$OUTER" add city/outra.txt >/dev/null && G -C "$OUTER" commit -qm "feat(ga-t1): reescrito" \
  && SHA3=$(git -C "$OUTER" rev-parse HEAD) && git -C "$OUTER" push -q -f "$MIRROR" "HEAD:refs/heads/worker/$SESS" && G -C "$OUTER" checkout -q main && git -C "$OUTER" branch -q -D work-tmp
run_exe; ok $((RC != 1)) "reescrita (não-FF): recusa com 1, sem forçar"
[ "$(origin_has "$BR")" = "$SHA2" ]; ok $? "reescrita: o origin NÃO foi sobrescrito"
[ "$(dbq '[.beads | keys[] | select(startswith("ga-mk"))] | length')" = 0 ] && [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ]; ok $? "reescrita: sem marcador novo e a bead segue com o alias"
clean_after; ok $? "reescrita: o que a execução criou foi recolhido"
git -C "$OUTER" push -q -f "$MIRROR" "$SHA:refs/heads/worker/$SESS"; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"   # volta ao estado do caso feliz

# ── 4. recusas ANTES de qualquer escrita: a bead, o espelho, o ambiente e a forma do gate-done.md ──────────────────────────────────────────────────
nothing_written() { [ "$(mut_count)" = 0 ] && ! origin_has "$BR" >/dev/null && [ ! -e "$CITY/.gc/gate-done-remote/wt-ga-t1" ]; }
reset_db; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["beads"]["ga-t1"]["assignee"]="outro"; json.dump(d,open(sys.argv[1],"w"))' "$DB"
run_exe; ok $((RC != 1)) "sem bead do alias: recusa 1"; has "$T/err" "nenhuma bead in_progress"; ok $? "sem bead: diz o motivo"; nothing_written; ok $? "sem bead: nada escrito"
reset_db; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["beads"]["ga-2"]=dict(d["beads"]["ga-t1"],id="ga-2"); json.dump(d,open(sys.argv[1],"w"))' "$DB"
run_exe; ok $((RC != 1)) "duas beads do alias: recusa 1"; has "$T/err" "não adivinho"; ok $? "duas beads: diz que não adivinha"; nothing_written; ok $? "duas beads: nada escrito"
reset_db; run_exe FAKE_BD_FAIL=list; ok $((RC != 1)) "bd list que FALHA: recusa 1"; has "$T/err" "não consegui ler"; ok $? "bd falho: 'não consegui ler', não 'nenhuma bead'"; nothing_written; ok $? "bd falho: nada escrito"
reset_db; run_exe FAKE_BD_BADJSON=list; ok $((RC != 1)) "bd list com JSON corrompido: recusa 1"; has "$T/err" "ilegível"; ok $? "JSON corrompido: diz 'ilegível'"; nothing_written; ok $? "JSON corrompido: nada escrito"
reset_db; run_exe BEADS_ACTOR=; ok $((RC != 2)) "sem alias: recusa 2"; nothing_written; ok $? "sem alias: nada escrito"
reset_db; run_exe GC_SESSION_NAME='../x'; ok $((RC != 2)) "sessão com '../': recusa 2"; nothing_written; ok $? "sessão com '../': nada escrito"
reset_db; run_exe GC_SESSION_NAME=dog-remote-zzz999; ok $((RC != 1)) "espelho sem worker/<sessão>: recusa 1"; has "$T/err" "o espelho não tem worker/dog-remote-zzz999"; ok $? "espelho sem a ref: diz que o push não chegou"; nothing_written; ok $? "espelho sem a ref: nada escrito"
reset_db; run_exe GATE_DONE_REMOTE_MIRROR="$T/nao-existe.git"; ok $((RC != 1)) "espelho ausente: recusa 1"; has "$T/err" "não existe neste mini"; ok $? "espelho ausente: diz o motivo"
mkdir -p "$T/naogit"; reset_db; run_exe GATE_DONE_REMOTE_MIRROR="$T/naogit"; ok $((RC != 1)) "espelho que o git não lê: recusa 1"; has "$T/err" "não consegui ler worker/"; ok $? "espelho ilegível: 'não consegui ler', não 'o push não chegou'"; nothing_written; ok $? "espelho ilegível: nada escrito"
( cd "$T" && env -i HOME="$T/home" PATH="$BIN:/usr/bin:/bin" BEADS_ACTOR="$ALIAS" GC_SESSION_NAME="$SESS" "$CITY/scripts/gate-done-remote.py" ) > "$T/out" 2> "$T/err"; ok $(( $? != 2 )) "cwd fora da cidade: recusa 2"
cp "$CITY/commands/gate-done.md" "$T/gate-done.md.orig"
python3 -I - "$CITY/commands/gate-done.md" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
i = s.index("## Step 3"); j = s.index("```bash", i); k = s.index("```", j + 8)
open(p, "w").write(s[:j] + "```text" + s[j + 7:k] + "```" + s[k + 3:])   # o bloco do passo 3 deixa de ser bash
EOF
reset_db; run_exe; ok $((RC != 2)) "gate-done.md sem o bloco do passo 3: recusa 2"; has "$T/err" "mudou de forma"; ok $? "md mudou: diz 'mudou de forma'"; nothing_written; ok $? "md mudou: NADA foi empurrado nem escrito"
cp "$T/gate-done.md.orig" "$CITY/commands/gate-done.md"
mv "$CITY/commands/gate-done.md" "$T/gdm.moved"; reset_db; run_exe; ok $((RC != 2)) "gate-done.md ilegível/ausente: recusa 2"; nothing_written; ok $? "md ausente: nada escrito"
mv "$T/gdm.moved" "$CITY/commands/gate-done.md"

# ── 5. restos de execução morta nunca são apagados; trava de instância única ───────────────────────────────────────────────────────────────────────
reset_db; G -C "$OUTER" branch "$BR" "$MAINSHA"; run_exe; ok $((RC != 1)) "branch local de mesmo nome já existe: recusa 1"; has "$T/err" "resto de uma submissão anterior"; ok $? "resto: diz o que recolher"
[ "$(git -C "$OUTER" rev-parse "$BR")" = "$MAINSHA" ]; ok $? "resto: o branch alheio NÃO foi apagado"; nothing_written; ok $? "resto: nada escrito"
git -C "$OUTER" branch -q -D "$BR"
reset_db; mkdir -p "$CITY/.gc/gate-done-remote/wt-ga-t1"; printf 'x\n' > "$CITY/.gc/gate-done-remote/wt-ga-t1/marca"; run_exe; ok $((RC != 1)) "pasta de worktree sobrando: recusa 1"
[ -f "$CITY/.gc/gate-done-remote/wt-ga-t1/marca" ]; ok $? "pasta sobrando: NÃO foi apagada"; ! origin_has "$BR" >/dev/null; ok $? "pasta sobrando: nada empurrado"
rm -f "$CITY/.gc/gate-done-remote/wt-ga-t1/marca"; rmdir "$CITY/.gc/gate-done-remote/wt-ga-t1"
reset_db; python3 -I - "$CITY/.gc/gate-done-remote/ga-t1.lock" <<'EOF' &
import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); print("locked", flush=True); time.sleep(20)
EOF
LOCKPID=$!; for _ in $(seq 1 50); do [ -e "$CITY/.gc/gate-done-remote/ga-t1.lock" ] && break; sleep 0.1; done; sleep 0.5
run_exe; kill $LOCKPID 2>/dev/null; wait $LOCKPID 2>/dev/null
ok $((RC != 1)) "outra submissão da mesma bead em curso: recusa 1"; has "$T/err" "outra submissão de ga-t1 está em curso"; ok $? "trava: diz que há outra em curso"; ! origin_has "$BR" >/dev/null; ok $? "trava: nada empurrado"

# ── 6. falhas no meio: o marcador não nasce, nasce sem submitted_by, ou a bead muda de mão ──────────────────────────────────────────────────────────
reset_db; run_exe FAKE_BD_NOMARKER=1; ok $((RC != 1)) "bd create falha: sai 1"; [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ] && [ "$(dbq '.beads["ga-t1"].metadata | has("gc.routed_to")')" = true ]; ok $? "sem marcador: a bead NÃO foi solta"
clean_after; ok $? "sem marcador: o que a execução criou foi recolhido"; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"
reset_db; run_exe FAKE_BD_NO_SUBMITTED_BY=1; ok $((RC != 0)) "marcador sem gate.submitted_by: a submissão vale (sai 0)"
has "$T/out" "AVISO: não soltei ga-t1"; ok $? "sem submitted_by: AVISO visível de que NÃO soltou"
[ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ] && [ "$(dbq '.beads["ga-t1"].metadata | has("gc.routed_to")')" = true ]; ok $? "sem submitted_by: assignee e rota INTACTOS (soltar mudaria o autor para o criador)"
git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"
reset_db; run_exe FAKE_BD_STEAL=1; ok $((RC != 0)) "bead que mudou de dono no meio: a submissão vale (sai 0)"
[ "$(dbq '.beads["ga-t1"].assignee // ""')" = "outro-dono" ]; ok $? "mudou de dono: o dono novo NÃO foi tirado (sem força)"; has "$T/out" "AVISO: ga-t1 NÃO ficou solta"; ok $? "mudou de dono: AVISO, não 'solta'"
git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"
python3 -I - "$CITY/commands/gate-done.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read(); a = 'echo "Marker created: $MARKER_ID"'; assert a in s
open(p, "w").write(s.replace(a, "true"))
EOF
reset_db; run_exe; ok $((RC != 4)) "script que sai 0 sem 'Marker created': sai 4"; has "$T/err" "NÃO repita às cegas"; ok $? "sem a linha do marcador: avisa para não repetir"
[ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ]; ok $? "sem a linha do marcador: a bead NÃO foi solta"
cp "$T/gate-done.md.orig" "$CITY/commands/gate-done.md"; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"

# ── 7. a cadeia pelo remote-shim-wrapper REAL (ambiente do zero, cwd = cidade, config com gate_done_bin) ───────────────────────────────────────────
WRAP="$HERE/remote-shim-wrapper.py"
printf '{"city": "%s", "identity_pattern": "^(dog-remote(-[A-Za-z0-9]{1,12})?)$", "gate_done_bin": "%s", "log": "%s", "timeout_s": 300, "bin_dirs": ["%s", "/opt/homebrew/bin", "/usr/local/bin"]}\n' \
  "$CITY" "$CITY/scripts/gate-done-remote.py" "$T/shim.log" "$BIN" > "$T/shim.json"
REQ=$(python3 -I -c 'import sys, json, base64
p = json.dumps({"tool": "gate-done", "argv": [], "env": {"GC_ALIAS": sys.argv[1], "GC_AGENT": "dog-remote", "GC_SESSION_NAME": sys.argv[2], "GC_TEMPLATE": "dog-remote"}}, separators=(",", ":"))
print("rs1 " + base64.urlsafe_b64encode(p.encode()).decode().rstrip("="), end="")' "$ALIAS" "$SESS")
reset_db; env -i HOME="$T/home" USER=t PATH=/usr/bin:/bin SSH_ORIGINAL_COMMAND="$REQ" SSH_CLIENT="203.0.113.9 5555 22" \
  python3 -I "$WRAP" serve --config "$T/shim.json" > "$T/out" 2> "$T/err"; RC=$?
ok $((RC != 0)) "pelo wrapper: gate-done sai 0 (antes: 77, gate_done_bin ausente)"
has "$T/out" "Marker created: ga-mk1"; ok $? "pelo wrapper: o marcador foi criado"
[ "$(dbq '.beads["ga-mk1"].metadata["gate.submitted_by"] // ""')" = "$ALIAS" ]; ok $? "pelo wrapper: gate.submitted_by = alias (BEADS_ACTOR chegou ao executável)"
[ "$(origin_has "$BR")" = "$SHA" ]; ok $? "pelo wrapper: o origin recebeu $BR no sha do espelho"
[ -z "$(dbq '.beads["ga-t1"].assignee // ""')" ]; ok $? "pelo wrapper: a bead foi solta"
grep -q "gate-done" "$T/shim.log" && grep -q "done	rc=0\|rc=0" "$T/shim.log"; ok $? "pelo wrapper: a auditoria registra a regra gate-done e rc=0"
clean_after; ok $? "pelo wrapper: nada sobrou"; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"

# ── 8. mutantes: cada guarda apagada tem de reprovar o caso que a prova ───────────────────────────────────────────────────────────────────────────
mutant() {  # mutant NOME 'trecho' 'troca' CASO — CASO é uma função que devolve 0 se o comportamento BOM aparece
  cp -p "$CITY/scripts/gate-done-remote.py" "$T/exe.good"
  python3 -I - "$CITY/scripts/gate-done-remote.py" "$2" "$3" <<'EOF' || { echo "FAIL mutante $1: o trecho não existe mais no executável"; fails=$((fails+1)); n=$((n+1)); return; }
import sys
p, a, b = sys.argv[1:]; s = open(p).read(); assert s.count(a) == 1, "trecho ausente ou repetido"
open(p, "w").write(s.replace(a, b))
EOF
  reset_db; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"; mkdir -p "$T/mut"
  if "$4" >/dev/null 2>&1; then ok 1 "mutante $1 SOBREVIVEU (o caso não pegou)"; else ok 0 "mutante $1 morto"; fi
  cp -p "$T/exe.good" "$CITY/scripts/gate-done-remote.py"
}
case_release_without_who() { run_exe FAKE_BD_NO_SUBMITTED_BY=1; [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ]; }
case_fetch_head() { b=$(ls -l "$OUTER/.git/FETCH_HEAD" 2>&1); run_exe; eqs "$b" "$(ls -l "$OUTER/.git/FETCH_HEAD" 2>&1)"; }
case_md_shape() { python3 -I -c '
import sys; p=sys.argv[1]; s=open(p).read(); i=s.index("## Step 3"); j=s.index("```bash", i); k=s.index("```", j + 8)
open(p, "w").write(s[:j] + "```text" + s[j + 7:k] + "```" + s[k + 3:])' "$CITY/commands/gate-done.md"; run_exe; r=$RC; cp "$T/gate-done.md.orig" "$CITY/commands/gate-done.md"; [ "$r" = 2 ] && ! origin_has "$BR" >/dev/null; }
case_leftover_branch() { G -C "$OUTER" branch "$BR" "$MAINSHA"; run_exe; k=0; has "$T/err" "resto de uma submissão anterior" && k=1; git -C "$OUTER" branch -q -D "$BR" 2>/dev/null; [ "$k" = 1 ]; }
case_cas() { run_exe FAKE_BD_STEAL=1; [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "outro-dono" ]; }
mutant sem-checar-submitted_by 'if not who:' 'if False:' case_release_without_who
mutant fetch-escreve-FETCH_HEAD '"--no-write-fetch-head", ' '' case_fetch_head
mutant md-sem-checar-forma 'if cur is not None or sorted(blocks) != [1, 2, 3, 4] or any(len(v) != 1 for v in blocks.values()):' 'if False:' case_md_shape
mutant branch-alheio-nao-recusado 'or run(["git", "-C", repo, "show-ref", "--verify", "-q", f"refs/heads/{branch}"]).returncode == 0' 'or False' case_leftover_branch
mutant solta-sem-compare-and-swap '"--if-assignee", alias, ' '' case_cas

echo
echo "$((n - fails))/$n ok, $fails falhas"
[ "$fails" = 0 ]
