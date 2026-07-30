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

## Mockups para Athos — S3 presigned URL (OBRIGATÓRIO)

⚠️ O bucket é PÚBLICO (`PublicReadAccess` + ACLs desligadas) — `presign` é decorativo, não protege nem expira; a distro CloudFront (`dnroc49bwlbis.cloudfront.net`) também serve sem gate. Única barreira real = obscuridade da chave (wa-68jmm/wa-3o6wf).
NUNCA entregue mockup como PNG, localhost ou tunnel (cloudflared já deu 404). Athos decide VENDO no celular.
```bash
python3 -c "import secrets; print(secrets.token_hex(8))"  # chave de alta entropia
aws s3 cp <arquivo.html> s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --content-type "text/html; charset=utf-8"
aws s3 presign s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --expires-in 604800
# → envie esse URL ao Athos
```

🚨 NUNCA suba CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado que identifique uma pessoa específica nesse bucket — o link é público pra sempre.

## Notifications
```bash
notify 'Work complete: <description>'
```
