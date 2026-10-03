# LexBH — Batista (Crew Worker)

You are crew worker **batista** in the **lexbh** rig.

## O que é o LexBH

Sistema de inteligência legislativa para a UrbLink — intermediadora de terrenos em BH.
Monitora legislação da CMBH (Câmara Municipal de BH) relevante para incorporação imobiliária.

## Contexto de Negócio (CRÍTICO para o LLM)

A UrbLink encontra e monta áreas em BH para vender a incorporadoras.
Legislação que **aumenta potencial construtivo** é positiva para o negócio:
- Coeficiente de aproveitamento maior
- Gabaritos mais altos
- Afastamentos menores
- Novos usos permitidos
- ZEIS, OUS, upzoning em geral

## Design aprovado

`docs/superpowers/specs/2026-03-30-lexbh-design.md`

**Resumo da arquitetura:**
- Fonte: CMBH (pesquisar-legislacao + pesquisar-proposicoes)
- Stack: Python + SQLite + DeepSeek + Flask
- Porta: localhost:7842
- Frequência: scraping semanal (domingo)
- 3 módulos: Acervo (busca semântica) | Radar (novidades) | Vigília (tramitação)

## Credenciais

- DeepSeek: já disponíveis no ambiente (verificar config existente)

## Timezone

BRT (UTC-3). SQLite: `datetime('now','localtime')`. Python: `datetime.now()`.

## Mockups para Athos — página Mockups do admin (OBRIGATÓRIO)

Mockup NÃO vai mais pro S3 (wa-cyvf1f): `publicar_mockup.py` grava na página Mockups do admin, atrás do Cloudflare Access, e imprime a URL PERMANENTE `https://admin.urblink.com.br/mockups/<slug>` — não expira, então não há chave nem link temporário pra gerar. Links antigos de `mockups/` no bucket seguem valendo até expirar; não publique nada novo lá.
NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.
```bash
python3 /Users/athos/gt/whatsapp_automation/scripts/publicar_mockup.py dirA.html \
  --titulo "<nome do mockup>" --bead <id-do-bead> \
  --grupo <slug-do-mockup> --direcao A --tradeoff "Ganha: … Perde: …"
# → a linha "✓ publicado: <URL>" é o que você apresenta ao Athos
```
⚠️ Use SEMPRE esse caminho ABSOLUTO, de qualquer cwd: rodar `scripts/publicar_mockup.py` de dentro de um worktree sai 3 sem publicar nada. Códigos de saída: 0 publicado; 1 recusado (dado pessoal ou entrada inválida); 3 erro de infraestrutura — NADA foi publicado; 4 FICOU gravado mas a conferência falhou — NÃO republique (duplica), confira `https://admin.urblink.com.br/mockups`; 2 é uso errado da linha de comando.
Mockup NOVO (1ª versão): 3-4 direções visuais distintas, uma chamada por arquivo com o mesmo `--grupo` e uma letra de `--direcao` cada, apresentadas via AskUserQuestion (1ª opção = sua recomendação). Passo a passo completo: skill `wa-worker-session-protocol`.

🚨 NUNCA publique CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica num mockup. O script varre o HTML e recusa sozinho (exit 1), mas em exemplo use número obviamente falso (98888-7777). Dossiê de pessoa ou imóvel específico não é mockup.

## Notifications
```bash
notify 'Work complete: <description>'
```
