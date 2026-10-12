# Publicar o site urblink.com.br

## Contents

• Como o site é publicado · Quem tem acesso
• Variáveis de ambiente (nomes apenas; valores no Bitwarden, nunca no repositório)
• Antes de dar merge no main · Rollback · Fila de espera (convite para a plataforma de terrenos)
• Pontos em aberto

## Como o site é publicado
- Código: repositório **privado** `athosmartins/v0-urb-link-website-structure` (Next.js 16 / React 19, criado no v0.app). Não é um rig da cidade; trabalhe numa cópia fora de `~/gt` (ex.: `gh repo clone athosmartins/v0-urb-link-website-structure /private/tmp/claude-501/site-urblink/repo`).
- **Push no `main` = produção na hora.** A integração GitHub → Vercel publica cada commit do `main` (deploys "Production" feitos pelo `vercel[bot]`). O `main` não tem proteção (o plano do GitHub não permite), então **nada impede um push direto**: use sempre branch + pull request.
- **Pull request = prévia.** Cada PR gera uma prévia da Vercel (URL `…-git-<branch>-athosmartins-4490s-projects.vercel.app`). As prévias ficam **atrás do login da Vercel** (respondem 302); quem está logado como Athos abre.
- Há **dois projetos Vercel** construindo o mesmo repositório: `v0-urb-link-website-structure` e `v0-urblink` (ambos aparecem como checks "Vercel – …" no PR). Qual deles serve o domínio `urblink.com.br` ainda não foi confirmado (precisa de acesso ao painel; ver "Pontos em aberto").
- A Vercel **bloqueia** o deploy se o autor do commit não for uma conta verificada do time (11/10: commit com autor `mayor@gascity.local` → "Deployment was blocked"). Faça os commits com o autor `athosmartins <athosmartins@gmail.com>` (é a conta que já faz o push) e deixe o trailer `Co-Authored-By` para registrar o agente.

## Quem tem acesso
- `gh` autenticado como `athosmartins` no mini: **admin** do repositório (permissões admin/maintain/push). Serve para branch, PR, merge e para ler os checks.
- **Vercel CLI 54.1.0 está instalado, mas sem login** (`vercel whoami` pede login interativo; não há token da Vercel no Bitwarden/`SECRETS.md`). Sem isso um agente **não consegue** configurar variáveis de ambiente nem promover/reverter deploys pela linha de comando. Opções: o Athos entra uma vez com `vercel login` (ou cria um token e guarda no Bitwarden como `vercel-token`) ou configura pelo painel.

## Variáveis de ambiente (nomes apenas; valores no Bitwarden, nunca no repositório)
- `FILA_ESPERA_API_URL` — endereço do endpoint da fila (bead wa-l4or3v).
- `FILA_ESPERA_HMAC_SECRET` — segredo compartilhado da assinatura HMAC-SHA256.
- Configurar em **Production e Preview**. Sem elas a rota `/api/fila-espera` responde 503 e a tela mostra "Tentar de novo".
- Já existe `GOOGLE_SCRIPT_URL` (formulário "Avaliar meu terreno", rota `/api/submit`): não mexer.

## Antes de dar merge no main
1. PR aberto com a prévia verde nos dois checks da Vercel; abrir a prévia no celular e no desktop.
2. Backend da fila no ar e as duas variáveis configuradas (senão o convite entra em produção e mostra erro).
3. `npx tsc --noEmit` e `npx next build` sem erro (o `npm run lint` não roda: o repositório não tem eslint instalado).
4. Fluxo completo testado contra o endpoint real com uma entrada de teste, depois apagada da tabela.
5. Só então o merge (squash). Conferir `curl -s https://urblink.com.br | grep "Para incorporadoras"` após o deploy.

## Rollback
- Pelo painel da Vercel: abrir o projeto que serve o domínio → Deployments → o último deploy bom → **Promote to Production** (instantâneo, sem novo build). Pela CLI (precisa de login): `vercel promote <url-do-deploy-anterior>`.
- Pelo Git: `git revert <commit>` numa branch + PR + merge (publica o revert).
- A faixa/seção do convite some sozinha com o revert; a tabela `fila_espera` do backend não é afetada.

## Fila de espera (convite para a plataforma de terrenos)
- Telas: faixa dispensável acima do cabeçalho + seção "Para incorporadoras" logo após o hero + item "Incorporadoras" no menu/rodapé; formulário empresa → nome → WhatsApp (sem confirmação) → "Você entrou na fila".
- Rota `app/api/fila-espera/route.ts`: zod, campo-armadilha + tempo mínimo, encaminha ao backend com assinatura HMAC (`X-Fila-Timestamp`, `X-Fila-Signature: sha256=<hmac de "timestamp.corpo">`, `X-Fila-Client-Ip`). Telefone nunca é registrado em log.
- Beads: ga-x2m4jt (tela, PR #1), wa-l4or3v (backend e tabela).

## Pontos em aberto
- Confirmar qual projeto Vercel serve `urblink.com.br` e se o segundo é um resto a desligar.
- Login da Vercel para agentes (token) — sem ele, variáveis de ambiente e rollback dependem do Athos.
- Página de política de privacidade: o site não tem; o texto de consentimento do formulário está sem link.
