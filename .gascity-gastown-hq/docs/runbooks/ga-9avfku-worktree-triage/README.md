# ga-9avfku — triagem dos worktrees do motor e do framework (21/10/2026)

## Contents

- Resultado
- Tabela
- O que foi salvo e como recuperar
- Não feito (e por quê)

## Resultado

30 worktrees mortos removidos (2.192 MB) e 9 vivos mantidos com `git worktree lock` (motivo + bead dono). Nenhum commit nem arquivo não-publicado se perdeu: cada removido passou, no instante da remoção, por uma checagem que exige (a) HEAD num ref remoto, ou todo commit local com patch equivalente no remoto, ou patch salvo (exceção única: `ga-ljoz23-step1a-no-auto-dispatch`, cujo HEAD f99bb6f2a — o commit local de vendor do beads 1.3.0 — segue no ramo `fix/ga-vjlwso-vendor-beads-130-v2` do worktree vivo `engine-window-0919`), e (b) a sujeira reproduzida exatamente por um patch salvo (aplicar sobre o HEAD dá a mesma árvore do worktree), ou todo arquivo alterado já existente no histórico ou copiado aqui, e (c) nenhum processo com cwd dentro da árvore e nenhum arquivo ignorado que não seja dado derivado. Disco do mini: 7,8 GB → 9,6 GB livres (a bead falava em 3 GB; o número oscila com outras cargas, o ganho dos worktrees é os 2.192 MB).

O escopo foram as 38 árvores que o reaper listou em `kept-detached.txt`: 28 são do repo do motor (`_src-hookfix`) e 10 do repo do framework (`~/gt`) — por isso 13 nomes "não existiam" em `~/gt/.gc-worktrees`: moram em `.gascity-gastown-hq/.gc-worktrees` ou pertencem ao outro repo. A tabela tem 39 linhas porque inclui `ga-3risy2-dolt-hold`, criado depois da auditoria do Mayor (bead aberta, mantido e travado).

## Tabela

| worktree | repo | bead | estado (prova) | ação | MB |
|---|---|---|---|---|---:|
| fix-ga-ebbr2t | motor | ga-ebbr2t fechada | commits já no remoto (patch-id); limpo | removido | 86 |
| fix-ga-jg1sg8-dolt-backup-fd-leak | motor | ga-jg1sg8 fechada | commits já no remoto (patch-id); limpo | removido | 86 |
| fix-ga-q2i6b7-rigdb-resolution | motor | ga-q2i6b7 fechada | commit sem remoto = patch salvo; limpo | removido | 87 |
| ga-h9xpwb-engine | motor | ga-h9xpwb fechada | HEAD no remoto (origin/consolidated/engine-window-20260926); dirt == ga-h9xpwb-read-mail-not-work.patch (round-trip exato) | removido | 87 |
| ga-punx6-keyset-cursors | motor | ga-punx6 fechada | commit sem remoto = patch salvo; dirt == ga-punx6-keyset-cursors.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 86 |
| gt-69j2v-hasassignedwork | motor | gt-69j2v fechada | HEAD no remoto (origin/fix/gt-69j2v-hasassignedwork-wip); limpo | removido | 86 |
| fix-ga-4ibmk6-demand-snapshot | motor | ga-4ibmk6 fechada | HEAD no remoto (origin); dirt == ga-4ibmk6-ephemeral-tier-unassigned-serverside-filter.patch.APLICADO-20260919 (round-trip exato) | removido | 86 |
| fix-ga-k7o6ou-dolt-loopback | motor | ga-k7o6ou fechada | commits locais == patch (ga-k7o6ou-dolt-bind-loopback.patch); limpo | removido | 87 |
| ga-35cyh5-named-always-wake | motor | ga-35cyh5 fechada | HEAD no remoto (origin/consolidated/engine-window-20260926); dirt == ga-35cyh5-named-always-wake.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 87 |
| ga-42mlf-text-veto-pool-filter | motor | ga-42mlf fechada | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-42mlf-text-veto-pool-filter.patch.APLICADO-20260902 (round-trip exato) | removido | 83 |
| ga-6bghe-gate-inflight-exclude | motor | ga-6bghe fechada | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-6bghe-gate-inflight-exclude-labels.patch.APLICADO-20260829b (round-trip exato) | removido | 83 |
| ga-7sy6j-nudge-suspended-check | motor | ga-7sy6j inexistente | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-7sy6j-nudge-suspended-check.patch.APLICADO-20260829 (round-trip exato) | removido | 83 |
| ga-8fwusw-prompt-failclosed | motor | ga-8fwusw fechada | HEAD no remoto (origin); dirt == ga-8fwusw-prompt-failclosed.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 86 |
| ga-98tv30-model-table | motor | ga-98tv30 fechada | HEAD no remoto (origin); dirt == ga-98tv30-model-table.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 86 |
| ga-ebbr2t-tmux-live-session-guard | motor | ga-ebbr2t fechada | HEAD no remoto (origin); dirt == ga-ebbr2t-tmux-live-session-guard.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 86 |
| ga-f9zou-hookfix | motor | ga-f9zou fechada | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-f9zou-hookfix.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 83 |
| ga-i5bu7-molecule-step-filter | motor | ga-i5bu7 fechada | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-i5bu7-molecule-step-filter.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 83 |
| ga-j96y0n-nudge-dead-ttl | motor | ga-j96y0n fechada | HEAD no remoto (origin); dirt == ga-j96y0n-nudge-dead-ttl.patch (round-trip exato) | removido | 86 |
| ga-jl8rz-events-since-pagination | motor | ga-jl8rz fechada | HEAD no remoto (origin/fix/ga-p1c6p-sling-molecule-rollback); dirt == ga-jl8rz-events-since-window-pagination.patch.APLICADO-20260829 (round-trip exato) | removido | 83 |
| ga-ljoz23-step1a-no-auto-dispatch | motor | ga-ljoz23 fechada | HEAD f99bb6f2a mantido no ramo local do engine-window-0919; dirt == ga-ljoz23-step1a-no-auto-dispatch.patch (round-trip exato) | removido | 92 |
| ga-olsi9d-rebase-patches | motor | ga-olsi9d fechada | HEAD no remoto (origin/consolidated/engine-window-20260919); dirt == ga-olsi9d-rebase-patches.dirty.patch.SUPERSEDED-20261021 (round-trip exato) | removido | 87 |
| ga-skuoh-refinery-test-command | motor | ga-skuoh fechada | HEAD no remoto (origin/consolidated/engine-window-20260919); dirt == ga-skuoh-refinery-test-command-var.patch.APLICADO-20260919 (round-trip exato) | removido | 87 |
| ga-6u64fm-dog-store-migrate | framework | ga-6u64fm fechada | commit sem remoto = patch salvo; arquivos já no histórico ou copiados | removido | 40 |
| ga-vs6shu-worktree-reaper-lock | framework | ga-vs6shu fechada | commits já no remoto (patch-id); arquivos já no histórico ou copiados | removido | 39 |
| feat-ga-4q2zo5-e12-write-3state | framework | ga-4q2zo5 fechada | commits já no remoto (patch-id); arquivos já no histórico ou copiados | removido | 48 |
| feat-ga-dzzqvw-1-tally | framework | ga-dzzqvw fechada | HEAD no remoto (fork/feat/ga-dzzqvw.1-tally); dirt == feat-ga-dzzqvw-1-tally.dirty.patch (round-trip exato) | removido | 52 |
| fix-ga-67hae-reviewer-drain-exempt | framework | ga-67hae inexistente | commits já no remoto (patch-id); arquivos já no histórico ou copiados | removido | 22 |
| fix-ga-8q1ulq-symbol-reachability | framework | ga-8q1ulq fechada | commits já no remoto (patch-id); dirt == fix-ga-8q1ulq-symbol-reachability.dirty.patch (round-trip exato) | removido | 37 |
| ga-hnn7l-pool-settings-overlay | framework | ga-hnn7l inexistente | commits já no remoto (patch-id); arquivos já no histórico ou copiados | removido | 32 |
| fix-wa-th4b1-symbol-reachability | framework | wa-th4b1 fechada | HEAD no remoto (fork/fix/wa-th4b1-daemon-refresh-symbol-reachability); dirt == fix-wa-th4b1-symbol-reachability.dirty.patch (round-trip exato) | removido | 36 |
| engine-window-0919 | motor | ga-vjlwso ABERTA | commit f99bb6f2a (vendor beads 1.3.0, 1015 arquivos) só no ramo local fix/ga-vjlwso-vendor-beads-130-v2 | **mantido + git worktree lock** | 92 |
| engine-window-1011b | motor | — (janela corrente) | workspace de engine-window-run.sh (ENGINE_WINDOW=20261011b); bin/ = 233 MB de build; limpo, HEAD publicado | **mantido + git worktree lock** | 320 |
| ga-0y849e-dolt-cli-memo | motor | ga-0y849e ABERTA | sujeira = ga-0y849e-dolt-wait-ready-cli-spawn.patch, que NÃO está no git (só em disco); `gc` ignorado de 256 MB, regenerável | **mantido + git worktree lock** | 356 |
| ga-3dhb91-builtin-models-5-5 | motor | ga-3dhb91 ABERTA | sujeira = ga-3dhb91-builtin-models-5-5.patch (rastreado) — redundante | **mantido + git worktree lock** | 87 |
| ga-3risy2-dolt-hold | motor | ga-3risy2 ABERTA (gate-fix) | 13 arquivos de trabalho ÚNICOS, sem patch salvo em lugar nenhum | **mantido + git worktree lock** | 87 |
| ga-epdbe3-crew-drift | motor | ga-epdbe3 ABERTA | limpo e HEAD publicado — redundante | **mantido + git worktree lock** | 87 |
| ga-me6wsb-suspend-stop | motor | ga-me6wsb ABERTA | sujeira diverge do patch staged (1 arquivo ÚNICO) | **mantido + git worktree lock** | 95 |
| ga-3kmvyr | framework | ga-3kmvyr ABERTA | 4 arquivos ÚNICOS (lab de restore MBP) sem ref remoto | **mantido + git worktree lock** | 54 |
| ga-w7qwl1.1.8-provider-gui-domain | framework | ga-w7qwl1.1.8 ABERTA | 3 arquivos modificados ÚNICOS (gc-session-ssh) | **mantido + git worktree lock** | 58 |

## O que foi salvo e como recuperar

Sufixo `.SUPERSEDED-<data>` em `docs/pending-engine-window/` é o marcador que o `engine-window-backlog-guard.sh` conta como JÁ RESOLVIDO; um `.patch` cru ali seria lido como pendente e entraria na fila da próxima janela de engine. Por isso os diffs do motor NÃO foram gravados como `<nome>.dirty.patch` (nome literal pedido na bead): são `<nome>.dirty.patch.SUPERSEDED-20261021`. Os do repo do framework ficam neste diretório.

Para reaplicar um diff sujo: `git worktree add --detach <caminho> <sha-base>` e depois `git -C <caminho> apply <patch>`.

| patch | repo | sha base |
|---|---|---|
| docs/pending-engine-window/ga-35cyh5-named-always-wake.dirty.patch.SUPERSEDED-20261021 | motor | ae3833456a692e0c341661f77dfdf4b5a9980450 |
| docs/pending-engine-window/ga-8fwusw-prompt-failclosed.dirty.patch.SUPERSEDED-20261021 | motor | 08d7ef78810b7f9e89730d8ee7d44bd6f572da08 |
| docs/pending-engine-window/ga-98tv30-model-table.dirty.patch.SUPERSEDED-20261021 | motor | 08d7ef78810b7f9e89730d8ee7d44bd6f572da08 |
| docs/pending-engine-window/ga-ebbr2t-tmux-live-session-guard.dirty.patch.SUPERSEDED-20261021 | motor | 08d7ef78810b7f9e89730d8ee7d44bd6f572da08 |
| docs/pending-engine-window/ga-f9zou-hookfix.dirty.patch.SUPERSEDED-20261021 | motor | 64dc28fcc76fe4bf57371a5253450773af3b49e2 |
| docs/pending-engine-window/ga-i5bu7-molecule-step-filter.dirty.patch.SUPERSEDED-20261021 | motor | 64dc28fcc76fe4bf57371a5253450773af3b49e2 |
| docs/pending-engine-window/ga-olsi9d-rebase-patches.dirty.patch.SUPERSEDED-20261021 | motor | a1f30af181b81e09cb49174bd5202073684c08d1 |
| docs/pending-engine-window/ga-punx6-keyset-cursors.dirty.patch.SUPERSEDED-20261021 | motor | cd2b10f426145e7c744f1aee4b003b111809e57a |
| feat-ga-dzzqvw-1-tally.dirty.patch | framework | 00511cc2defafcad251a57a87eb11b55664287a7 |
| fix-ga-8q1ulq-symbol-reachability.dirty.patch | framework | 9c65f715a79d753d71a232c5c244d1ad0c126ef3 |
| fix-wa-th4b1-symbol-reachability.dirty.patch | framework | 63294323a2bc0fa8c1d6cbfcbc25c4342080cd8c |

Outros itens guardados: `docs/pending-engine-window/ga-punx6-keyset-cursors.commit-cd2b10f42.patch.SUPERSEDED-20261021` (commit do upstream que não está em nenhum ref remoto do repo do motor), `ga-6u64fm-dog-store-migrate.commit-53e19c393.patch` (único commit do ga-6u64fm sem equivalente no remoto) e três arquivos untracked únicos (`*.untracked.*`). O resto do untracked dos worktrees do framework já existia no histórico git ou era dado derivado (`.gc/system/packs/**`, materializado pelo `gc` quando roda dentro do worktree).

Os commits locais dos ramos `fix/ga-q2i6b7-rigdb-resolution`, `fix/ga-k7o6ou-dolt-loopback` e `fix/ga-vjlwso-vendor-beads-130-v2` continuam nos ramos locais do repo do motor (remover o worktree não apaga o ramo); os dois primeiros também são idênticos a patches rastreados em `docs/pending-engine-window/`.

## Não feito (e por quê)

- **Fora de `.gc-worktrees`, não listados pelo reaper, intocados:** `.local-patches/_worktrees/ga-dx5z9-hook-ephemeral-filter` (83 MB) e `.local-patches/_wt-ga-f9zou` (83 MB) — sujeira idêntica a patches `APLICADO` rastreados, removíveis; `.local-patches/_worktrees/ga-epdbe3` (87 MB) — bead aberta, 2 arquivos únicos.
- **Vivos mas redundantes** (o dono pode soltar quando quiser): `ga-3dhb91-builtin-models-5-5` (87 MB) e `ga-epdbe3-crew-drift` (87 MB); em `ga-0y849e-dolt-cli-memo` o binário ignorado `gc` ocupa 256 MB e se regenera com `go build`.
- **Risco aberto, de outro dono:** `ga-0y849e-dolt-wait-ready-cli-spawn.patch` existe só em disco (não está no git) e `ga-3risy2-dolt-hold` tem 13 arquivos de trabalho sem cópia em lugar nenhum. Nenhum dos dois foi tocado.
- Nada foi enviado a remoto (`git push`): só o commit local no `main` do `~/gt`.
