# Staging local efêmero do backup do hq (ga-gqllbc)

**Estado em uma linha:** `.dolt-backup/hq` (9,5 GB) deixou de ser uma cópia permanente. O backup noturno
constrói o staging do zero, sobe ao S3, **prova** que o S3 tem uma cópia idêntica e restaurável, e só
então apaga o staging. Quem apaga é o próprio sistema (o job das 04:00), nunca um agente com `rm -rf`.

## Por que

- Disco da máquina vive em 7-10 GB livres. O staging do hq era o maior bloco redundante (o S3 já tem a
  mesma cópia, provada restaurável) e era o que fazia a pré-revisão do gate recusar por "disco < 10 GiB"
  (ga-ufskhy: 44 de 46 bloqueadas).
- O portão de disco do próprio backup (150% do tamanho vivo = 14,4 GB para o hq) recusava **pelo espaço
  que o staging ocupava**: recusado em 22-25/09 e em 28/09-01/10. Sem o staging, o mesmo disco tem ~17 GB.
- Dolt 2.3.1 ainda não aceita `s3://` como destino de backup (`unknown url scheme: 's3'`, reconferido), então
  um staging local durante UMA execução não tem como sumir — só a permanência dele.

## O que mudou, por script

| Script | Para um db efêmero (default: `hq`) |
|---|---|
| `dolt-s3-backup.sh` (noturno) | pula o sync via servidor (o servidor guarda uma visão em cache do dir esvaziado → `table file not found`, ga-yct7r1), usa o sync offline; sobe ao S3; prova; **libera**. Também libera depois de uma noite recusada por disco, se o S3 estiver provado. |
| `mol-dog-backup.sh` (6h) | **pula** o db (aparece como `ephemeral: N` no resumo, um quarto estado) — recriar o staging seria desfazer tudo. |
| `dolt-backup-reseed.sh` | no-op bem-sucedido (não há o que re-semear). `RESEED_ALLOW_EPHEMERAL=1` força, à mão. |
| `dolt-restore-verify.sh` | sem backup local, confere o S3: fingerprint legível + manifest **fecha** + idade ≤ 36 h. Resultado `S3-OK`, **nunca** `OK` (não é um restore). |
| `mol-dog-doctor.sh` | sem artefatos locais, lê o frescor no fingerprint do S3. Não conseguir ler = "não medido", nunca "backup ausente". |
| `dolt-backup-status.sh` | lista o db como "SEM staging local POR DESENHO", sem erro e sem consultar a rede. |
| prompt do `gate-reviewer` | o revisor apaga o próprio scratch (~1 GB/revisão) antes de emitir o veredito; o `scratchpad-sweep` (ga-hynohs) continua recolhendo o resto 30 min depois. |

Código comum: `scripts/dolt-backup-ephemeral-lib.sh` (+ `.selftest.sh`).

## Configuração e kill switch

Arquivo local (gitignored): `$GC_CITY_PATH/.gc/config/dolt-backup-ephemeral.env`. Linha do arquivo > variável de
ambiente > default.

```bash
printf 'DOLT_BACKUP_EPHEMERAL_DBS=\n' > .gc/config/dolt-backup-ephemeral.env      # desliga TUDO (volta ao staging permanente)
printf 'DOLT_BACKUP_EPHEMERAL_DRYRUN=1\n' >> .gc/config/dolt-backup-ephemeral.env  # a prova do S3 roda, o rm não
```

Lista vazia = modo desligado. Arquivo que existe mas não pode ser lido = modo desligado **e** dry-run (na
dúvida, o staging fica). O noturno loga `ephemeral staging mode: on(hq)` / `off` no início de cada rodada.

## Como conferir

```bash
grep -E 'ephemeral staging' ~/gt/.gascity-gastown-hq/.gc/logs/dolt-s3-backup.log | tail     # released / REFUSED / not released
bash ~/gt/.gascity-gastown-hq/scripts/dolt-backup-status.sh                                  # hq: SEM staging local POR DESENHO
df -h /System/Volumes/Data                                                                  # o ganho: ~9,5 GB livres de forma permanente
```

Alarmes: `S3 NÃO provou cópia idêntica e restaurável logo após o upload` (notificação imediata; o staging é
**mantido**) e `staging local ... não foi liberado por 3 noites seguidas` (uma vez por sequência).

## Consequências (ditas, não escondidas)

1. **O portão de 150% continua valendo**, agora para um backup COMPLETO em vez de incremental. Passa muito mais
   vezes que antes, mas uma noite abaixo dele deixa o S3 sem refresco — o noturno avisa como hoje.
2. **Restaurar o hq do S3** (`aws s3 sync` + `dolt backup restore`, procedimento no fim de `dolt-s3-backup.sh`)
   precisa de ~19 GB livres (puxar + restaurar). Por isso o `dolt-restore-verify.sh` não faz esse restore para o
   hq; um drill de restore real do hq deve vir **depois** do `dolt gc --full` (ga-txsjgj) encolher o banco.
3. O portão "backup fresco" de **prune/flatten** do `dolt-gc-maintenance.sh` lê o staging local e fica fechado
   para o hq. Os dois estão desligados hoje; quem ligar precisa ensinar esse portão a ler o S3.
4. A alavanca do `dolt-gc-maintenance.sh` que libera o staging do hq para o `dolt_gc` continua no código, mas
   passa a achar quase sempre "nada a liberar" (o staging só existe durante a janela do noturno). O `dolt_gc`
   online continua exigindo ~2x o tamanho do hq livre; quem encolhe o hq de verdade é o `dolt gc --full`
   (ga-txsjgj), cuja condição (livre ≥ hq + 8 GB ≈ 17 GB) este ganho de ~9,5 GB passa a satisfazer.
