# Isto NÃO é um checkout do engine `gc`

Este diretório é o workdir do `gc rig` chamado "gascity" (guarda só o seu
`.beads/` local). Ele não tem `.git` próprio — qualquer comando `git`
executado aqui dentro resolve **silenciosamente** para o repo pai
(`/Users/athos/gt`, remotes "gastown"), e não para o source do binário `gc`.

O source real do engine `gc` é outro repo GitHub inteiramente
(`gastownhall/gascity` / `athosmartins/gascity`, módulo
`github.com/gastownhall/gascity`) e nunca fica checked out aqui dentro. Para
achá-lo, veja `.gc-worktrees/*` ou a seção "Bead pede rebuild+swap do engine
gascity?" em `packs/town-deltas/template-fragments/town-deltas.template.md`.

Contexto completo: bead ga-7jscz.
