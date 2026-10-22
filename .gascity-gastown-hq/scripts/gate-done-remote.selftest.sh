#!/usr/bin/env bash
# gate-done-remote.selftest.sh — prova hermética de scripts/gate-done-remote.py (ga-2hd02v.1.13): cidade, origin e espelho FALSOS em tmp, `bd`/`gc` falsos,
# e o commands/gate-done.md DE VERDADE (a fonte única que o executável reaproveita: se ele mudar de forma, este teste quebra). Uma seção final roda a cadeia
# pelo remote-shim-wrapper.py real (ambiente montado do zero, cwd = cidade) e outra mata os mutantes (a seção 11, ga-2hd02v.3.10: o rig WA roda SEM o pre-push que executaria a árvore do nó). Nada toca a cidade nem o origin de verdade.
# ga-2hd02v.1.18: as seções 9 e 9b cobrem `gate-done <bead> <ref> <sha>` (2ª bead da sessão, sha conferido antes do marcador, refs que a sessão não pode submeter) e a volta do gate.
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
with open(T + "/bd.cwd", "a") as f: f.write(os.getcwd() + " " + " ".join(x for x in a[:3] if not x.startswith("/")) + "\n")   # onde a chamada rodou (o cwd do `create` do marcador é o do worktree)
if a[:1] == ["-C"]:
    if os.path.realpath(a[1]) == os.path.realpath(T + "/rigs/property_scrapers"): db_path = T + "/db-ps.json"   # a loja do rig PS (ga-2hd02v.4); qualquer outro -C é a da cidade
    if os.path.realpath(a[1]) == os.path.realpath(T + "/rigs/whatsapp_automation"): db_path = T + "/db-wa.json"   # a loja do rig WA (ga-2hd02v.3.10)
    a = a[2:]
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
    if not st and "--all" not in a: rows = [b for b in rows if b["status"] != "closed"]  # como o bd de verdade: sem --all (e sem --status) as fechadas somem, e o gate FECHA os marcadores
    print(json.dumps(rows)); sys.exit(0)
if cmd == "show":
    i = [x for x in a[1:] if not x.startswith("-")][0]
    if i not in beads: sys.stderr.write("not found\n"); sys.exit(1)
    if env("FAKE_BD_BADJSON") == "show:" + i: print("{nao e json"); sys.exit(0)
    if env("FAKE_BD_SHOW_EMPTY_AFTER_UPDATE") == i and any((" update " + i + " ") in (" " + l) for l in open(T + "/bd.log")): print("[]"); sys.exit(0)   # a releitura depois da soltura volta vazia
    if env("FAKE_BD_SHOW_OTHER_AFTER_UPDATE") == i and any((" update " + i + " ") in (" " + l) for l in open(T + "/bd.log")): print(json.dumps([{"id": "ps-outra", "status": "in_progress", "labels": [], "metadata": {}}])); sys.exit(0)   # a releitura devolve OUTRA bead (sem dono nem rota)
    print(json.dumps([beads[i]]) if "--json" in a else i); sys.exit(0)
if cmd == "create":
    if env("FAKE_BD_NOMARKER"): sys.exit(1)
    db["n"] += 1; mid = "ga-mk%d" % db["n"]
    beads[mid] = {"id": mid, "title": a[1], "status": "open", "labels": multi("-l"), "description": flag("-d"), "metadata": {}, "issue_type": "chore", "created_at": "2026-10-19T20:00:%02dZ" % db["n"]}
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
        if not (env("FAKE_BD_KEEP_MARK") and k == "pilot.wa_node_alias"): b["metadata"].pop(k, None)
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
if "rig" in a and "list" in a:
    t = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    print(json.dumps({"rigs": [{"name": "gascity", "path": t + "/outer/city", "prefix": "ga"}, {"name": "property_scrapers", "path": t + "/rigs/property_scrapers", "prefix": "ps"}, {"name": "whatsapp_automation", "path": t + "/rigs/whatsapp_automation", "prefix": "wa"}]})); sys.exit(0)
sys.stderr.write("fake gc: comando nao previsto: %s\n" % a); sys.exit(64)
EOF
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<GITEOF
#!/bin/sh
echo "cfg=\${GIT_CONFIG_COUNT:-UNSET}" >> "$T/git.log"
case " \$* " in *" \${FAKE_GIT_FAIL:-@@nenhum@@} "*) echo "fake git: \$FAKE_GIT_FAIL falhou" >&2; exit 128;; esac
exec "$REAL_GIT" "\$@"
GITEOF
chmod +x "$BIN/bd" "$BIN/gc" "$BIN/git"

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
  rm -f "$T/db-ps.json" "$T/db-wa.json"
  : > "$BDLOG"; : > "$T/bd.cwd"
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
[ -s "$T/git.log" ] && ! grep -qv '^cfg=2$' "$T/git.log"; ok $? "feliz: TODO git da submissão (exe e blocos do gate-done.md) leva gc.auto/maintenance.auto desligados"
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
reset_db; run_exe FAKE_GIT_FAIL=for-each-ref; ok $((RC != 1)) "git que FALHA ao listar branches locais: recusa 1"; has "$T/err" "não consegui listar os branches locais"; ok $? "listar falhou: 'não consegui', não 'nenhum resto'"; nothing_written; ok $? "listar falhou: nada escrito"
reset_db; run_exe FAKE_GIT_FAIL=fetch; ok $((RC != 1)) "git fetch do espelho que falha: recusa 1"; has "$T/err" "não consegui buscar worker/"; ok $? "fetch falhou: diz o motivo"; nothing_written; ok $? "fetch falhou: nada escrito"; clean_after; ok $? "fetch falhou: nada sobrou"
reset_db; run_exe FAKE_GIT_FAIL=worktree; ok $((RC != 1)) "git worktree add que falha: recusa 1"; has "$T/err" "não consegui criar o worktree"; ok $? "worktree falhou: diz o motivo"; nothing_written; ok $? "worktree falhou: nada escrito"; clean_after; ok $? "worktree falhou: a ref temporária foi recolhida"
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

# ── 9. `gate-done <bead> <ref> <sha>` (ga-2hd02v.1.18): a 2ª bead da sessão sai do ref que o dog diz, com o sha conferido ANTES do marcador ─────────────
db_edit() {  # db_edit 'código python sobre d (o banco falso)'
  python3 -I - "$DB" "$1" <<'EOF'
import json, sys
p, code = sys.argv[1:]
d = json.load(open(p))
exec(code)
json.dump(d, open(p, "w"))
EOF
}
run_exe_a() {  # run_exe_a [VAR=valor ...] -- arg... → RC, $T/out, $T/err: a forma com argumentos, no mesmo ambiente do run_exe
  envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; [ $# -gt 0 ] && shift
  ( cd "$CITY" && env -i HOME="$T/home" USER=t LOGNAME=t LANG=en_US.UTF-8 PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      BEADS_ACTOR="$ALIAS" GC_ALIAS="$ALIAS" GC_SESSION_NAME="$SESS" GC_TEMPLATE=dog-remote ${envs[@]+"${envs[@]}"} \
      "$CITY/scripts/gate-done-remote.py" "$@" ) > "$T/out" 2> "$T/err"; RC=$?
}
mk_work() {  # mk_work ARQUIVO REF [BASE] → NEWSHA: um commit novo (filho de BASE, padrão main), empurrado ao espelho em refs/heads/REF
  G -C "$OUTER" checkout -q -b work-tmp "${3:-main}" && printf '%s\n' "$1" > "$CITY/$1" && G -C "$OUTER" add "city/$1" >/dev/null && G -C "$OUTER" commit -qm "feat: $1" \
    && NEWSHA=$(git -C "$OUTER" rev-parse HEAD) && git -C "$OUTER" push -q -f "$MIRROR" "HEAD:refs/heads/$2"
  r=$?; G -C "$OUTER" checkout -q main; git -C "$OUTER" branch -q -D work-tmp; return $r
}
BR2="fix/ga-t2-segunda-bead-da-sessao"
reset_db2() {  # ga-t1 e ga-t2, as duas in_progress com o alias (a 2ª bead da mesma sessão); o origin sem o branch da ga-t2
  reset_db; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR2" 2>/dev/null
  db_edit 'd["beads"]["ga-t2"] = dict(d["beads"]["ga-t1"], id="ga-t2", title="Segunda bead da sessao")'
}
clean_after2() {  # clean_after2 BEAD BRANCH — nada do que a execução criou sobra
  [ ! -e "$CITY/.gc/gate-done-remote/wt-$1" ] && ! git -C "$OUTER" show-ref -q --verify "refs/heads/$2" && [ -z "$(git -C "$OUTER" for-each-ref refs/gt-remote)" ] \
    && [ "$(git -C "$OUTER" worktree list | wc -l | tr -d ' ')" = 1 ]
}
mk_work seg.txt "worker/$SESS-2"; SHAB=$NEWSHA
reset_db2; run_exe_a -- ga-t2 "worker/$SESS-2" "$SHAB"
ok $((RC != 0)) "2ª bead: gate-done ga-t2 worker/<sessão>-2 <sha> sai 0 (as duas beads do alias estão in_progress)"
[ "$(origin_has "$BR2")" = "$SHAB" ]; ok $? "2ª bead: o origin tem $BR2 no sha de worker/<sessão>-2 (fix/<bead>-…, não worker/…)"
[ "$(dbq '[.beads[] | select((.labels // []) | index("source-bead:ga-t2"))] | length')" = 1 ]; ok $? "2ª bead: UM marcador, o da ga-t2"
[ -z "$(dbq '.beads["ga-t2"].assignee // ""')" ] && [ "$(dbq '.beads["ga-t2"].metadata | has("gc.routed_to")')" = false ]; ok $? "2ª bead: a ga-t2 foi solta"
[ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ] && [ "$(dbq '.beads["ga-t1"].metadata | has("gc.routed_to")')" = true ]; ok $? "2ª bead: a ga-t1 (a 1ª) NÃO foi tocada"
has "$T/out" "submetido: $BR2 @ $SHAB"; ok $? "2ª bead: a saída imprime o sha submetido"
clean_after2 ga-t2 "$BR2"; ok $? "2ª bead: worktree, branch local e ref temporária foram recolhidos"
reset_db2; run_exe_a -- ga-t2 "refs/heads/worker/$SESS-2" "$SHAB"
ok $((RC != 0)) "ref escrito com refs/heads/: aceito, mesmo caminho"
# sha que não é o do espelho: recusa ANTES do marcador, dizendo os dois
reset_db2; run_exe_a -- ga-t2 "worker/$SESS-2" "$SHA"
ok $((RC != 1)) "sha que não é o do espelho: recusa 1"; has "$T/err" "o espelho tem ${SHAB:0:12}"; ok $? "sha errado: diz o que o espelho tem"
has "$T/err" "você disse ${SHA:0:12}"; ok $? "sha errado: diz o que o dog disse"
[ "$(mut_count)" = 0 ] && ! origin_has "$BR2" >/dev/null; ok $? "sha errado: nada escrito (nem marcador, nem branch no origin)"
# refs que a sessão não pode submeter: outra sessão (inclusive uma cujo nome COMEÇA com o da minha), sufixo que não é número, fix/ de outra bead, tag
mk_work alheio.txt "worker/${SESS}4"; SHAX=$NEWSHA
for bad in "worker/${SESS}4" "worker/$SESS-x" "worker/dog-remote-zzz999-2" "fix/ga-t1-de-outra-bead" "refs/heads/worker/${SESS}4" "refs/tags/x"; do
  reset_db2; run_exe_a -- ga-t2 "$bad" "$SHAX"
  ok $((RC != 1)) "ref $bad: recusa 1"; has "$T/err" "fora do que esta sessão pode submeter"; ok $? "ref $bad: diz que está fora do que a sessão pode submeter"
  [ "$(mut_count)" = 0 ] && ! origin_has "$BR2" >/dev/null; ok $? "ref $bad: nada escrito"
done
git --git-dir="$MIRROR" update-ref -d "refs/heads/worker/${SESS}4"
# o dog empurrou fix/<bead>-<resumo>: o branch do origin leva o NOME que ele deu, não o do título
mk_work seg2.txt "fix/ga-t2-meu-resumo"; SHAF=$NEWSHA
reset_db2; run_exe_a -- ga-t2 "fix/ga-t2-meu-resumo" "$SHAF"
ok $((RC != 0)) "fix/<bead>-<resumo>: sai 0"
[ "$(origin_has "fix/ga-t2-meu-resumo")" = "$SHAF" ] && ! origin_has "$BR2" >/dev/null; ok $? "fix/<bead>-<resumo>: o origin leva o nome que o dog deu (não o do título)"
git --git-dir="$ORIGIN" update-ref -d "refs/heads/fix/ga-t2-meu-resumo"; git --git-dir="$MIRROR" update-ref -d "refs/heads/fix/ga-t2-meu-resumo"; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR2" 2>/dev/null

# ── 9b. volta do gate (caso B): sem assignee + gate:needs-fix + rota gastown.dog (a que o gate RESTAURA) ou dog-remote; vale se a ÚLTIMA entrega foi deste alias ──
BRB="fix/ga-t2-volta-do-gate"
seed_back() {  # seed_back AUTOR SUBMITTED_BY [STATUS] [ASSIGNEE] [LABELS,] [ROTA]: a ga-t2 volta do gate COMO O GATE A DEIXA (rota gastown.dog, medida em ga-9636op, .1.12 e .1.18); marcador antigo MEU e o mais novo do AUTOR dado, os dois FECHADOS
  reset_db; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BRB" 2>/dev/null
  python3 -I - "$DB" "$ALIAS" "$1" "$2" "${3-open}" "${4-}" "${5-gate:needs-fix,gate:fix-attempt:1}" "${6-gastown.dog}" <<'EOF'
import json, sys
p, me, author, by, status, assignee, labels, route = sys.argv[1:]
d = json.load(open(p))
d["beads"]["ga-t2"] = {"id": "ga-t2", "title": "Volta do gate", "status": status, "assignee": assignee, "issue_type": "bug", "created_by": "gastown.mayor",
                       "labels": labels.split(",") if labels else [], "metadata": ({"gc.routed_to": route} if route else {})}
def mk(i, ts, a, b):
    d["beads"][i] = {"id": i, "title": "ready-for-gate: x", "status": "closed", "issue_type": "chore", "created_at": ts,
                     "labels": ["type:quality-gate-marker", "source-bead:ga-t2", "gate-status:failed"],
                     "description": "branch: x\nbead_id: ga-t2\nauthor: " + a + "\nbase_commit: y\n", "metadata": {"gate.submitted_by": b}}
mk("ga-mkold", "2026-10-19T10:00:00Z", me, me)
mk("ga-mknew", "2026-10-19T11:00:00Z", author, by)
json.dump(d, open(p, "w"))
EOF
}
back_refused() {  # back_refused DESCRIÇÃO FRAGMENTO: recusa 1, diz o motivo e nada foi escrito
  ok $((RC != 1)) "$1: recusa 1"; has "$T/err" "$2"; ok $? "$1: diz o motivo ($2)"
  [ "$(mut_count)" = 0 ] && ! origin_has "$BRB" >/dev/null; ok $? "$1: nada escrito"
}
mk_work volta.txt "$BRB"; SHAV=$NEWSHA
for combo in "$ALIAS:$ALIAS" "gastown.mayor:$ALIAS" "$ALIAS:gastown.mayor"; do   # autor e submitted_by; o Mayor submeteu à mão (só submitted_by); 2ª volta (só author: submitted_by cai no criador)
  seed_back "${combo%%:*}" "${combo##*:}"; run_exe_a -- ga-t2 "$BRB" "$SHAV"
  ok $((RC != 0)) "volta do gate (autor=${combo%%:*}, submitted_by=${combo##*:}): sai 0"
  [ "$(origin_has "$BRB")" = "$SHAV" ]; ok $? "volta do gate ($combo): o origin tem $BRB no sha dito"
  [ "$(dbq '[.beads[] | select((.labels // []) | index("source-bead:ga-t2"))] | length')" = 3 ]; ok $? "volta do gate ($combo): UM marcador novo (3 com os 2 antigos)"
  dbq '.beads["ga-mk1"].description' | grep -qF -- "author: $ALIAS"; ok $? "volta do gate ($combo): o marcador novo leva author: alias (a próxima volta ainda prova a autoria)"
  has "$T/out" "bead solta: ga-t2"; ok $? "volta do gate ($combo): a bead foi solta"
  [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ]; ok $? "volta do gate ($combo): a ga-t1 não foi tocada"
  git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BRB"
done
seed_back outro-dog outro-dog; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "volta do gate cuja ÚLTIMA entrega é de outro alias (a antiga é minha: vale a mais nova)" "não foi de $ALIAS"
seed_back "$ALIAS" "$ALIAS"; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [d["beads"].pop(k) for k in ("ga-mkold","ga-mknew")]; json.dump(d,open(sys.argv[1],"w"))' "$DB"
run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "volta do gate sem nenhum marcador (nunca entregue)" "nunca foi entregue"
seed_back "$ALIAS" "$ALIAS"; run_exe_a FAKE_BD_FAIL=list -- ga-t2 "$BRB" "$SHAV"; back_refused "leitura dos marcadores que FALHA (não é 'sem marcador')" "não consegui ler os marcadores"
seed_back "$ALIAS" "$ALIAS"; run_exe_a FAKE_BD_BADJSON=list -- ga-t2 "$BRB" "$SHAV"; back_refused "marcadores com JSON corrompido" "ilegível"
seed_back "$ALIAS" "$ALIAS" open "" "gate:queued"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "sem gate:needs-fix (na fila do gate, não voltou)" "nem uma volta do gate"
seed_back "$ALIAS" "$ALIAS" open "" "gate:needs-fix" ""; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "sem rota nenhuma (não sei de que pool é a bead)" "nem uma volta do gate"
seed_back "$ALIAS" "$ALIAS" open "" "gate:needs-fix" "wa-worker"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "rota de OUTRO pool (nem gastown.dog nem dog-remote), mesmo com a última entrega minha" "nem uma volta do gate"
has "$T/err" "achei 'wa-worker'"; ok $? "rota de outro pool: a recusa diz a rota que achou"
seed_back "$ALIAS" "$ALIAS" open "" "gate:needs-fix" "dog-remote"; run_exe_a -- ga-t2 "$BRB" "$SHAV"   # a rota posta à mão (a descrição da ga-2hd02v.1.18) continua valendo
ok $((RC != 0)) "volta do gate com a rota dog-remote: sai 0"; [ "$(origin_has "$BRB")" = "$SHAV" ]; ok $? "volta do gate com a rota dog-remote: o origin tem $BRB no sha dito"
git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BRB"
seed_back "$ALIAS" "$ALIAS" open "outro-dog"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "bead de outro alias, mesmo com gate:needs-fix" "nem uma volta do gate"
seed_back "$ALIAS" "$ALIAS" closed; run_exe_a -- ga-t2 "$BRB" "$SHAV"; back_refused "bead fechada" "nem uma volta do gate"
# `worker/<sessão>-N` só é inequívoco se `<sessão>-N` NÃO for ele mesmo um nome de sessão. Premissa lida do IDENTITY_PATTERN do runbook (a linha que o wrapper de produção usa):
# hoje só os nomes SEM cauda colidem; se alguém alargar o padrão, este caso quebra e manda rever BARE_ROLE_RE
COLL=$(python3 -I - "$HQ/docs/runbooks/gc-session-ssh.md" <<'EOF'
import re, sys
rx = re.compile(re.search(r"^IDENTITY_PATTERN=(.*)$", open(sys.argv[1], encoding="utf-8").read(), re.M).group(1))
roles = ["dog-remote", "gate-reviewer-remote", "wa-worker-remote", "ps-worker-remote"]
names = ["remote-e2e-1"] + roles + [f"{r}-{t}" for r in roles for t in ("1", "12", "123", "abc", "gawisp1ryjj", "adhoc-0fc28155dd")]
print(" ".join(x for x in names if rx.fullmatch(x) and any(rx.fullmatch(f"{x}-{n}") for n in ("1", "12", "123"))))
EOF
)
eqs "$COLL" "dog-remote gate-reviewer-remote wa-worker-remote ps-worker-remote"; ok $? "ambiguidade do -N: só os nomes sem cauda colidem pelo IDENTITY_PATTERN do runbook (achei: '$COLL')"
for x in $COLL; do
  reset_db2; run_exe_a GC_SESSION_NAME="$x" GC_ALIAS="$x-1" BEADS_ACTOR="$x-1" -- ga-t2 "worker/$x-2" "$SHA"   # alias do MESMO papel da sessão (senão a identidade mista recusa antes)
  ok $((RC != 1)) "sessão sem cauda '$x' com worker/$x-2: recusa 1"; has "$T/err" "branch principal de OUTRA sessão"; ok $? "'$x': diz que worker/$x-2 pode ser de OUTRA sessão"
  [ "$(mut_count)" = 0 ]; ok $? "'$x': nada escrito"
done
reset_db2; run_exe_a GC_SESSION_NAME=dog-remote -- ga-t2 "fix/ga-t2-meu-resumo" "$SHA"
! has "$T/err" "branch principal de OUTRA sessão"; ok $? "sessão sem cauda com fix/<bead>-<resumo>: a guarda do -N não se aplica (o ref leva o id da bead)"


# ── 10. outros rigs (ga-2hd02v.4): a tabela RIGS. Sessão ps-worker-remote-* submete bead ps-… da loja do rig property_scrapers, com o espelho property_scrapers.git e o worktree SOB o rig ────────
PSORIGIN="$T/ps-origin.git"; PSRIG="$T/rigs/property_scrapers"; PSMIRROR="$CITY/.gc/hetzner-mirror/repos/property_scrapers.git"; PSDB="$T/db-ps.json"
PSSESS="ps-worker-remote-abc123"; PSALIAS="ps-worker-remote-1"; PSBR="fix/ps-t1-ps-remoto-teste"; PSBR2="fix/ps-t2-segunda-do-ps"; PSW="$T/ps-work"
mkdir -p "$T/rigs" "$CITY/.beads"
printf '{"prefix":"ga","path":"."}\n{"prefix":"ps","path":"../../rigs/property_scrapers"}\n' > "$CITY/.beads/routes.jsonl"
git init -q --bare -b main "$PSORIGIN"; git clone -q "$PSORIGIN" "$PSW" 2>/dev/null
mkdir -p "$PSW/lib"; printf 'x = 1\n' > "$PSW/lib/x.py"; G -C "$PSW" add lib >/dev/null && G -C "$PSW" commit -qm "base" && G -C "$PSW" push -q origin HEAD:main 2>/dev/null
# o rig como o de verdade: pasta-contêiner com `.git` → `.repo.git` (bare), com o refspec do origin
mkdir -p "$PSRIG"; git clone -q --bare "$PSORIGIN" "$PSRIG/.repo.git"; printf 'gitdir: %s\n' "$PSRIG/.repo.git" > "$PSRIG/.git"
git --git-dir="$PSRIG/.repo.git" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git --git-dir="$PSRIG/.repo.git" fetch -q origin 2>/dev/null
git clone -q --bare "$PSORIGIN" "$PSMIRROR"
ps_work() {  # ps_work ARQUIVO REF → NEWSHA: commit novo em cima de main, empurrado ao espelho do PS em refs/heads/REF
  G -C "$PSW" checkout -q -b work-tmp main && printf 'v = 1\n' > "$PSW/lib/$1" && G -C "$PSW" add "lib/$1" >/dev/null && G -C "$PSW" commit -qm "feat(ps): $1" \
    && NEWSHA=$(git -C "$PSW" rev-parse HEAD) && git -C "$PSW" push -q -f "$PSMIRROR" "HEAD:refs/heads/$2"
  r=$?; G -C "$PSW" checkout -q main; git -C "$PSW" branch -q -D work-tmp; return $r
}
ps_work y.py "worker/$PSSESS"; PSSHA=$NEWSHA
ps_work z.py "worker/$PSSESS-2"; PSSHA2=$NEWSHA
reset_ps() {  # reset_ps: ps-t1 do alias PS na loja do rig (rota do nó); a loja da cidade com a ga-t1 do dog (para provar que uma não enxerga a outra)
  reset_db; git --git-dir="$PSORIGIN" update-ref -d "refs/heads/$PSBR" 2>/dev/null; git --git-dir="$PSORIGIN" update-ref -d "refs/heads/$PSBR2" 2>/dev/null
  python3 -I - "$PSDB" "$PSALIAS" <<'EOF'
import json, sys
p, alias = sys.argv[1:]
json.dump({"n": 0, "beads": {"ps-t1": {"id": "ps-t1", "title": "PS remoto: teste", "status": "in_progress", "assignee": alias, "issue_type": "bug",
           "labels": ["story:approved"], "metadata": {"gc.routed_to": "ps-worker-remote", "pilot.wa_node_alias": alias}, "created_by": "gastown.mayor", "owner": "x@y"}}}, open(p, "w"))
EOF
}
psq() { jq -r "$1" "$PSDB"; }
run_ps() {  # run_ps [VAR=valor ...] [-- arg...] → RC, $T/out, $T/err (sessão ps-worker-remote)
  envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; [ $# -gt 0 ] && shift
  ( cd "$CITY" && env -i HOME="$T/home" USER=t LOGNAME=t LANG=en_US.UTF-8 PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      BEADS_ACTOR="$PSALIAS" GC_ALIAS="$PSALIAS" GC_SESSION_NAME="$PSSESS" GC_TEMPLATE=ps-worker-remote ${envs[@]+"${envs[@]}"} \
      "$CITY/scripts/gate-done-remote.py" "$@" ) > "$T/out" 2> "$T/err"; RC=$?
}
ps_origin_has() { git --git-dir="$PSORIGIN" rev-parse --verify -q "refs/heads/$1" 2>/dev/null; }
ps_clean() {  # nada do que a execução criou sobra, nem no rig nem na cidade
  [ ! -e "$PSRIG/.gc-worktrees/gate-done-remote/wt-ps-t1" ] && [ ! -e "$CITY/.gc/gate-done-remote/wt-ps-t1" ] && ! git --git-dir="$PSRIG/.repo.git" show-ref -q --verify "refs/heads/$PSBR" \
    && [ -z "$(git --git-dir="$PSRIG/.repo.git" for-each-ref refs/gt-remote)" ] && [ "$(git -C "$PSRIG" worktree list | wc -l | tr -d ' ')" = 1 ]
}
ps_nothing() { [ "$(mut_count)" = 0 ] && ! ps_origin_has "$PSBR" >/dev/null && ! ps_origin_has "$PSBR2" >/dev/null; }
# ensaio
reset_ps; run_ps GATE_DONE_REMOTE_DRY_RUN=1
ok $((RC != 0)) "PS ensaio: sai 0"; has "$T/out" "bead=ps-t1 worker/$PSSESS@${PSSHA:0:12} → $PSBR"; ok $? "PS ensaio: diz alias, bead (da loja do rig), sha e branch"
ps_nothing; ok $? "PS ensaio: nada foi escrito nem empurrado"; [ ! -e "$PSRIG/.gc-worktrees/gate-done-remote" ]; ok $? "PS ensaio: nem a pasta de worktree do rig foi criada"
# caminho feliz (forma sem argumento: a ÚNICA bead in_progress do alias NA LOJA DO RIG; a ga-t1 do dog na loja da cidade não conta)
reset_ps; run_ps
ok $((RC != 0)) "PS feliz: sai 0 (a ga-t1 do dog na loja da cidade não atrapalha: cada papel olha a loja do seu rig)"
[ "$(ps_origin_has "$PSBR")" = "$PSSHA" ]; ok $? "PS feliz: o origin do PS tem $PSBR no sha do espelho do PS"
! origin_has "$PSBR" >/dev/null; ok $? "PS feliz: o origin do HQ NÃO recebeu o branch do PS"
has "$T/out" "Marker created: ga-mk1"; ok $? "PS feliz: o marcador foi criado (na loja da CIDADE, onde o gate o lê)"
[ "$(dbq '.beads["ga-mk1"].metadata["gate.submitted_by"] // ""')" = "$PSALIAS" ]; ok $? "PS feliz: gate.submitted_by = alias do PS"
[ "$(dbq '[.beads["ga-mk1"].labels[] | select(startswith("source-bead:") or startswith("bead-rig:") or startswith("branch:"))] | sort | join(",")')" = "bead-rig:property_scrapers,branch:$PSBR,source-bead:ps-t1" ]; ok $? "PS feliz: o marcador leva source-bead:ps-t1, bead-rig:property_scrapers e o branch"
grep -qF "$PSRIG/.gc-worktrees/gate-done-remote/wt-ps-t1 -C create" "$T/bd.cwd"; ok $? "PS feliz: o marcador foi criado de DENTRO do worktree sob o caminho do rig ($PSRIG/.gc-worktrees/gate-done-remote)"
dbq '.beads["ga-mk1"].description' | grep -qF -- "rig: property_scrapers"; ok $? "PS feliz: rig: property_scrapers na descrição (o worktree está SOB o caminho do rig, e o gate-done.md acha o rig por ele)"
dbq '.beads["ga-mk1"].description' | grep -qF -- "bead_rig: property_scrapers"; ok $? "PS feliz: bead_rig: property_scrapers (a bead foi achada na loja do rig)"
[ "$(psq '.beads["ps-t1"].labels | index("gate:queued") != null')" = true ]; ok $? "PS feliz: gate:queued na bead, NA LOJA DO RIG"
[ -z "$(psq '.beads["ps-t1"].assignee // ""')" ] && [ "$(psq '.beads["ps-t1"].metadata | has("gc.routed_to")')" = false ] && [ "$(psq '.beads["ps-t1"].metadata | has("pilot.wa_node_alias")')" = false ]; ok $? "PS feliz: a bead foi SOLTA na loja do rig (sem assignee, sem rota e sem a marca do nó)"
[ "$(dbq '.beads["ga-t1"].assignee // ""')" = "$ALIAS" ]; ok $? "PS feliz: a ga-t1 do dog (loja da cidade) NÃO foi tocada"
has "$T/out" "bead solta: ps-t1"; ok $? "PS feliz: a saída diz que soltou"; has "$T/out" "submetido: $PSBR @ $PSSHA"; ok $? "PS feliz: a saída imprime o sha submetido"
ps_clean; ok $? "PS feliz: worktree, branch local e ref temporária foram recolhidos (no rig e na cidade)"
[ "$(git --git-dir="$PSRIG/.repo.git" rev-parse main)" = "$(git --git-dir="$PSORIGIN" rev-parse main)" ]; ok $? "PS feliz: o main do rig não mudou"
# leitura vazia do bd depois da soltura: NÃO é sucesso (não digo 'bead solta' sem ter lido a bead)
reset_ps; run_ps FAKE_BD_SHOW_EMPTY_AFTER_UPDATE=ps-t1; ok $((RC != 0)) "PS releitura vazia do bd: a submissão vale (sai 0)"; has "$T/out" "NÃO ficou solta (resta ?"; ok $? "PS releitura vazia: AVISO 'NÃO ficou solta (resta ?', e NÃO 'bead solta'"; ! has "$T/out" "bead solta: ps-t1"; ok $? "PS releitura vazia: não diz 'bead solta'"
reset_ps; run_ps FAKE_BD_SHOW_OTHER_AFTER_UPDATE=ps-t1; ok $((RC != 0)) "PS releitura devolve OUTRA bead: a submissão vale (sai 0)"; has "$T/out" "NÃO ficou solta (resta ?"; ok $? "PS releitura de outra bead: AVISO, não 'solta' (uma bead sem dono nem rota que não é a minha não prova nada)"
# a soltura confere TAMBÉM a marca do nó: se o bd não a tirou, o aviso diz (a bead não fica "solta" por engano)
reset_ps; run_ps FAKE_BD_KEEP_MARK=1; ok $((RC != 0)) "PS marca do nó que o bd não tirou: a submissão vale (sai 0)"; has "$T/out" "NÃO ficou solta (resta pilot.wa_node_alias"; ok $? "PS marca do nó que ficou: AVISO diz que a bead NÃO ficou solta e o que resta"
# forma com argumentos (2ª bead da sessão) e prefixo
reset_ps; python3 -I - "$PSDB" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["beads"]["ps-t2"] = dict(d["beads"]["ps-t1"], id="ps-t2", title="Segunda do PS"); json.dump(d, open(sys.argv[1], "w"))
EOF
run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"
ok $((RC != 0)) "PS 2ª bead: gate-done ps-t2 worker/<sessão>-2 <sha> sai 0"; [ "$(ps_origin_has "$PSBR2")" = "$PSSHA2" ]; ok $? "PS 2ª bead: o origin do PS tem $PSBR2 no sha dito"
[ "$(psq '.beads["ps-t1"].assignee // ""')" = "$PSALIAS" ]; ok $? "PS 2ª bead: a ps-t1 (a outra) NÃO foi tocada"
reset_ps; run_ps
ok $((RC != 0)) "PS: forma sem argumento com duas beads do alias NA LOJA do rig recusa" || true
reset_ps; python3 -I - "$PSDB" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["beads"]["ps-t2"] = dict(d["beads"]["ps-t1"], id="ps-t2"); json.dump(d, open(sys.argv[1], "w"))
EOF
run_ps; ok $((RC != 1)) "PS: duas beads do alias na loja do rig: recusa 1"; has "$T/err" "não adivinho"; ok $? "PS duas beads: diz que não adivinha"; ps_nothing; ok $? "PS duas beads: nada escrito"
# nome de sessão que não é de nenhum papel (gate-reviewer-remote, nome de teste) vale como o HQ — o comportamento de antes da tabela
mk_work unk.txt "worker/remote-e2e-1"; SHAU=$NEWSHA
reset_ps; run_exe GC_SESSION_NAME=remote-e2e-1 GATE_DONE_REMOTE_DRY_RUN=1
ok $((RC != 0)) "papel desconhecido (remote-e2e-1): sai 0 e trata como o rig do HQ"; has "$T/out" "bead=ga-t1 worker/remote-e2e-1@${SHAU:0:12}"; ok $? "papel desconhecido: a bead é a ga-t1 da loja da cidade"
# identidade mista (o identity_pattern do atalho é global): alias de um papel com sessão de outro = recusa 2 antes de ler qualquer bead
reset_ps; run_ps GC_ALIAS="$ALIAS" BEADS_ACTOR="$ALIAS"; ok $((RC != 2)) "PS identidade mista (alias dog-remote-1, sessão ps-worker-remote-…): recusa 2"; has "$T/err" "identidade mista"; ok $? "identidade mista: diz o motivo"; ps_nothing; ok $? "identidade mista: nada escrito"
reset_ps; run_exe GC_ALIAS="$PSALIAS" BEADS_ACTOR="$PSALIAS"; ok $((RC != 2)) "HQ identidade mista (alias ps-worker-remote-1, sessão dog-remote-…): recusa 2"; has "$T/err" "identidade mista"; ok $? "HQ identidade mista: diz o motivo"; ps_nothing; ok $? "HQ identidade mista: nada escrito"
# o papel da sessão limita o rig: ps-worker-remote com bead ga-…, dog-remote com bead ps-…
reset_ps; run_ps -- ga-t1 "worker/$PSSESS" "$PSSHA"; ok $((RC != 1)) "PS sessão com bead ga-…: recusa 1"; has "$T/err" "é de outro prefixo (ga)"; ok $? "PS sessão com bead ga-…: diz que é de outro prefixo"; ps_nothing; ok $? "PS sessão com bead ga-…: nada escrito"
reset_ps; run_exe_a -- ps-t1 "worker/$SESS" "$SHA"; ok $((RC != 1)) "dog-remote com bead ps-…: recusa 1"; has "$T/err" "é de outro prefixo (ps)"; ok $? "dog-remote com bead ps-…: diz que é de outro prefixo"; ps_nothing; ok $? "dog-remote com bead ps-…: nada escrito"
reset_ps; run_ps GC_SESSION_NAME=wa-worker-remote-abc123 GC_ALIAS=wa-worker-remote-1 BEADS_ACTOR=wa-worker-remote-1; ok $((RC != 1)) "wa-worker-remote: rig sem rota na routes.jsonl: recusa 1"; has "$T/err" "não achei a rota do prefixo 'wa'"; ok $? "wa-worker-remote sem rota: diz que não achou a rota"; ps_nothing; ok $? "wa-worker-remote sem rota: nada escrito"
# volta do gate no PS: a rota restaurada pelo gate é ps-worker (a do pool do mini) ou ps-worker-remote; gastown.dog NÃO é rota de volta do PS
seed_ps_back() {  # seed_ps_back ROTA: ps-t2 volta do gate (sem dono, gate:needs-fix) com marcador antigo MEU
  reset_ps; python3 -I - "$PSDB" "$DB" "$PSALIAS" "$1" <<'EOF'
import json, sys
pp, hp, me, route = sys.argv[1:]
d = json.load(open(pp)); d["beads"]["ps-t2"] = {"id": "ps-t2", "title": "Segunda do PS", "status": "open", "assignee": "", "issue_type": "bug", "created_by": "gastown.mayor",
    "labels": ["gate:needs-fix", "gate:fix-attempt:1"], "metadata": ({"gc.routed_to": route} if route else {})}
json.dump(d, open(pp, "w"))
h = json.load(open(hp)); h["beads"]["ga-mkps"] = {"id": "ga-mkps", "title": "ready-for-gate: x", "status": "closed", "issue_type": "chore", "created_at": "2026-10-19T11:00:00Z",
    "labels": ["type:quality-gate-marker", "source-bead:ps-t2", "gate-status:failed"], "description": "branch: x\nbead_id: ps-t2\nauthor: " + me + "\nbase_commit: y\n", "metadata": {"gate.submitted_by": me}}
json.dump(h, open(hp, "w"))
EOF
}
seed_ps_back ps-worker; run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"
ok $((RC != 0)) "PS volta do gate com a rota ps-worker (a que o gate restaura): sai 0"; [ "$(ps_origin_has "$PSBR2")" = "$PSSHA2" ]; ok $? "PS volta do gate: o origin do PS tem $PSBR2"
has "$T/out" "bead solta: ps-t2"; ok $? "PS volta do gate: a bead foi solta"
seed_ps_back ps-worker-remote; run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"; ok $((RC != 0)) "PS volta do gate com a rota ps-worker-remote (à mão): sai 0"
seed_ps_back gastown.dog; run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"
ok $((RC != 1)) "PS volta do gate com a rota gastown.dog (do HQ): recusa 1"; has "$T/err" "achei 'gastown.dog'"; ok $? "PS rota do HQ: a recusa diz a rota que achou"; ps_nothing; ok $? "PS rota do HQ: nada escrito"
# a rota (routes.jsonl) e o espelho: ausente/ilegível/apontando para a pasta errada = recusa sem escrever
reset_ps; cp "$CITY/.beads/routes.jsonl" "$T/routes.orig"
printf '{"prefix":"ga","path":"."}\n' > "$CITY/.beads/routes.jsonl"; run_ps; ok $((RC != 1)) "PS routes.jsonl sem o prefixo ps: recusa 1"; has "$T/err" "não achei a rota do prefixo 'ps'"; ok $? "PS sem rota: diz o motivo"; ps_nothing; ok $? "PS sem rota: nada escrito"
printf 'routes.jsonl corrupt: not json\n' > "$CITY/.beads/routes.jsonl"; run_ps; ok $((RC != 1)) "PS routes.jsonl ilegível: recusa 1 (não vira 'só a cidade')"; ps_nothing; ok $? "PS routes ilegível: nada escrito"
rm -f "$CITY/.beads/routes.jsonl"; run_ps; ok $((RC != 1)) "PS routes.jsonl ausente: recusa 1"; ps_nothing; ok $? "PS routes ausente: nada escrito"
mkdir -p "$T/rigs/outro-rig"; git init -q "$T/rigs/outro-rig"; printf '{"prefix":"ga","path":"."}\n{"prefix":"ps","path":"../../rigs/outro-rig"}\n' > "$CITY/.beads/routes.jsonl"
run_ps; ok $((RC != 1)) "PS rota aponta para uma pasta que não é o rig property_scrapers: recusa 1"; has "$T/err" "não é a pasta do rig property_scrapers"; ok $? "PS pasta errada: diz o motivo"; ps_nothing; ok $? "PS pasta errada: nada escrito"
cp "$T/routes.orig" "$CITY/.beads/routes.jsonl"
mv "$PSMIRROR" "$T/psmirror.moved"; run_ps; ok $((RC != 1)) "PS sem o espelho property_scrapers.git: recusa 1"; has "$T/err" "não existe neste mini"; ok $? "PS sem espelho: diz o motivo"; ps_nothing; ok $? "PS sem espelho: nada escrito"
mv "$T/psmirror.moved" "$PSMIRROR"
reset_ps; run_ps GATE_DONE_REMOTE_MIRROR="$T/nao-existe.git" GATE_DONE_REMOTE_DRY_RUN=1; ok $((RC != 0)) "PS: GATE_DONE_REMOTE_MIRROR (variável de teste do HQ) NÃO desvia o espelho do PS"

# ── 11. o rig WA (ga-2hd02v.3.10): o pre-push do WA executa scripts da ÁRVORE empurrada ($REPO_ROOT/scripts/check_*.py) e o worktree é sem checkout de propósito (nada do nó roda no mini antes da revisão).
#    Sem o conserto o push do passo 1 era recusado ("Guard 6 FAILED": scripts/check_mds_registry_guard.py não existe no worktree) e o gate-done recusava 2x. Com ele, o atalho desliga o hook SÓ para o WA (core.hooksPath → pasta vazia da cidade) e diz isso no marcador.
WAORIGIN="$T/wa-origin.git"; WARIG="$T/rigs/whatsapp_automation"; WAMIRROR="$CITY/.gc/hetzner-mirror/repos/whatsapp_automation.git"; WADB="$T/db-wa.json"; WAW="$T/wa-work"
WASESS="wa-worker-remote-abc123"; WAALIAS="wa-worker-remote-1"; WABR="fix/wa-t1-wa-remoto-teste"; WAHOOKLOG="$T/wa-hook.log"; WASENT="$T/wa-executed"
git init -q --bare -b main "$WAORIGIN"; git clone -q "$WAORIGIN" "$WAW" 2>/dev/null
mkdir -p "$WAW/lib" "$WAW/scripts/hooks"; printf 'x = 1\n' > "$WAW/lib/x.py"
# o hook de verdade (scripts/hooks/pre-push do WA) acha $REPO_ROOT pelo `git rev-parse --show-toplevel` e roda os guards DE LÁ (G6 check_mds_registry_guard.py, G7, G12…): aqui, o menor que mostra a mesma forma
cat > "$WAW/scripts/hooks/pre-push" <<WAHOOK
#!/bin/sh
REPO_ROOT="\$(git rev-parse --show-toplevel)"
echo "pre-push em \$REPO_ROOT" >> "$WAHOOKLOG"
python3 "\$REPO_ROOT/scripts/check_mds_registry_guard.py" || { echo "Guard 6 FAILED: scripts/check_mds_registry_guard.py" >&2; exit 1; }
exit 0
WAHOOK
chmod +x "$WAW/scripts/hooks/pre-push"
printf 'open("%s", "a").write("guard rodou: " + __file__ + "\\n")\n' "$WASENT" > "$WAW/scripts/check_mds_registry_guard.py"   # o guard da ÁRVORE: se ele rodar em algum lugar, deixa rastro
G -C "$WAW" add lib scripts >/dev/null && G -C "$WAW" commit -qm "base" && G -C "$WAW" push -q origin HEAD:main 2>/dev/null
# o rig como o de verdade: checkout principal (confiável) com core.hooksPath apontando para <rig>/.git/hooks, onde pre-push é um link para scripts/hooks/pre-push do próprio checkout
git clone -q "$WAORIGIN" "$WARIG" 2>/dev/null; mkdir -p "$WARIG/.git/hooks"; ln -s "$WARIG/scripts/hooks/pre-push" "$WARIG/.git/hooks/pre-push"
git -C "$WARIG" config core.hooksPath "$WARIG/.git/hooks"
git clone -q --bare "$WAORIGIN" "$WAMIRROR"
wa_work() {  # wa_work ARQUIVO REF → NEWSHA: commit em cima de main que também mexe no guard e no hook DA ÁRVORE (o que o nó pode empurrar), empurrado ao espelho do WA em refs/heads/REF
  G -C "$WAW" checkout -q -b work-tmp main && printf 'v = 1\n' > "$WAW/lib/$1" && printf '# do no\n' >> "$WAW/scripts/check_mds_registry_guard.py" && printf 'echo hostil >> "%s"\n' "$WASENT" >> "$WAW/scripts/hooks/pre-push" \
    && G -C "$WAW" add "lib/$1" scripts >/dev/null && G -C "$WAW" commit -qm "feat(wa): $1" && NEWSHA=$(git -C "$WAW" rev-parse HEAD) && git -C "$WAW" push -q -f "$WAMIRROR" "HEAD:refs/heads/$2"
  r=$?; G -C "$WAW" checkout -q main; git -C "$WAW" branch -q -D work-tmp; return $r
}
wa_work y.py "worker/$WASESS"; WASHA=$NEWSHA
nohooks_clear() { rm -f "$CITY/.gc/gate-done-remote/no-hooks/"* 2>/dev/null; rmdir "$CITY/.gc/gate-done-remote/no-hooks" 2>/dev/null; return 0; }
reset_wa() {  # reset_wa: wa-t1 do alias WA na loja do rig (rota do nó); a loja da cidade com a ga-t1 do dog; sem rastro de hook/guard
  reset_db; git --git-dir="$WAORIGIN" update-ref -d "refs/heads/$WABR" 2>/dev/null; rm -f "$WAHOOKLOG" "$WASENT"; : > "$T/git.log"; nohooks_clear
  python3 -I - "$WADB" "$WAALIAS" <<'PYEOF'
import json, sys
p, alias = sys.argv[1:]
json.dump({"n": 0, "beads": {"wa-t1": {"id": "wa-t1", "title": "WA remoto: teste", "status": "in_progress", "assignee": alias, "issue_type": "bug",
           "labels": ["story:approved"], "metadata": {"gc.routed_to": "wa-worker-remote", "pilot.wa_node_alias": alias}, "created_by": "gastown.mayor", "owner": "x@y"}}}, open(p, "w"))
PYEOF
}
waq() { jq -r "$1" "$WADB"; }
run_wa() {  # run_wa [VAR=valor ...] [-- arg...] → RC, $T/out, $T/err (sessão wa-worker-remote; a rota do prefixo wa só existe DENTRO da chamada: a seção 10 prova a recusa sem ela)
  envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; [ $# -gt 0 ] && shift
  cp "$CITY/.beads/routes.jsonl" "$T/routes.keep"; printf '{"prefix":"ga","path":"."}\n{"prefix":"wa","path":"../../rigs/whatsapp_automation"}\n' > "$CITY/.beads/routes.jsonl"
  ( cd "$CITY" && env -i HOME="$T/home" USER=t LOGNAME=t LANG=en_US.UTF-8 PATH="$BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      BEADS_ACTOR="$WAALIAS" GC_ALIAS="$WAALIAS" GC_SESSION_NAME="$WASESS" GC_TEMPLATE=wa-worker-remote ${envs[@]+"${envs[@]}"} \
      "$CITY/scripts/gate-done-remote.py" "$@" ) > "$T/out" 2> "$T/err"; RC=$?
  cp "$T/routes.keep" "$CITY/.beads/routes.jsonl"
}
wa_origin_has() { git --git-dir="$WAORIGIN" rev-parse --verify -q "refs/heads/$1" 2>/dev/null; }
wa_clean() {  # nada do que a execução criou sobra no rig do WA
  [ ! -e "$WARIG/.gc-worktrees/gate-done-remote/wt-wa-t1" ] && ! git -C "$WARIG" show-ref -q --verify "refs/heads/$WABR" && [ -z "$(git -C "$WARIG" for-each-ref refs/gt-remote)" ] && [ "$(git -C "$WARIG" worktree list | wc -l | tr -d ' ')" = 1 ]
}
wa_nothing() { [ "$(mut_count)" = 0 ] && ! wa_origin_has "$WABR" >/dev/null; }
wa_no_trace() { [ ! -e "$WAHOOKLOG" ] && [ ! -e "$WASENT" ]; }   # o hook do rig não rodou e nenhum arquivo da árvore empurrada foi executado
# controles do fixture (sem o atalho): o hook liga num checkout de verdade e REPRODUZ o bug num worktree sem checkout; sem isto os testes de "hook desligado" passariam no vazio
reset_wa; git -C "$WARIG" fetch -q "$WAMIRROR" "+refs/heads/worker/$WASESS:refs/probe/wa" 2>/dev/null; git -C "$WARIG" push -q --dry-run origin "$WASHA:refs/heads/probe" 2>"$T/err"; ok $? "WA controle: o push do checkout principal passa pelo hook do rig (o guard roda de $WARIG)"
has "$WAHOOKLOG" "pre-push em $WARIG"; ok $? "WA controle: o hook do fixture rodou de verdade (a config core.hooksPath vale)"; [ -s "$WASENT" ]; ok $? "WA controle: o guard do checkout principal rodou (deixou rastro)"
reset_wa; git -C "$WARIG" worktree add -q --no-checkout -b probe-nc "$T/probe-wt" "$WASHA" 2>/dev/null; git -C "$T/probe-wt" push --dry-run origin HEAD:refs/heads/probe >/dev/null 2>"$T/err"; r=$?
ok $((r == 0)) "WA controle (o bug): push de worktree sem checkout é RECUSADO pelo hook do rig (o guard não existe lá)"; has "$T/err" "Guard 6 FAILED"; ok $? "WA controle (o bug): a recusa é a do Guard 6, a de produção"
git -C "$WARIG" worktree remove --force "$T/probe-wt" 2>/dev/null; git -C "$WARIG" branch -q -D probe-nc 2>/dev/null; git -C "$WARIG" update-ref -d refs/probe/wa 2>/dev/null
# ensaio: resolve tudo, não escreve nada
reset_wa; run_wa GATE_DONE_REMOTE_DRY_RUN=1
ok $((RC != 0)) "WA ensaio: sai 0"; has "$T/out" "bead=wa-t1 worker/$WASESS@${WASHA:0:12} → $WABR"; ok $? "WA ensaio: diz alias, bead (da loja do rig), sha e branch"
wa_nothing && wa_no_trace; ok $? "WA ensaio: nada escrito, nada empurrado, nenhum hook"
# caminho feliz: o atalho submete o WA, SEM o pre-push do rig e sem rodar nada da árvore do nó
reset_wa; run_wa
ok $((RC != 0)) "WA feliz: sai 0 (sem o conserto o hook recusava o push: Guard 6 FAILED, rc 1)"
[ "$(wa_origin_has "$WABR")" = "$WASHA" ]; ok $? "WA feliz: o origin do WA tem $WABR no sha do espelho do WA"
! origin_has "$WABR" >/dev/null; ok $? "WA feliz: o origin do HQ NÃO recebeu o branch do WA"
has "$T/out" "Marker created: ga-mk1"; ok $? "WA feliz: o marcador foi criado (na loja da CIDADE)"
[ "$(dbq '.beads["ga-mk1"].metadata["gate.submitted_by"] // ""')" = "$WAALIAS" ]; ok $? "WA feliz: gate.submitted_by = alias do WA"
[ "$(dbq '[.beads["ga-mk1"].labels[] | select(startswith("source-bead:") or startswith("bead-rig:") or startswith("branch:"))] | sort | join(",")')" = "bead-rig:whatsapp_automation,branch:$WABR,source-bead:wa-t1" ]; ok $? "WA feliz: o marcador leva source-bead:wa-t1, bead-rig:whatsapp_automation e o branch"
[ "$(waq '.beads["wa-t1"].labels | index("gate:queued") != null')" = true ]; ok $? "WA feliz: gate:queued na bead, NA LOJA DO RIG"
[ -z "$(waq '.beads["wa-t1"].assignee // ""')" ] && [ "$(waq '.beads["wa-t1"].metadata | has("gc.routed_to")')" = false ]; ok $? "WA feliz: a bead foi SOLTA na loja do rig"
wa_no_trace; ok $? "WA feliz: o pre-push do rig NÃO rodou e NENHUM arquivo da árvore empurrada foi executado no mini (sem hook, sem rastro do guard nem do hook hostil)"
has "$T/err" "AVISO: o pre-push de whatsapp_automation NÃO roda no mini"; ok $? "WA feliz: o cliente é avisado de que o pre-push foi pulado (não fica calado)"
dbq '.beads["ga-mk1"].description' | grep -qF -- "o pre-push de whatsapp_automation NAO rodou no mini"; ok $? "WA feliz: o marcador (self_audit:, o que o revisor do gate lê) registra que o pre-push NÃO rodou"
dbq '.beads["ga-mk1"].description' | grep -qF -- "NAO verificada aqui"; ok $? "WA feliz: a nota de auto-auditoria de sempre continua no marcador"
wa_clean; ok $? "WA feliz: worktree, branch local e ref temporária foram recolhidos (no rig do WA)"
[ "$(git -C "$WARIG" rev-parse HEAD)" = "$(git --git-dir="$WAORIGIN" rev-parse main)" ] && [ -z "$(git -C "$WARIG" status --porcelain)" ]; ok $? "WA feliz: o checkout principal do rig não mudou (nem arquivo novo)"
[ "$(git -C "$WARIG" config core.hooksPath)" = "$WARIG/.git/hooks" ]; ok $? "WA feliz: a config do rig continua apontando para o hook dele (o desligamento vale só dentro da chamada, por ambiente)"
[ -d "$CITY/.gc/gate-done-remote/no-hooks" ] && [ -z "$(ls -A "$CITY/.gc/gate-done-remote/no-hooks")" ]; ok $? "WA feliz: a pasta sem hooks (da cidade) existe e segue vazia"
grep -q '^cfg=3$' "$T/git.log" && ! grep -qvE '^cfg=(2|3)$' "$T/git.log"; ok $? "WA feliz: os git dos blocos levam 3 entradas (gc.auto, maintenance.auto e core.hooksPath); nenhum git do exe perde as duas de antes"
# forma com argumentos (2ª bead da sessão) vale igual
wa_work z.py "worker/$WASESS-2"; WASHA2=$NEWSHA
reset_wa; python3 -I - "$WADB" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["beads"]["wa-t2"] = dict(d["beads"]["wa-t1"], id="wa-t2", title="Segunda do WA"); json.dump(d, open(sys.argv[1], "w"))
PYEOF
run_wa -- wa-t2 "worker/$WASESS-2" "$WASHA2"; ok $((RC != 0)) "WA 2ª bead: gate-done wa-t2 worker/<sessão>-2 <sha> sai 0"; [ "$(wa_origin_has "fix/wa-t2-segunda-do-wa")" = "$WASHA2" ]; ok $? "WA 2ª bead: o origin do WA tem o branch no sha dito"
wa_no_trace; ok $? "WA 2ª bead: nenhum hook nem guard rodou"
# a pasta sem hooks é da cidade e tem de estar VAZIA: um hook plantado nela rodaria no mini → recusa antes de escrever (falhou/ilegível nunca vira "sem hooks")
reset_wa; mkdir -p "$CITY/.gc/gate-done-remote/no-hooks"; printf '#!/bin/sh\necho plantado >> "%s"\nexit 0\n' "$WASENT" > "$CITY/.gc/gate-done-remote/no-hooks/pre-push"; chmod +x "$CITY/.gc/gate-done-remote/no-hooks/pre-push"
run_wa; ok $((RC != 1)) "WA pasta sem hooks com um hook plantado: recusa 1"; has "$T/err" "não está vazia"; ok $? "WA hook plantado: diz o motivo"; wa_nothing && [ ! -e "$WASENT" ]; ok $? "WA hook plantado: nada escrito, nada empurrado, o hook plantado não rodou"; wa_clean; ok $? "WA hook plantado: o que a execução criou foi recolhido"
nohooks_clear
# o desligamento é SÓ do WA: HQ e PS seguem com o hook do próprio rig (o do PS é um shim do bd; o do HQ roda de /Users/athos/gt/.git/hooks). Hook de teste: deixa rastro e passa
mkdir -p "$PSRIG/.repo.git/hooks"; printf '#!/bin/sh\necho "ps-hook rodou" >> "%s"\nexit 0\n' "$T/ps-hook.log" > "$PSRIG/.repo.git/hooks/pre-push"; chmod +x "$PSRIG/.repo.git/hooks/pre-push"
reset_ps; rm -f "$T/ps-hook.log"; run_ps; ok $((RC != 0)) "PS com hook: sai 0"; has "$T/ps-hook.log" "ps-hook rodou"; ok $? "PS: o pre-push do rig RODOU (só o WA o pula)"; ! has "$T/err" "AVISO: o pre-push"; ok $? "PS: nenhum aviso de hook pulado"
! dbq '.beads["ga-mk1"].description' | grep -qF -- "NAO rodou no mini"; ok $? "PS: o marcador não diz que o pre-push foi pulado"
rm -f "$PSRIG/.repo.git/hooks/pre-push"
mkdir -p "$OUTER/.git/hooks"; printf '#!/bin/sh\necho "hq-hook rodou" >> "%s"\nexit 0\n' "$T/hq-hook.log" > "$OUTER/.git/hooks/pre-push"; chmod +x "$OUTER/.git/hooks/pre-push"
reset_db; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"; rm -f "$T/hq-hook.log"; run_exe; ok $((RC != 0)) "HQ com hook: sai 0"; has "$T/hq-hook.log" "hq-hook rodou"; ok $? "HQ: o pre-push do repositório RODOU (o hook do HQ é confiável e funciona sem checkout)"
rm -f "$OUTER/.git/hooks/pre-push"; reset_db; git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BR"
# hooks_off direto (a ordem das entradas de GIT_CONFIG_*: acrescenta NO FIM, nunca sobrescreve o que o main() já pôs; o que não consegue ler recusa)
python3 -B -I - "$CITY/scripts/gate-done-remote.py" "$T/hoff" <<'PYEOF'; ok $? "hooks_off: acrescenta core.hooksPath no fim de GIT_CONFIG_*, e recusa contagem ilegível, pasta com arquivo, arquivo no lugar da pasta e contagem negativa"
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("gdr", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w = Path(sys.argv[2]); w.mkdir()
e = m.hooks_off({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "gc.auto", "GIT_CONFIG_VALUE_0": "0", "GIT_CONFIG_KEY_1": "maintenance.auto", "GIT_CONFIG_VALUE_1": "false"}, w)
assert e["GIT_CONFIG_COUNT"] == "3" and e["GIT_CONFIG_KEY_2"] == "core.hooksPath" and e["GIT_CONFIG_VALUE_2"] == str(w / "no-hooks"), e
assert e["GIT_CONFIG_KEY_0"] == "gc.auto" and e["GIT_CONFIG_KEY_1"] == "maintenance.auto", e
e = m.hooks_off({}, w)
assert e["GIT_CONFIG_COUNT"] == "1" and e["GIT_CONFIG_KEY_0"] == "core.hooksPath", e
def refuses(env, wd):
    try: m.hooks_off(env, wd)
    except m.Stop: return True
    return False
assert refuses({"GIT_CONFIG_COUNT": "abc"}, w) and refuses({"GIT_CONFIG_COUNT": "-1"}, w)
(w / "no-hooks" / "pre-push").write_text("x")
assert refuses({}, w)
w2 = Path(sys.argv[2] + "-arquivo"); w2.mkdir(); (w2 / "no-hooks").write_text("x")   # um ARQUIVO no lugar da pasta: não dá para criar nem ler → recusa, não traceback
assert refuses({}, w2)
PYEOF

# ── 8. mutantes: cada guarda apagada tem de reprovar o caso que a prova ───────────────────────────────────────────────────────────────────────────
mutant() {  # mutant NOME 'trecho' 'troca' CASO ['trecho2' 'troca2'] — CASO é uma função que devolve 0 se o comportamento BOM aparece
  # CASO tem de estar definido ANTES da chamada: função indefinida sai 127 e o harness leria "morto" sem o caso ter rodado (ga-2hd02v.4.7, gate 1)
  declare -F "$4" >/dev/null || { echo "FAIL mutante $1: o caso '$4' não está definido (definido DEPOIS da chamada, ou com o nome errado)"; fails=$((fails+1)); n=$((n+1)); return; }
  cp -p "$CITY/scripts/gate-done-remote.py" "$T/exe.good"
  python3 -I - "$CITY/scripts/gate-done-remote.py" "$2" "$3" ${5+"$5"} ${6+"$6"} <<'EOF' || { echo "FAIL mutante $1: o trecho não existe mais no executável"; fails=$((fails+1)); n=$((n+1)); return; }
import sys
p, *pairs = sys.argv[1:]; s = open(p).read()
for a, b in zip(pairs[0::2], pairs[1::2]):  # um ou dois pares trecho/troca; cada trecho tem de existir UMA vez
    assert s.count(a) == 1, "trecho ausente ou repetido"; s = s.replace(a, b)
open(p, "w").write(s)
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
case_list_fail() { run_exe FAKE_GIT_FAIL=for-each-ref; [ "$RC" = 1 ] && ! origin_has "$BR" >/dev/null; }
case_leftover_branch() { G -C "$OUTER" branch "$BR" "$MAINSHA"; run_exe; k=0; has "$T/err" "resto de uma submissão anterior" && k=1; git -C "$OUTER" branch -q -D "$BR" 2>/dev/null; [ "$k" = 1 ]; }
case_cas() { run_exe FAKE_BD_STEAL=1; [ "$(dbq '.beads["ga-t1"].assignee // ""')" = "outro-dono" ]; }
mutant sem-checar-submitted_by 'if not who:' 'if False:' case_release_without_who
mutant fetch-escreve-FETCH_HEAD '"--no-write-fetch-head", ' '' case_fetch_head
mutant md-sem-checar-forma 'if cur is not None or sorted(blocks) != [1, 2, 3, 4] or any(len(v) != 1 for v in blocks.values()):' 'if False:' case_md_shape
mutant branch-alheio-nao-recusado 'if os.path.exists(wt) or refs.stdout.strip():' 'if os.path.exists(wt):' case_leftover_branch
mutant listar-branches-falho-vira-vazio 'if refs.returncode != 0:' 'if False:' case_list_fail
mutant solta-sem-compare-and-swap '"--if-assignee", alias, ' '' case_cas
# ga-2hd02v.1.18: as guardas da volta do gate e da ambiguidade do -N (cada caso devolve 0 quando o comportamento BOM aparece: recusa 1 e nada no origin)
refused_back() { [ "$RC" = 1 ] && ! origin_has "$BRB" >/dev/null; }
case_back_other_author() { seed_back outro-dog outro-dog; run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
case_back_newest() { seed_back outro-dog outro-dog; run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
case_back_no_label() { seed_back "$ALIAS" "$ALIAS" open "" "gate:queued"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
case_back_no_route() { seed_back "$ALIAS" "$ALIAS" open "" "gate:needs-fix" ""; run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
case_back_no_marker() { seed_back "$ALIAS" "$ALIAS"; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [d["beads"].pop(k) for k in ("ga-mkold","ga-mknew")]; json.dump(d,open(sys.argv[1],"w"))' "$DB"
  run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
case_bare_role() { reset_db2; run_exe_a GC_SESSION_NAME=dog-remote -- ga-t2 "worker/dog-remote-2" "$SHA"; has "$T/err" "branch principal de OUTRA sessão"; }
mutant volta-sem-checar-autor 'if not delivered_by(last, alias):' 'if False:' case_back_other_author
mutant volta-pega-o-marcador-mais-antigo 'return max(rows, key' 'return min(rows, key' case_back_newest
mutant volta-sem-gate-needs-fix 'isinstance(labels, list) and FIX_LABEL in labels' 'isinstance(labels, list)' case_back_no_label
mutant volta-sem-rota 'meta.get("gc.routed_to") in routes)' 'True)' case_back_no_route
# a forma REAL da volta (rota gastown.dog, marcadores fechados): o revisor do gate achou que o fixture só fabricava a rota dog-remote e que nada exercia o que a produção deixa
case_back_real_shape() { seed_back "$ALIAS" "$ALIAS"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; [ "$RC" = 0 ] && [ "$(origin_has "$BRB")" = "$SHAV" ]; }
case_back_other_route() { seed_back "$ALIAS" "$ALIAS" open "" "gate:needs-fix" "wa-worker"; run_exe_a -- ga-t2 "$BRB" "$SHAV"; refused_back; }
mutant volta-so-aceita-dog-remote 'ROUTES = ("gastown.dog", "dog-remote")' 'ROUTES = ("dog-remote",)' case_back_real_shape
mutant volta-sem-all-nos-marcadores '["list", "--all", "--label"' '["list", "--label"' case_back_real_shape
mutant volta-aceita-rota-de-outro-pool 'meta.get("gc.routed_to") in routes)' 'meta.get("gc.routed_to") is not None)' case_back_other_route
mutant volta-sem-marcador-vira-pode 'raise Stop(f"{bid} nunca foi entregue ao gate (nenhum marcador source-bead:{bid}): não há volta do gate para submeter")' 'return {"description": "author: " + os.environ["BEADS_ACTOR"]}' case_back_no_marker
mutant sufixo-N-ambiguo-sem-guarda 'and BARE_ROLE_RE.fullmatch(sess):' 'and False:' case_bare_role

# ga-2hd02v.4: os mutantes da tabela de rigs (cada um precisa do caso PS que o mata)
case_ps_happy() { reset_ps; run_ps; [ "$RC" = 0 ] && [ "$(ps_origin_has "$PSBR")" = "$PSSHA" ] && [ -z "$(psq '.beads["ps-t1"].assignee // ""')" ]; }
case_ps_rig_line() { reset_ps; run_ps; grep -qF "$PSRIG/.gc-worktrees/gate-done-remote/wt-ps-t1 -C create" "$T/bd.cwd"; }
case_ps_prefix_guard() { reset_ps; run_exe_a -- ps-t1 "worker/$SESS" "$SHA"; [ "$RC" = 1 ] && has "$T/err" "é de outro prefixo (ps)" && ps_nothing; }
case_ps_back() { seed_ps_back ps-worker; run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"; [ "$RC" = 0 ]; }
case_ps_back_hq_route() { seed_ps_back gastown.dog; run_ps -- ps-t2 "worker/$PSSESS-2" "$PSSHA2"; [ "$RC" = 1 ] && ps_nothing; }
case_ps_wrong_dir() { mkdir -p "$T/rigs/outro-rig"; printf '{"prefix":"ga","path":"."}\n{"prefix":"ps","path":"../../rigs/outro-rig"}\n' > "$CITY/.beads/routes.jsonl"; reset_ps; run_ps; r=$RC; cp "$T/routes.orig" "$CITY/.beads/routes.jsonl"; [ "$r" = 1 ] && has "$T/err" "não é a pasta do rig property_scrapers" && ps_nothing; }
case_ps_mirror_name() { reset_ps; run_ps; [ "$RC" = 0 ]; }
case_ps_released_in_store() { reset_ps; run_ps; [ "$(psq '.beads["ps-t1"].metadata | has("gc.routed_to")')" = false ]; }
case_ps_node_mark() { reset_ps; run_ps; [ "$(psq '.beads["ps-t1"].metadata | has("pilot.wa_node_alias")')" = false ]; }
case_ps_no_routes() { reset_ps; printf '{"prefix":"ga","path":"."}\n' > "$CITY/.beads/routes.jsonl"; run_ps; r=$RC; e=0; has "$T/err" "não achei a rota do prefixo 'ps'" && e=1; cp "$T/routes.orig" "$CITY/.beads/routes.jsonl"; [ "$r" = 1 ] && [ "$e" = 1 ] && ps_nothing; }
case_ps_unknown_prefix() { reset_ps; run_ps GC_SESSION_NAME=wa-worker-remote-abc123 GC_ALIAS=wa-worker-remote-1 BEADS_ACTOR=wa-worker-remote-1; [ "$RC" = 1 ] && ps_nothing; }
case_unknown_role() { reset_ps; run_exe GC_SESSION_NAME=remote-e2e-1 GATE_DONE_REMOTE_DRY_RUN=1; [ "$RC" = 0 ] && has "$T/out" "bead=ga-t1 worker/remote-e2e-1@"; }
case_release_empty_read() { reset_ps; run_ps FAKE_BD_SHOW_EMPTY_AFTER_UPDATE=ps-t1; has "$T/out" "NÃO ficou solta (resta ?" && ! has "$T/out" "bead solta: ps-t1"; }
case_release_other_bead() { reset_ps; run_ps FAKE_BD_SHOW_OTHER_AFTER_UPDATE=ps-t1; has "$T/out" "NÃO ficou solta (resta ?" && ! has "$T/out" "bead solta: ps-t1"; }
mutant ps-releitura-de-outra-bead-vira-solta 'if not isinstance(now, dict) or now.get("id") != bead:' 'if False:' case_release_other_bead
mutant ps-releitura-vazia-volta-a-or-vazio 'if not isinstance(now, dict) or now.get("id") != bead:' $'now = now or {}\n        if False:' case_release_empty_read
case_node_mark_left() { reset_ps; run_ps FAKE_BD_KEEP_MARK=1; has "$T/out" "NÃO ficou solta (resta pilot.wa_node_alias"; }
mutant ps-solta-nao-le-a-marca '("pilot.wa_node_alias", (now.get("metadata") or {}).get("pilot.wa_node_alias"))' '("x", None)' case_node_mark_left
case_mixed_identity() { reset_ps; run_ps GC_ALIAS="$ALIAS" BEADS_ACTOR="$ALIAS"; [ "$RC" = 2 ] && has "$T/err" "identidade mista" && ps_nothing; }
mutant ps-identidade-mista-vale 'if rig_of_session(alias) != role_prefix:' 'if False:' case_mixed_identity
mutant ps-loja-da-cidade        'bead = one_bead(ctx.store, alias)' 'bead = one_bead(city, alias)' case_ps_happy
mutant ps-guarda-de-prefixo     'if bpfx != role_prefix:' 'if False:' case_ps_prefix_guard
mutant ps-rotas-do-hq           'bead = named_bead(city, alias, args[0], ctx.store, ctx.rig.routes)' 'bead = named_bead(city, alias, args[0], ctx.store)' case_ps_back_hq_route
mutant ps-rotas-do-ps           'bead = named_bead(city, alias, args[0], ctx.store, ctx.rig.routes)' 'bead = named_bead(city, alias, args[0], ctx.store, ROUTES)' case_ps_back
mutant ps-worktree-fora-do-rig  'str(Path(path) / ".gc-worktrees" / "gate-done-remote"))' 'str(Path(city) / ".gc" / "gate-done-remote"))' case_ps_rig_line
mutant ps-espelho-do-hq         'f"{city}/.gc/hetzner-mirror/repos/{rig.name}.git", str(Path(path)' 'f"{city}/.gc/hetzner-mirror/repos/gascity.git", str(Path(path)' case_ps_mirror_name
mutant ps-solta-na-loja-errada  'release(city, bid, alias, found[0], ctx.store)' 'release(city, bid, alias, found[0])' case_ps_released_in_store
mutant ps-nao-solta-a-marca-do-no '"--unset-metadata", "gc.routed_to", "--unset-metadata", "pilot.wa_node_alias", "-q"' '"--unset-metadata", "gc.routed_to", "-q"' case_ps_node_mark
mutant ps-pasta-do-rig-nao-conferida 'if os.path.basename(path) != rig.name or not os.path.isdir(path):' 'if False:' case_ps_wrong_dir
mutant ps-rota-ausente-vira-cidade 'raise Stop(f"não achei a rota do prefixo {prefix!r} em {city}/.beads/routes.jsonl ({type(e).__name__}): sem ela não sei em que loja a bead mora")' 'return Ctx(rig, city, city, f"{city}/.gc/hetzner-mirror/repos/{rig.name}.git", str(Path(city) / ".gc" / "gate-done-remote"))' case_ps_no_routes
mutant ps-papel-desconhecido-vira-ps 'return next((p for p, r in RIGS.items() if m and r.role == m.group(1)), "ga")' 'return next((p for p, r in RIGS.items() if m and r.role == m.group(1)), "ps")' case_unknown_role

# ga-2hd02v.3.10: os mutantes do desligamento do pre-push do WA (cada caso devolve 0 quando o comportamento BOM aparece)
case_wa_happy() { reset_wa; run_wa; [ "$RC" = 0 ] && [ "$(wa_origin_has "$WABR")" = "$WASHA" ]; }
case_wa_no_exec() { reset_wa; run_wa; [ "$RC" = 0 ] && wa_no_trace; }
case_wa_audit_note() { reset_wa; run_wa; dbq '.beads["ga-mk1"].description' | grep -qF -- "o pre-push de whatsapp_automation NAO rodou no mini"; }
case_wa_warn() { reset_wa; run_wa; has "$T/err" "AVISO: o pre-push de whatsapp_automation NÃO roda no mini"; }
case_wa_cfg() { reset_wa; run_wa; grep -q '^cfg=3$' "$T/git.log"; }
case_wa_planted() { reset_wa; mkdir -p "$CITY/.gc/gate-done-remote/no-hooks"; printf '#!/bin/sh\nexit 0\n' > "$CITY/.gc/gate-done-remote/no-hooks/pre-push"; chmod +x "$CITY/.gc/gate-done-remote/no-hooks/pre-push"
  run_wa; r=$RC; nohooks_clear; [ "$r" = 1 ] && wa_nothing; }
case_ps_hook_runs() { mkdir -p "$PSRIG/.repo.git/hooks"; printf '#!/bin/sh\necho "ps-hook rodou" >> "%s"\nexit 0\n' "$T/ps-hook.log" > "$PSRIG/.repo.git/hooks/pre-push"; chmod +x "$PSRIG/.repo.git/hooks/pre-push"
  reset_ps; rm -f "$T/ps-hook.log"; run_ps; r=$RC; rm -f "$PSRIG/.repo.git/hooks/pre-push"; [ "$r" = 0 ] && has "$T/ps-hook.log" "ps-hook rodou"; }
mutant wa-hook-ligado-no-rig-wa      'prepush=False),' '),' case_wa_happy
mutant wa-hook-ligado-pelo-if        'if not ctx.rig.prepush:' 'if False:' case_wa_happy
mutant wa-aposentada-checkout-e-hook 'if not ctx.rig.prepush:' 'if False:' case_wa_no_exec '"worktree", "add", "-q", "--no-checkout", "-b"' '"worktree", "add", "-q", "-b"'
mutant wa-hook-desligado-em-todo-rig 'if not ctx.rig.prepush:' 'if True:' case_ps_hook_runs
mutant wa-aviso-calado-no-marcador   'env["SELF_AUDIT_SUMMARY"] += f"' '_ = f"' case_wa_audit_note
mutant wa-aviso-calado-no-cliente    'say(f"AVISO: o pre-push de' '(f"AVISO: o pre-push de' case_wa_warn
mutant wa-pasta-sem-hooks-nao-vazia  'if found:' 'if False:' case_wa_planted
mutant wa-config-sobrescreve-a-do-main 'n = int(env.get("GIT_CONFIG_COUNT") or "0")' 'n = int(env.get("GIT_CONFIG_COUNT") or "0") * 0' case_wa_cfg

echo
echo "$((n - fails))/$n ok, $fails falhas"
[ "$fails" = 0 ]
