# pilot-dispatcher.wa-node-spawn.mutants.py — o mutador do pilot-dispatcher.wa-node-spawn.selftest.sh (ga-2hd02v.3): 86 quebras de UMA linha do pilot-dispatcher.sh, cada uma com um nome.
#
# Contents
#   Uso · Como cada mutante é escrito
#
# USO:  python3 -I pilot-dispatcher.wa-node-spawn.mutants.py --list                  imprime os nomes, um por linha, na ordem
#       python3 -I pilot-dispatcher.wa-node-spawn.mutants.py <origem> <destino> <nome>   grava em <destino> a cópia de <origem> com o mutante <nome> aplicado
# Quem chama é o selftest (seção G): para cada nome ele aplica, confere `bash -n` e roda o selftest inteiro contra a cópia; o mutante tem de derrubá-lo.
# COMO CADA MUTANTE É ESCRITO: `rep(velho, novo)` troca UMA ocorrência e FALHA se o trecho sumiu ou se repete (o pilot-dispatcher.sh mudou: atualize o mutante, nunca deixe um no-op passar por "morto");
#   `frep(função, velho, novo)` faz o mesmo DENTRO do corpo de uma função (o desfazer do dog, _pilot_node_first_rollback, tem linhas parecidas com o desfazer genérico). Mutante que não muda nada = erro.
import sys

M = {}
ORDER = []
s = ""
name = ""


def rep(old, new):
    global s
    assert s.count(old) == 1, ("trecho ausente ou repetido", name, old[:80], s.count(old))
    s = s.replace(old, new, 1)


def frep(fn, old, new):
    """troca UMA vez, dentro do corpo de fn() — o desfazer do dog (_pilot_node_first_rollback) tem linhas parecidas"""
    global s
    a = s.index(fn + "() {\n")
    b = s.index("\n}\n", a) + 3
    reg = s[a:b]
    assert reg.count(old) == 1, ("trecho ausente ou repetido na função", name, fn, old[:80], reg.count(old))
    s = s[:a] + reg.replace(old, new, 1) + s[b:]


RR = "_pilot_node_remote_rollback"


def m(n):
    def d(f):
        M[n] = f
        ORDER.append(n)
        return f
    return d


# ── A. o modo ──
@m("modo-sempre-pool")
def _():
    rep('  _PWN_SPAWN=pilot\n  case "${PILOT_WA_NODE_SLOTS:-1}"', '  _PWN_SPAWN=pool\n  case "${PILOT_WA_NODE_SLOTS:-1}"')


@m("modo-qualquer-valor")
def _():
    rep('[ "${PILOT_WA_NODE_SPAWN:-}" = pilot ] || return 0', '[ -n "${PILOT_WA_NODE_SPAWN:-}" ] || return 0')


@m("slots-qualquer-valor")
def _():
    rep('[1-9]) _PWN_SLOTS="${PILOT_WA_NODE_SLOTS:-1}" ;; esac', '*) _PWN_SLOTS="${PILOT_WA_NODE_SLOTS:-1}" ;; esac')


@m("slots-ate-19")
def _():
    rep('[1-9]) _PWN_SLOTS=', '[1-9]|1[0-9]) _PWN_SLOTS=')


@m("slots-aceita-zero")
def _():
    rep('[1-9]) _PWN_SLOTS=', '[0-9]) _PWN_SLOTS=')


@m("slots-ignorados")
def _():
    rep('[1-9]) _PWN_SLOTS="${PILOT_WA_NODE_SLOTS:-1}" ;; esac', '[1-9]) _PWN_SLOTS=1 ;; esac')


# ── D. o decide ──
APPLY_REAL = '_out=$(WA_NODE_SPAWN="$_PWN_SPAWN" WA_NODE_SLOTS="$_PWN_SLOTS" timeout "${PILOT_WA_NODE_TIMEOUT:-90}" "$_dir/wa-node-dispatch.sh" apply "$_id" --store "$_store" --basis "$_basis" 2>/dev/null)'
APPLY_DRY = '_out=$(WA_NODE_SPAWN="$_PWN_SPAWN" WA_NODE_SLOTS="$_PWN_SLOTS" timeout "${PILOT_WA_NODE_TIMEOUT:-90}" "$_dir/wa-node-dispatch.sh" apply "$_id" --store "$_store" --basis "$_basis" --dry-run 2>/dev/null)'


@m("env-falta-no-apply")
def _():
    rep(APPLY_REAL, APPLY_REAL.replace('WA_NODE_SPAWN="$_PWN_SPAWN" WA_NODE_SLOTS="$_PWN_SLOTS" ', ''))


@m("env-falta-no-dry-run")
def _():
    rep(APPLY_DRY, APPLY_DRY.replace('WA_NODE_SPAWN="$_PWN_SPAWN" WA_NODE_SLOTS="$_PWN_SLOTS" ', ''))


@m("env-sem-slots-no-apply")
def _():
    rep(APPLY_REAL, APPLY_REAL.replace('WA_NODE_SLOTS="$_PWN_SLOTS" ', ''))


@m("env-sem-spawn-no-dry-run")
def _():
    rep(APPLY_DRY, APPLY_DRY.replace('WA_NODE_SPAWN="$_PWN_SPAWN" ', ''))


@m("pilot-nao-abre")
def _():
    rep('    _pilot_wa_node_open "$_id" "$_store"\n    return $?\n', '    return 0\n')


@m("pilot-open-ignora-rc")
def _():
    rep('    _pilot_wa_node_open "$_id" "$_store"\n    return $?\n', '    _pilot_wa_node_open "$_id" "$_store"\n    return 0\n')


@m("orcamento-ignorado")
def _():
    rep('if [ "$_PWN_SPAWN" = pilot ] && _pilot_slow_spawn_budget_spent; then', 'if false; then')


@m("orcamento-vale-no-pool")
def _():
    rep('if [ "$_PWN_SPAWN" = pilot ] && _pilot_slow_spawn_budget_spent; then', 'if _pilot_slow_spawn_budget_spent; then')


@m("orcamento-devolve-0")
def _():
    rep('(uma por sweep); nada escrito"\n      return 1', '(uma por sweep); nada escrito"\n      return 0')


@m("orcamento-devolve-2")
def _():
    rep('(uma por sweep); nada escrito"\n      return 1', '(uma por sweep); nada escrito"\n      return 2')


@m("jsonl-sem-modo")
def _():
    rep('--arg sp "$_PWN_SPAWN" --argjson sl "$_PWN_SLOTS"', '--arg sp pool --argjson sl 1')


# ── E. o settle ──
@m("settle-ausente-rc13")
def _():
    rep('desconhecido (rc=$_rc); não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 2 ;;', 'desconhecido (rc=$_rc); não despacho esta varredura"; return 2 ;;')


@m("settle-ausente-sinal")
def _():
    rep('a escrita pode ter acontecido; não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 2 ;;', 'a escrita pode ter acontecido; não despacho esta varredura"; return 2 ;;')


@m("rc13-devolve-1")
def _():
    rep('desconhecido (rc=$_rc); não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 2 ;;', 'desconhecido (rc=$_rc); não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 1 ;;')


@m("sinal-devolve-1")
def _():
    rep('a escrita pode ter acontecido; não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 2 ;;', 'a escrita pode ter acontecido; não despacho esta varredura"; _pilot_wa_node_settle "$_id" "$_store"; return 1 ;;')


@m("settle-roda-no-pool")
def _():
    rep('  [ "$_PWN_SPAWN" = pilot ] || return 0\n  _pilot_wa_node_read', '  _pilot_wa_node_read')


@m("settle-pisa-alheio")
def _():
    rep('  case "$_PWR_ALIAS" in wa-worker-remote-[1-9]) ;; *) return 0 ;; esac\n', '')


@m("settle-alias-largo")
def _():
    rep('case "$_PWR_ALIAS" in wa-worker-remote-[1-9]) ;; *) return 0 ;; esac', 'case "$_PWR_ALIAS" in wa-worker-remote*) ;; *) return 0 ;; esac')


@m("settle-ignora-marca")
def _():
    rep('if [ "$_PWR_MARK" != "$_PWR_ALIAS" ] || [ "$_PWR_STATUS" != in_progress ]; then return 0; fi', 'if [ "$_PWR_STATUS" != in_progress ]; then return 0; fi')


@m("settle-ignora-status")
def _():
    rep('if [ "$_PWR_MARK" != "$_PWR_ALIAS" ] || [ "$_PWR_STATUS" != in_progress ]; then return 0; fi', 'if [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then return 0; fi')


@m("settle-fecha-sessao")
def _():
    rep('_pilot_node_remote_rollback "$_PWR_ALIAS" "$_se_id" "$_se_store" 0 pilot.wa_node_alias || true', '_pilot_node_remote_rollback "$_PWR_ALIAS" "$_se_id" "$_se_store" 1 pilot.wa_node_alias || true')


@m("settle-chave-errada")
def _():
    rep('_pilot_node_remote_rollback "$_PWR_ALIAS" "$_se_id" "$_se_store" 0 pilot.wa_node_alias || true', '_pilot_node_remote_rollback "$_PWR_ALIAS" "$_se_id" "$_se_store" 0 pilot.outra_chave || true')


# ── C. a abertura do gancho do WA ──
@m("open-alias-fixo")
def _():
    rep('_pilot_node_remote_open wa-worker-remote "$_PWR_ALIAS" "$_wo_id"', '_pilot_node_remote_open wa-worker-remote wa-worker-remote-1 "$_wo_id"')


@m("open-qualquer-dono")
def _():
    rep('  case "$_PWR_ALIAS" in\n    wa-worker-remote-[1-9]) ;;\n    *) warn "wa-node: $_wo_id depois', '  case "$_PWR_ALIAS" in\n    *) ;;\n    *) warn "wa-node: $_wo_id depois')


@m("open-alias-largo")
def _():
    rep('    wa-worker-remote-[1-9]) ;;\n    *) warn "wa-node: $_wo_id depois', '    wa-worker-remote-*) ;;\n    *) warn "wa-node: $_wo_id depois')


@m("open-ignora-marca")
def _():
    rep('if [ "$_PWR_MARK" != "$_PWR_ALIAS" ] || [ "$_PWR_STATUS" != in_progress ]; then\n    warn', 'if [ "$_PWR_STATUS" != in_progress ]; then\n    warn')


@m("open-ignora-status")
def _():
    rep('if [ "$_PWR_MARK" != "$_PWR_ALIAS" ] || [ "$_PWR_STATUS" != in_progress ]; then\n    warn', 'if [ "$_PWR_MARK" != "$_PWR_ALIAS" ]; then\n    warn')


@m("open-leitura-ignorada")
def _():
    rep('if ! _pilot_wa_node_read "$_wo_id" "$_wo_store"; then', 'if false; then')


# ── a releitura ──
@m("le-outro-id")
def _():
    rep('select(type == "object" and .id == $id and (.status | type == "string")) | [.status', 'select(type == "object" and (.status | type == "string")) | [.status')


@m("le-sem-status-texto")
def _():
    rep('select(type == "object" and .id == $id and (.status | type == "string")) | [.status', 'select(type == "object" and .id == $id) | [.status')


@m("titulo-sub")
def _():
    rep(r'''gsub("[\r\n|]"; " ")''', r'''sub("[\r\n|]"; " ")''')


@m("titulo-sem-barra")
def _():
    rep(r'''gsub("[\r\n|]"; " ")''', r'''gsub("[\r\n]"; " ")''')


@m("read-sem-r")
def _():
    rep("IFS='|' read -r _PWR_STATUS", "IFS='|' read _PWR_STATUS")


# ── B. a peça genérica de abrir ──
@m("nunca-acorda")
def _():
    rep('if [ "$_ro_st" = asleep ]; then', 'if false; then')


@m("ocupado-aceito")
def _():
    rep('busy) _ro_step="o alias já tem uma sessão viva (ou de outro template)" ;;', 'busy) ;;')


@m("lista-sem-array")
def _():
    rep(r'''if ! printf '%s' "$_ro_sj" | jq -e '.sessions | type == "array"' >/dev/null 2>&1; then''', 'if false; then')


@m("fechada-conta-viva")
def _():
    rep('select(type == "object" and .closed != true and .alias == $a)', 'select(type == "object" and .alias == $a)')


@m("sem-tipo-objeto")
def _():
    rep('select(type == "object" and .closed != true and .alias == $a)', 'select(.closed != true and .alias == $a)')


@m("parada-conta-viva")
def _():
    rep('test("closed|stopped|archived|drained") | not', 'test("closed") | not')


@m("dormindo-conta-morta")
def _():
    rep('test("closed|stopped|archived|drained") | not', 'test("closed|stopped|archived|drained|asleep") | not')


@m("acorda-de-outro-template")
def _():
    rep('all(.template == $t and .state == "asleep")', 'all(.state == "asleep")')


@m("acorda-qualquer-estado")
def _():
    rep('all(.template == $t and .state == "asleep")', 'all(.template == $t)')


@m("acorda-se-algum-dorme")
def _():
    rep('all(.template == $t and .state == "asleep")', 'any(.template == $t and .state == "asleep")')


@m("template-fixo")
def _():
    rep('session new "$_ro_tpl" --alias', 'session new wa-worker-remote --alias')


@m("dica-sem-id")
def _():
    rep('--title-hint "build $_ro_id: $_ro_title"', '--title-hint "build: $_ro_title"')


@m("sem-aviso")
def _():
    rep('timeout 15 gc --city "$GC_CITY" session nudge "$_ro_alias" "$_ro_msg" >/dev/null 2>&1 || _ro_rc=$?', ':')


@m("aviso-falha-ignorada")
def _():
    rep('[ "$_ro_rc" -eq 0 ] || _ro_step="o aviso falhou (rc=$_ro_rc)"', ':')


@m("sem-nota-de-prazo")
def _():
    rep('    _pilot_note_spawn_timing "$_ro_rc" "$_ro_t0"\n', '')


@m("abertura-falha-ignorada")
def _():
    rep('if [ "$_ro_rc" -ne 0 ]; then\n      _ro_step="a sessão', 'if false; then\n      _ro_step="a sessão')


@m("sessao-nao-marcada")
def _():
    rep('_ro_sess=1; _ro_rc=0; _ro_t0=$SECONDS', '_ro_sess=0; _ro_rc=0; _ro_t0=$SECONDS')


@m("desfaz-nao-confirmado-vira-1")
def _():
    rep('then return 1; fi\n    return 2\n  fi\n  log "  ga-2hd02v.3: $_ro_id foi ao nó', 'then return 1; fi\n    return 1\n  fi\n  log "  ga-2hd02v.3: $_ro_id foi ao nó')


@m("desfaz-confirmado-vira-2")
def _():
    rep('"$_ro_sess" "$_ro_key"; then return 1; fi', '"$_ro_sess" "$_ro_key"; then return 2; fi')


@m("sem-desfazer")
def _():
    rep('if _pilot_node_remote_rollback "$_ro_alias" "$_ro_id" "$_ro_store" "$_ro_sess" "$_ro_key"; then return 1; fi', 'if true; then return 1; fi')


# ── o desfazer ──
@m("desfaz-nunca-fecha")
def _():
    frep(RR, 'if [ "$_rb_sess" = "1" ]; then', 'if false; then')


@m("desfaz-sempre-fecha")
def _():
    frep(RR, 'if [ "$_rb_sess" = "1" ]; then', 'if true; then')


@m("desfaz-bead-antes-da-sessao")
def _():
    global s
    a = s.index(RR + "() {\n")
    b = s.index("\n}\n", a) + 3
    reg = s[a:b]
    i0 = reg.index('  if [ "$_rb_sess" = "1" ]; then')
    u0 = reg.index('  timeout 15 bd -C "$_rb_store" update')
    u1 = reg.index("\n", u0) + 1
    assert i0 < u0
    s = s[:a] + reg[:i0] + reg[u0:u1] + reg[i0:u0] + reg[u1:] + s[b:]


@m("desfaz-sem-if-assignee")
def _():
    frep(RR, ' --if-assignee "$_rb_alias" --assignee ""', ' --assignee ""')


@m("desfaz-sem-open")
def _():
    rep(' --status open --unset-metadata "$_rb_key" -q', ' --unset-metadata "$_rb_key" -q')


@m("desfaz-sem-soltar-marca")
def _():
    rep(' --status open --unset-metadata "$_rb_key" -q', ' --status open -q')


@m("desfaz-chave-fixa")
def _():
    rep('--unset-metadata "$_rb_key" -q', '--unset-metadata pilot.wa_node_alias -q')


@m("confirma-so-dono")
def _():
    rep('if [ -z "$_rb_asg" ] && [ "$_rb_st" = open ] && [ -z "$_rb_mk" ]; then return 0; fi', 'if [ -z "$_rb_asg" ]; then return 0; fi')


@m("confirma-sem-status")
def _():
    rep('if [ -z "$_rb_asg" ] && [ "$_rb_st" = open ] && [ -z "$_rb_mk" ]; then return 0; fi', 'if [ -z "$_rb_asg" ] && [ -z "$_rb_mk" ]; then return 0; fi')


@m("confirma-sem-marca")
def _():
    rep('if [ -z "$_rb_asg" ] && [ "$_rb_st" = open ] && [ -z "$_rb_mk" ]; then return 0; fi', 'if [ -z "$_rb_asg" ] && [ "$_rb_st" = open ]; then return 0; fi')


@m("confirma-ilegivel-ok")
def _():
    frep(RR, 'o claim fica para o TTL"\n    return 1\n  fi', 'o claim fica para o TTL"\n    return 0\n  fi')


@m("nao-confirmado-vira-ok")
def _():
    frep(RR, 'o claim fica para o TTL"\n  return 1\n}', 'o claim fica para o TTL"\n  return 0\n}')


@m("confirma-outro-id")
def _():
    rep('select(type == "object" and .id == $id and (.status | type == "string")) | "\\(.assignee', 'select(type == "object" and (.status | type == "string")) | "\\(.assignee')


# ── H. a sessão ociosa reaproveitada (ga-2hd02v.3.12) ──
@m("ocioso-sempre-ligado")
def _():
    rep("case \"$_ro_idle\" in ''|*[!0-9]*) _ro_idle=-1 ;; esac", "case \"$_ro_idle\" in ''|*[!0-9]*) _ro_idle=0 ;; esac")


@m("ocioso-desligado-vale")
def _():
    rep('elif $idle >= 0 and', 'elif true and')


@m("ocioso-sem-quietude")
def _():
    rep(' and (($now - $ts) >= $idle)))', '))')


@m("ocioso-estado-qualquer")
def _():
    rep('select(.template == $t and .state == "active")', 'select(.template == $t)')


@m("ocioso-template-qualquer")
def _():
    rep('select(.template == $t and .state == "active")', 'select(.state == "active")')


@m("ocioso-varias-sessoes")
def _():
    rep('$idle >= 0 and ($h | length) == 1 and ([$h[]', '$idle >= 0 and ([$h[]')


@m("ocioso-abre-sessao")
def _():
    rep('if [ -z "$_ro_step" ] && [ "$_ro_st" != idle ]; then', 'if [ -z "$_ro_step" ]; then')


@m("ocioso-fecha-ao-desfazer")
def _():
    rep('_ro_step="" _ro_sess=0 _ro_msg=""', '_ro_step="" _ro_sess=1 _ro_msg=""')


@m("ocioso-wa-sem-optar")
def _():
    rep('pilot.wa_node_alias "$(_pilot_node_idle_secs)" || _wo_rc=$?', 'pilot.wa_node_alias || _wo_rc=$?')


@m("ocioso-ps-sem-optar")
def _():
    rep('pilot.wa_node_alias "$(_pilot_node_idle_secs)" || _po_rc=$?', 'pilot.wa_node_alias || _po_rc=$?')


@m("idle-secs-padrao")
def _():
    rep('local _is="${WA_NODE_IDLE_SECS:-300}"', 'local _is="${WA_NODE_IDLE_SECS:-0}"')


@m("idle-secs-octal")
def _():
    rep('_is=$((10#$_is))', '_is=$((_is))')


@m("idle-secs-ilegivel-zero")
def _():
    rep("''|*[!0-9]*) _is=300 ;; *) if", "''|*[!0-9]*) _is=0 ;; *) if")


@m("idle-secs-longo")
def _():
    rep('else _is=300; fi', 'else _is=0; fi')


if len(sys.argv) == 2 and sys.argv[1] == "--list":
    print("\n".join(ORDER))
    sys.exit(0)
src, dst, name = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
orig = s
M[name]()
assert s != orig, ("o mutante não mudou nada", name)
open(dst, "w", encoding="utf-8").write(s)
