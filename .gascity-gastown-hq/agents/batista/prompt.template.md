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

## Notifications
```bash
notify 'Work complete: <description>'
```
