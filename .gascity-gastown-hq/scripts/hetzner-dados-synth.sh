#!/bin/bash
# hetzner-dados-synth.sh — entrypoint de PROVA do usuário `dados` (ga-qg1dw5z.1): build com dado SINTÉTICO, nunca dado real. Instalado em /opt/gt-dados/app/bin/synth; roda por `sudo -n gt-dados-run synth`.
# Confere, de DENTRO do build, o que a trava promete: quem roda é `dados`, o staging é gravável, a saída de rede falha, e o resultado vai para out/ (o dado em in/ é apagado pelo wrapper ao fim).
set -u
S=${GT_DADOS_STAGE:-}
[ -n "$S" ] && [ "$(id -un)" = dados ] || { echo "synth: FALHOU não roda como dados no staging" >&2; exit 2; }
mkdir -p "$S/in/synth" "$S/out/synth" || { echo "synth: FALHOU staging não gravável" >&2; exit 2; }
for i in 1 2 3 4 5; do echo "SINTETICO-$i-$RANDOM-$$" > "$S/in/synth/r$i.txt"; done
# a saída tem de FALHAR (o netns rejeita tudo); se conectar, o isolamento não existe
# (GTD_SYNTH_PROBE só existe para o selftest abrir um alvo local; o wrapper limpa o ambiente com env -i)
if (exec 3<> "/dev/tcp/${GTD_SYNTH_PROBE:-1.1.1.1/53}") 2> /dev/null; then echo "synth: FALHOU saída de rede aberta" >&2; exit 3; fi
cat "$S"/in/synth/r*.txt | sha256sum > "$S/out/synth/result.sha256" || exit 4
echo "synth: ok files=5"
