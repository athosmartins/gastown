#!/usr/bin/env bash
# engine-backup-lib.sh (ga-ta2w6r) -- "o que RODA tem backup?"
#
# Biblioteca SOURCED (nunca executada). Tres consumidores, UMA implementacao --
# copias divergentes seriam a proxima versao deste mesmo defeito:
#   scripts/engine-window-run.sh                                    build empurra, swap verifica
#   packs/town-deltas/assets/scripts/engine-window-swap.sh          swap verifica
#   packs/town-deltas/assets/scripts/engine-binary-backup-guard.sh  detecta, de hora em hora
#
# POR QUE EXISTE (Mayor, 20/09/2026). A branch consolidated/engine-window-20260919
# tinha 12 commits em NENHUM remoto -- ~20 patches de tres janelas (0906, 0906b,
# 0919) -- e o binario que a cidade inteira rodava (gc-1.1.1-engwin0919) vinha do
# topo dela. O procedimento da janela consolidava, compilava e trocava o binario
# sem NENHUM passo que empurrasse a fonte: nao foi esquecimento, era etapa ausente.
#
# QUAL STAMP CONFIAR (medido em 20/09; e por isso esta lib nao le o que parece obvio):
#   * `main.commit` (gc) / `main.Build` (bd): passados por -ldflags -X. `gc version
#     --long` imprime o primeiro; `bd version --json` o segundo (.build). E o unico
#     stamp que descreve o repo-fonte certo.
#   * `vcs.revision` / `vcs.modified` / o "-dirty" do `gc version --long` NAO servem.
#     As janelas compilam num `git worktree` (.gc-worktrees/engine-window-*), cujo
#     `.git` e um ARQUIVO; o stamp VCS do Go so reconhece `.git` que e DIRETORIO e
#     entao sobe ate o repo que envolve o worktree (~/gt, a HQ). Resultado medido:
#     gc-*-engwin0906/0906b/0919 e o bd carregam um commit da HQ que nem existe no
#     repo do engine, e "-dirty" e a sujeira da HQ, nao do engine. Um teste
#     "vcs.revision esta num remoto?" daria verde FALSO justamente no incidente que
#     esta lib existe pra pegar.
#
# CONTRATO DE eb_backup_state -- quatro estados, nunca colapsados em booleano:
#   OK       algum ref remoto CONTEM o commit (positivo; marcado "velhas" se o fetch falhou)
#   MISSING  o commit existe so neste disco: nenhum remoto o contem
#   ORPHAN   o commit nem existe no repo-fonte (a fonte do binario pode nao existir em lugar nenhum)
#   UNKNOWN  nao da pra saber (fetch falhou sem evidencia positiva, uma leitura do git
#            falhou -- remotos, for-each-ref --, repo ilegivel, ...). Erro de leitura
#            nunca vira lista vazia, e lista vazia nunca vira acusacao.
# MISSING e ORPHAN so sao afirmados depois de um fetch que DEU CERTO: sem visao
# fresca do remoto, "nao achei" nao prova "nao existe" e o estado honesto e UNKNOWN.
#
# Regras que a lib nunca quebra: NUNCA force-push (um remoto com historia
# divergente e problema pra um humano decidir); o push so vale quando o EFEITO e
# verificado (o commit aparece num remoto depois), nao pelo codigo de saida; git
# nunca pergunta credencial; todo comando de rede tem limite de tempo -- `timeout`
# quando existe E, independente dele, http.lowSpeedLimit/Time (uma transferencia
# parada aborta sozinha). Isso importa mais do que parece: um fetch pendurado
# seguraria o lock do guard horario pra sempre, e todas as execucoes seguintes
# sairiam "outra instancia rodando" -- um guard que existe e entrega zero.
#
# Sem `set -e/-u` proprios (e sourced: quem inclui decide). Compativel com bash
# 3.2 (o /bin/bash do macOS): sem arrays associativos, sem ${x,,}, sem mapfile.

EB_FETCH_TIMEOUT_S="${EB_FETCH_TIMEOUT_S:-90}"
EB_FETCH_TRIES="${EB_FETCH_TRIES:-1}"
EB_PUSH_TIMEOUT_S="${EB_PUSH_TIMEOUT_S:-120}"
EB_PUSH_TRIES="${EB_PUSH_TRIES:-3}"
EB_RETRY_SLEEP_S="${EB_RETRY_SLEEP_S:-20}"
EB_VERSION_TIMEOUT_S="${EB_VERSION_TIMEOUT_S:-15}"

# Resultado do ultimo eb_fetch_all -- lido por eb_backup_state.
EB_FETCH_STATE=""     # ok | failed | skipped | "" (nunca buscou)
EB_FETCH_NOTE=""

# Quem inclui pode apontar EB_LOG para uma funcao sua (ex.: log, que escreve no
# arquivo de log da janela); sem isso, stderr.
eb_log() {
    if [ -n "${EB_LOG:-}" ] && [ "$(type -t "$EB_LOG" 2>/dev/null)" = "function" ]; then
        "$EB_LOG" "$@"
    else
        printf '%s\n' "$*" >&2
    fi
}

# eb_bounded <segundos> comando... -- com limite se houver timeout/gtimeout;
# sem nenhum dos dois roda sem limite (o git ainda respeita os timeouts de http).
eb_bounded() {
    local secs="$1" tb
    shift
    tb=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
    if [ -n "$tb" ]; then "$tb" "$secs" "$@"; else "$@"; fi
}

# eb_binary_commit <binario> [gc|bd] -- imprime o commit (so os hex) que o binario
# declara no PROPRIO stamp (ver "QUAL STAMP CONFIAR"). rc=1 se nao ha stamp: um
# binario sem commit rastreavel e um resultado, nunca um "commit vazio" a ser
# consultado. "4f4837703-dirty" e "042e965f0-ga165vq" viram o prefixo hex.
eb_binary_commit() {
    local bin="$1" kind="${2:-gc}" out c=""
    [ -x "$bin" ] || return 1
    case "$kind" in
        gc)
            out=$(eb_bounded "$EB_VERSION_TIMEOUT_S" "$bin" version --long 2>/dev/null) || out=""
            c=$(printf '%s\n' "$out" | grep -o -E 'commit: [0-9a-fA-F]{7,40}' | sed -n '1p' | awk '{print $2}') || c=""
            ;;
        bd)
            out=$(eb_bounded "$EB_VERSION_TIMEOUT_S" "$bin" version --json 2>/dev/null) || out=""
            c=$(printf '%s\n' "$out" | sed -n 's/.*"build": *"\([0-9a-fA-F]\{7,40\}\)".*/\1/p' | sed -n '1p') || c=""
            ;;
    esac
    # Sem executar o binario: le o buildinfo (ldflags -X main.commit= / main.Build=).
    if [ -z "$c" ] && command -v go >/dev/null 2>&1; then
        c=$(go version -m "$bin" 2>/dev/null | grep -o -E 'main\.(commit|Build)=[0-9a-fA-F]{7,40}' | sed -n '1p' | sed 's/.*=//') || c=""
    fi
    [ -n "$c" ] || return 1
    printf '%s\n' "$c"
}

# eb_fetch_all <repo> -- `fetch --prune` de cada remoto (limitado). --prune e o que
# faz "o branch foi apagado no remoto" aparecer como MISSING em vez de um ref velho
# fingir backup; --no-tags evita brigar com tags locais forcadas (engwin-*).
# gc.auto/maintenance.auto=0: um detector horario nao pode disparar manutencao.
# Seta EB_FETCH_STATE/EB_FETCH_NOTE. Sempre rc=0 -- falha de rede e ESTADO, nao erro.
eb_fetch_all() {
    local repo="$1" remote remotes try rc ok="" bad=""
    EB_FETCH_STATE=""
    EB_FETCH_NOTE=""
    if [ "${EB_NO_FETCH:-0}" = "1" ]; then
        EB_FETCH_STATE="skipped"
        EB_FETCH_NOTE="sem fetch (EB_NO_FETCH=1)"
        return 0
    fi
    if [ -n "${EB_REMOTES:-}" ]; then
        remotes="$EB_REMOTES"
    elif ! remotes=$(git -C "$repo" remote 2>/dev/null); then
        # NAO conseguir listar os remotos nao e "repo sem remotos" (uma visao
        # completa e fresca): e "nao sei". Terceiro estado, nunca colapsado em ok.
        EB_FETCH_STATE="failed"
        EB_FETCH_NOTE="nao consegui listar os remotos de $repo"
        return 0
    fi
    for remote in $remotes; do
        try=0
        rc=1
        while [ "$try" -lt "$EB_FETCH_TRIES" ]; do
            try=$((try + 1))
            if eb_bounded "$EB_FETCH_TIMEOUT_S" env GIT_TERMINAL_PROMPT=0 \
                git -C "$repo" -c gc.auto=0 -c maintenance.auto=false \
                -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
                fetch --prune --no-tags --quiet "$remote" >/dev/null 2>&1; then
                rc=0
                break
            fi
            if [ "$try" -lt "$EB_FETCH_TRIES" ]; then sleep "$EB_RETRY_SLEEP_S"; fi
        done
        if [ "$rc" = "0" ]; then ok="$ok $remote"; else bad="$bad $remote"; fi
    done
    if [ -n "$bad" ]; then
        EB_FETCH_STATE="failed"
        EB_FETCH_NOTE="fetch FALHOU em:${bad}; ok em:${ok:- nenhum}"
    else
        EB_FETCH_STATE="ok"
        EB_FETCH_NOTE="fetch ok em:${ok:- (repo sem remotos)}"
    fi
    return 0
}

# eb_backup_state <repo> <commit> -- imprime "ESTADO|detalhe" (ver CONTRATO). Le
# EB_FETCH_STATE: chame eb_fetch_all <repo> antes (uma vez por repo, nao por commit).
eb_backup_state() {
    local repo="$1" commit="$2" full refs refs_raw
    if [ -z "$repo" ] || [ -z "$commit" ]; then
        echo "UNKNOWN|argumento vazio (repo/commit)"
        return 0
    fi
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "UNKNOWN|repo-fonte ilegivel: $repo"
        return 0
    fi
    full=$(git -C "$repo" rev-parse --verify --quiet "${commit}^{commit}" 2>/dev/null) || full=""
    if [ -z "$full" ]; then
        if [ "$EB_FETCH_STATE" = "ok" ]; then
            echo "ORPHAN|commit $commit nao existe em $repo (nem apos fetch; ou o prefixo e ambiguo): a fonte deste binario pode nao existir em lugar nenhum"
        else
            echo "UNKNOWN|commit $commit ausente localmente e sem fetch confiavel (${EB_FETCH_NOTE:-fetch nao executado})"
        fi
        return 0
    fi
    # O rc do for-each-ref e lido SEPARADO do pipe de formatacao: um for-each-ref que
    # FALHOU nao pode virar "lista vazia" e depois MISSING (uma acusacao) -- e UNKNOWN.
    if ! refs_raw=$(git -C "$repo" for-each-ref --contains "$full" --format='%(refname:short)' refs/remotes 2>/dev/null); then
        echo "UNKNOWN|git for-each-ref --contains falhou em $repo: nao da pra saber se algum remoto contem $commit"
        return 0
    fi
    refs=$(printf '%s\n' "$refs_raw" | sed -n '1,3p' | tr '\n' ' ') || refs=""
    refs="${refs% }"
    if [ -n "$refs" ]; then
        if [ "$EB_FETCH_STATE" = "ok" ]; then
            echo "OK|$refs"
        else
            echo "OK|$refs [refs possivelmente velhas: ${EB_FETCH_NOTE:-fetch nao executado}]"
        fi
    elif [ "$EB_FETCH_STATE" = "ok" ]; then
        echo "MISSING|$commit existe so neste disco: nenhum remoto o contem"
    else
        echo "UNKNOWN|nenhum ref remoto conhecido contem $commit, mas sem fetch confiavel (${EB_FETCH_NOTE:-fetch nao executado})"
    fi
    return 0
}

# eb_branch_hint <repo> <commit> -- um branch local que contem o commit (dica de
# "o que empurrar" nas mensagens). Vazio se nenhum.
eb_branch_hint() {
    local repo="$1" commit="$2"
    git -C "$repo" for-each-ref --contains "$commit" --format='%(refname:short)' refs/heads 2>/dev/null | sed -n '1p' || true
}

# eb_push_branch <worktree> <branch> [remote] -- empurra <branch> (sem force) e so
# retorna 0 se o EFEITO foi verificado: depois do push, um fetch novo tem que
# mostrar o commit num remoto. rc=0 do `git push` nao prova isso.
eb_push_branch() {
    local wt="$1" branch="$2" remote="${3:-origin}" tip try=0 out rc=1 st
    tip=$(git -C "$wt" rev-parse --verify --quiet "refs/heads/${branch}^{commit}" 2>/dev/null) || tip=""
    if [ -z "$tip" ]; then
        eb_log "  push: branch '$branch' nao existe em $wt"
        return 1
    fi
    while [ "$try" -lt "$EB_PUSH_TRIES" ]; do
        try=$((try + 1))
        out=$(eb_bounded "$EB_PUSH_TIMEOUT_S" env GIT_TERMINAL_PROMPT=0 \
            git -C "$wt" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
            push "$remote" "refs/heads/${branch}:refs/heads/${branch}" 2>&1) && rc=0 || rc=$?
        [ "$rc" = "0" ] && break
        case "$out" in
            *"non-fast-forward"* | *"[rejected]"* | *"fetch first"*)
                eb_log "  push: REJEITADO por $remote -- o remoto tem historia que este branch nao tem (NAO faco force-push; um humano decide): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
                return 1
                ;;
        esac
        eb_log "  push: tentativa $try/$EB_PUSH_TRIES falhou (rc=$rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        if [ "$try" -lt "$EB_PUSH_TRIES" ]; then sleep "$EB_RETRY_SLEEP_S"; fi
    done
    [ "$rc" = "0" ] || return 1
    eb_fetch_all "$wt"
    st=$(eb_backup_state "$wt" "$tip")
    case "$st" in
        OK\|*)
            eb_log "  push: OK -- $branch @ $(printf '%.9s' "$tip") em ${st#*|}"
            return 0
            ;;
    esac
    eb_log "  push: o push retornou 0 mas o commit $tip NAO aparece em nenhum remoto (${st}) -- tratando como falha"
    return 1
}

# eb_require_backed_up <binario> <repo-fonte> <gc|bd> [rotulo] -- o gate dos swaps.
# rc=0 so com prova (OK) ou com bypass DELIBERADO e ruidoso; qualquer outro
# estado, inclusive UNKNOWN, recusa (fail-closed: trocar o binario da cidade e
# a hora em que nao vale "provavelmente esta empurrado").
# Bypass: ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 (ex.: GitHub fora do ar num P0).
eb_require_backed_up() {
    local bin="$1" repo="$2" kind="$3" label="${4:-$1}" commit st detail hint
    if [ "${ENGINE_WINDOW_SKIP_BACKUP_CHECK:-0}" = "1" ]; then
        eb_log "!!! CHECK DE BACKUP IGNORADO para $label (ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 -- bypass deliberado)"
        if command -v notify >/dev/null 2>&1; then
            notify -p 4 -t 'Engine window: check de backup IGNORADO' \
                "swap de $label sem provar que o codigo-fonte tem backup (bypass deliberado)" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    if ! commit=$(eb_binary_commit "$bin" "$kind"); then
        eb_log "  backup ....... RECUSADO: $label nao traz commit no stamp (ldflags main.commit/main.Build) -- nao da pra provar que a fonte tem backup."
        return 1
    fi
    eb_fetch_all "$repo"
    st=$(eb_backup_state "$repo" "$commit")
    detail="${st#*|}"
    st="${st%%|*}"
    case "$st" in
        OK)
            eb_log "  backup ....... OK -- $label deriva de $commit ($detail)"
            return 0
            ;;
        MISSING)
            hint=$(eb_branch_hint "$repo" "$commit")
            eb_log "  backup ....... RECUSADO: $label deriva de $commit, que NENHUM remoto contem (a fonte do que rodaria so existe neste disco)."
            eb_log "                 Empurre antes de trocar: git -C $repo push origin ${hint:-<branch que contem $commit>}"
            ;;
        ORPHAN)
            eb_log "  backup ....... RECUSADO: $detail"
            ;;
        *)
            eb_log "  backup ....... RECUSADO: nao consegui provar o backup de $commit ($detail)."
            eb_log "                 Sem rede? Bypass deliberado: ENGINE_WINDOW_SKIP_BACKUP_CHECK=1"
            ;;
    esac
    return 1
}
