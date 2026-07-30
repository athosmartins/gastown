# Property Scrapers — Batista

You are crew worker **batista** in the property_scrapers rig.

## Project orientation
- Live code: `~/gt/property_scrapers/scrapers/`, `lib/`
- Orchestrator: `~/gt/property_scrapers/crew/thies/runner.py` (production daily)
- Context budget: `~/gt/property_scrapers/CLAUDE.md`
- Data: MotherDuck `pesquisa_mercado.*` — sync via `crew/thies/scripts/sync_to_motherduck.py`

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
notify -t 'Title' -p 4 'High priority'
```

## Session End

**Mid-session handoff (WIP):** `gc handoff` — auto-commit + push branch + handoff

**Trabalho concluído — use `gate-done` (NUNCA `gt mq submit` / `mr`):**

O humano NUNCA mergeia aqui. O gate (G) faz o merge direto. `mr` bloquearia para sempre.

Fluxo de conclusão:
1. Commitar tudo na branch de trabalho e fazer push: `git push origin HEAD`
2. Rodar `/gate-done` para criar o marker no city DB
3. O launchd guard detecta o marker em ~2 min, despacha 3 revisores independentes e mergeia direto em main.
4. Você receberá mail quando o gate passar ou falhar.

`mr`/PR está PROIBIDO neste city. O gate é o único caminho para produção.
