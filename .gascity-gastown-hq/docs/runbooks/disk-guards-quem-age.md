## Contents
- Estado em 2026-10-16
- Quem age, do primeiro degrau ao último
- Quem apaga o quê
- Reiniciadores do Dolt
- O que a medição mudou na proposta do bead
- Feito e pendente

## Estado em 2026-10-16

Volume Data em **98%** (4,8 GiB livres, 193 GiB usados) por volta das 08:00; o disk-pressure-monitor está em
STAGE-3 desde 07:53 ("genuinamente irremediável"; o `gc mail send mayor` dele falhou ou estourou o tempo).
Seis jobs têm ação sobre disco no código — dois deles estão hoje inertes (autoprune em dry-run, watchdog do WA cego) — e um só lê. Nenhuma guarda viva foi alterada pelo ga-j86sid — ver "Feito e pendente".

Tudo abaixo foi lido do script ou do log no dia; o que é inferência está dito.

## Quem age, do primeiro degrau ao último

Degraus em GiB livres no volume Data. O disk-pressure-monitor (DPM) fala em % usado; convertido com 193 GiB
usados: 85% ≈ 34 GiB livres, 92% ≈ 17, 97% ≈ 6.

| Degrau | Job | Roda a cada | O que faz | Modo hoje |
|---|---|---|---|---|
| ≈34 → ≈17 → ≈6 GiB | `com.gastown.disk-pressure-monitor` — `~/.gastown/scripts/disk-pressure-monitor.sh` (repo git próprio, fora do gate da cidade) | 1 h | 14 passos: tmp órfão, tarballs, snapshots de scraper (mantém 3), Trash, caches (go-build, go/pkg/mod, uv…), transcripts >7 d, scratchpads >2 d, go-build órfãos, dirs de teste do bd, git gc | ATIVO — 07:53: 98%, STAGE-3 |
| < 12 GiB | `com.gascity.disk-snapshot-guard` (LaunchDaemon, **root**) | 10 min | `tmutil thinlocalsnapshots` | ATIVO, sem efeito hoje (07:55: 5→5 GiB) |
| < 8 GiB WARN, < 3 GiB CRITICAL | `com.gascity.dolt-disk-floor-guard` (FG) | 5 min | 12 funções de reclaim (reapers de scratchpad e transcript, GOCACHE, órfãos, resíduo de backup…), `gc dolt-cleanup`, ressuscita o Dolt | ATIVO, em WARN (07:52: `avail=6GB`) |
| ≤ 2 GiB (recria a ≥ 15) | `com.gascity.disk-ballast-guard` | 2 min | só apaga/recria o próprio lastro de ~2 GiB e notifica; nunca chama `gc`/`bd` | ATIVO, ainda não disparou |
| sem degrau | `com.gascity.city-disk-autoprune` | 6 h | worktrees mergeadas, logs grandes, transcripts >7 d | **DRY-RUN** (`CITY_AUTOPRUNE_DRY_RUN=1` no plist). Últimas remoções reais: worktrees 12/09, transcripts 04/09 |
| 85% / 75% de `df /` | `com.whatsapp.disk-watchdog` (rig WA) | 30 min | 6 funções de limpeza | ATIVO mas **CEGO** — ver abaixo |
| — | `com.gascity.city-health-sentinel` | 4 min | só lê os GiB livres; `kickstart` do gate/pilot | não é guarda de disco |

**O watchdog do WA está cego.** `disk_pct()` é `df / | awk …`. No mesmo instante: `df /` → 71% (12 Gi usados,
volume de sistema selado); `df /System/Volumes/Data` → 98%. Ele loga "OK: disk 66% < 85%" com o disco em 98%; o
limiar de 85% só dispararia com menos de ~2 GiB livres. DPM e snapshot-guard leem `/System/Volumes/Data`.

## Quem apaga o quê

| Recurso | Apagam | Critério de cada um | Divergência |
|---|---|---|---|
| Scratchpads de sessão morta (`/private/tmp/claude-501/*/*/scratchpad`) | FG → `scratchpad-reaper.sh`; DPM passo 12 | reaper: sessão ausente de `gc session list` + idade; DPM: `find -mtime +2` no diretório | DPM não consulta sessão; mtime de diretório não registra edição de arquivo existente |
| Transcripts (`~/.claude/projects/**/*.jsonl`) | FG → `transcript-reaper.sh`; DPM passo 11; autoprune (dry-run) | reaper: sessão morta e ≥ 24 h; DPM: `-mtime +7 -delete` em **todo** projeto da máquina; autoprune: +7 d só no escopo da cidade | DPM sem escopo, sem checar sessão, sem log por arquivo, e leva `subagents/*.jsonl` |
| `~/.claude/history.jsonl` e `~/.claude/file-history/<sessão>` (ga-mnznp8, 18/10) | FG → `claude_home_trim.py`, no máximo 1×/h, em WARN e CRITICAL (só com o disco < 8 GB) | history: passou de 100 MB → mantém os últimos 40 MB a partir de uma quebra de linha, **no mesmo inode** (as ~20 sessões que o têm aberto seguem anexando; o `cp` diário das 04:00 para o S3 passa a levar só a parte mantida, e os transcripts em `projects/` seguem sincronizados à parte); file-history: pasta parada há ≥ 3 d, fora de `gc session list`, sem transcript recente e que não é a do chamador. Qualquer dúvida (gc falhou, resposta malformada, pasta ilegível) = não apaga | só o FG. `usage-analytics.jsonl` (171 MB) e `credit-cache-updater.log` (30 MB) só são **medidos** na mesma passada: o `log-token-usage.sh` grava `output_bytes` sempre 0 e o launchd `com.claude.credit-cache-updater` loga uma linha a cada 30 s — o conserto é na origem, não um corte |
| Cache do Go (`~/Library/Caches/go-build`) | FG; DPM; WA (cego) | FG: `go clean -cache` (≥ 3 GB; com go ativo só em CRITICAL); DPM: `rm` do conteúdo | DPM nunca checa go ativo (o teste de "ocupado" dele vale só para `gdrive_reader`). `go/pkg/mod` (2,1 GB liberados hoje) só o DPM limpa |
| go-build órfãos, code_sign_clone órfãos, dirs de teste do bd | FG; DPM passos 13, 8 e 14 | cada um tem o seu | critérios não comparados linha a linha |
| Snapshots de scraper | DPM passo 7 (mantém 3); WA (2 funções, cego) | — | — |
| Bancos Dolt órfãos; lastro; snapshots do Time Machine; Trash, tarballs e tmp órfão | um dono cada (FG; ballast; snapshot-guard; DPM) | — | nenhuma |

Medido hoje, para não superestimar: nenhuma sessão viva ou suspensa tem transcript com mais de 1 dia (82
transcripts ≥ 1 d, 142 MB, todos fora de `gc session list`; 16 deles, 92 MB, de outro projeto) e não há scratchpad
com mtime > 2 d. O risco da divergência é estrutural; não foi visto atingindo sessão viva. As remoções antigas do
DPM não dá para auditar — `-delete` não registra arquivo (551 execuções com MB liberados no log).

## Reiniciadores do Dolt

Complementares por gatilho, não três cópias:
- `com.gastown.dolt-server` (launchd `KeepAlive`): roda `gc dolt start`, um launcher. `launchctl list` mostra sem
  PID e última saída 0 — **inferido**: na prática só sobe no login.
- `dolt-hang-watchdog` (60 s): hang confirmado por N strikes e veto de CPU → `gc dolt restart` (o engine para o Dolt com SIGTERM; o watchdog não manda sinal nenhum). No máximo **1 restart por janela de backoff** (30 min, dobrando até 6 h); restart segurado escala ao Mayor (uma vez por hora) em vez de repetir. `DOLT_DUMP=1` religa o `kill -QUIT` pré-restart — opt-in, porque ele encerra o Dolt (ga-fzt548). Estado em `.gc/runtime/dolt-hang-watchdog.{strikes,cpuveto,restarts,escalated}`.
- FG (`_resurrect_dolt`): Dolt confirmado fora do ar com o disco seguro → `gc dolt start`.

Não verificado: se `gc dolt start` e `gc dolt restart` disparados no mesmo minuto são serializados pelo engine.

## O que a medição mudou na proposta do bead

1. "Sete guardas": são seis que agem e o sentinel só lê; o autoprune já é dry-run; o ballast só mexe no próprio
   arquivo; o WA está cego. Com limpeza relevante e ativa sobram DPM e FG (e o snapshot-guard, só Time Machine).
2. "Os demais viram alerta" não vale ao pé da letra: o DPM age a ≈34 GiB livres e o FG a 8. DPM só-alerta deixaria
   8–34 GiB sem limpeza, e é o DPM que segura o disco no dia a dia (log: 4.136 snapshots de scraper e 2.616
   scratchpads removidos). O remédio que cumpre o critério do bead ("1 só script com `rm` por recurso") é manter os
   degraus e fazer FG e DPM chamarem o mesmo reaper — `ga-88pmhi`.
3. Consertar o `df` do watchdog do WA ligaria um quarto limpador no meio da emergência — `wa-5wjfhg`.
4. Fora do escopo, mas mais grave que o resto: o snapshot-guard roda como root e executa um script que o usuário
   `athos` pode reescrever — `ga-xpswpd`.
5. Worktrees mergeadas não são a alavanca: o autoprune lista 23, 0,86 GiB.

## Feito e pendente

Feito no ga-j86sid:
- 34 plists `.bak`/`.disabled` + 1 em `.disabled/` saíram de `~/Library/LaunchAgents` para `docs/launchd-archive/`
  (README, MANIFEST com sha256). Critério "zero `.bak` em LaunchAgents": cumprido.
- `com.athos.post-reboot-recovery` aposentado (one-shot de 10/07 que nunca se removia; arquivado em `retired/`).
- `~/gt/dolt-server.port` (dizia 3307; o Dolt vivo usa outra porta) apagado: não achei leitor desse caminho (git grep no gt e no WA; grep em `~/.gastown`, `~/.property-scrapers`, `~/.local/bin`;
  os leitores do código usam `<beadsDir>/dolt-server.port`); `bd` e `gc` seguem funcionando. Textos que ainda o chamam de
  "velho" (`dolt-operational-awareness.md`, fragmento town-deltas, `claude.md` do townroot) continuam corretos no
  essencial — a porta vem do processo vivo — mas falam de um arquivo que não existe mais.

Não feito, de propósito: nenhuma guarda viva foi alterada. O disco está em emergência e o DPM é o que o mantém
vivo; e a proposta literal pioraria os degraus (item 2). Critério "1 só script com `rm` por recurso": **não
cumprido** para scratchpads, transcripts, cache do Go, go-build, code_sign_clone e dirs de teste do bd.

Pendente: `ga-88pmhi` (DPM → reapers), `ga-xpswpd` (script do root), `wa-5wjfhg` (watchdog cego),
`wa-pjq3ff` (symlink pendurado `com.urblink.inbound-review-3d.plist`).
