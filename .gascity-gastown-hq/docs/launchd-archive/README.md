## Contents
- O que é
- Como restaurar
- Aposentado: post-reboot-recovery

## O que é

Plists inertes que viviam em `~/Library/LaunchAgents` ao lado dos jobs vivos: `*.plist.bak-*`,
`*.plist.disabled-*` e o diretório oculto `.disabled/`. Movidos para cá em 2026-10-16 (ga-j86sid):
**34 arquivos + 1 em `.disabled/`** (o título do bead dizia 33; era a contagem do dia anterior).

Antes de mover, conferido em 2026-10-16:
- nenhum termina em `.plist`, então o launchd não os carrega;
- nenhum código rastreado do gt nem do whatsapp_automation os referencia (`git grep 'plist\.(bak|disabled)'`);
- varredura de forma de segredo no texto cru: zero acertos (chaves e valores não foram impressos);
- `com.whatsapp.kanban-digest.plist.bak-20260726-001316` não é XML válido (erro na linha 34) — por isso foi
  mantido tal como está, sem tentar consertar.

Dois deles eram symlinks para `whatsapp_automation/crew/oracle/daemons/launchd/`. Aqui estão como cópia do
CONTEÚDO; o `MANIFEST.tsv` marca `kind=symlink` e guarda o alvo original.

## Como restaurar

`MANIFEST.tsv` tem, por arquivo: nome arquivado, caminho original, tipo, alvo do symlink, tamanho, mtime e sha256.

```
cp docs/launchd-archive/<nome> ~/Library/LaunchAgents/<nome>
```

Os de `dot-disabled/` voltam para `~/Library/LaunchAgents/.disabled/`. Copiar de volta não reativa nada: para
um job rodar, o nome tem de terminar em `.plist` e alguém precisa dar `launchctl bootstrap gui/$(id -u) <plist>`.
Isso é decisão do dono do job, não deste arquivo.

## Aposentado: post-reboot-recovery

`retired/com.athos.post-reboot-recovery.plist` + `retired/post_reboot_recovery.sh`.

Era um one-shot do incidente de disco cheio de 2026-07-10: o cabeçalho diz "roda UMA vez no primeiro login e
se auto-remove". Medido em 2026-10-16: o plist e o script continuavam em disco (script de 10/07), o job não
estava carregado no launchd (`launchctl print` → "Could not find service") e o plist tem `RunAtLoad`, então
pode disparar a cada login; a saída mais recente em `/tmp` é de 2026-10-15 23:43–23:46.

Causa provável da auto-remoção nunca completar (inferida, não reproduzida): o script chama
`launchctl bootout` do próprio label ANTES dos `rm -f`; o bootout encerra o processo em execução e os `rm`
não chegam a rodar.

O que a execução de 2026-10-15 23:43 (log em `/tmp/post_reboot_recovery.log`) mostrou que ele fazia, passo a passo:
- religar `com.scrapers.daily`: já estava carregado pelo launchd (`daily: loaded OK`), passo redundante;
- `gc dolt status`: falhava (`gc: unknown command "dolt"`), então o passo de Dolt já estava quebrado;
- pré-baixar o modelo bge-m3: já em cache (`bge-m3: cached OK`), nada a baixar;
- mandar ao Athos uma notificação com texto escrito em julho ("Falta subir Chrome CDP + Mayor (manual)").

Como o job não estava carregado, não foi preciso `bootout`. Os dois arquivos foram removidos de `~/Library/LaunchAgents`
e de `~/.property-scrapers` durante o ga-j86sid; as cópias estão em `retired/`.
