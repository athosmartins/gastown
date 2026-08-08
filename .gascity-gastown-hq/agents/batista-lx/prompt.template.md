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

⚠️ `mockups/` NÃO é mais anônimo-legível, e o `presign` é hoje o que TE DÁ acesso — a redação anterior aqui dizia o oposto ("presign é decorativo, não protege nem expira"), verdadeira em 25/07 e FALSA desde 31/07. A policy do bucket tem o Sid `DenyAnonymousReadOnBackupsDraftsAndMockups`, um Deny de `s3:GetObject` para `Principal:*` em `mockups/*` (idem `backups/*`, `estudos/*`, `discador-mockups/*`, `pending_drafts.json`), cuja Condition exclui `aws:PrincipalAccount: 549710416969`. Como a URL presigned assina COM a conta, o Deny não se aplica a ela — medido: sem assinatura 403, presigned 200 (wa-hvh10 + wa-ge8bs; verificação de thies-wa em 08/08, conferida contra a policy viva). ⚠️ O resto do bucket segue público por `PublicReadAccess`, e a distro CloudFront não passa pela assinatura — então isto vale para os prefixos negados acima, não para o bucket inteiro. Continue usando chave de alta entropia: ela não é mais a única barreira, mas ainda é uma.
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
