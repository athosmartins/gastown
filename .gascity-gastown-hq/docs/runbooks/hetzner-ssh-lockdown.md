# Hetzner: SSH fechado (admin com chave própria, fail2ban, firewall, root sem login) · runbook

## Contents

• Estado medido em 11/11 · O que o Athos precisa dar (3 itens, nenhum é técnico)
• Instalação (root, uma vez) · A ordem e cada passo
• As provas da história (rodar depois do rootcut, antes do confirm)
• Redes de segurança e como desfazer · Firewall da Hetzner Cloud (fica para quando houver token)
• O que este script NÃO prova

Bead ga-qg1dw5z.2 (trava 2 de 3; a 1 é o usuário `dados` sem sudo, a 3 é a auditoria). O alvo é o nó `hetzner-teste` (2.31.41.222). Tudo é um script só, `scripts/hetzner-ssh-lockdown.sh`, que roda **como root no nó** e tem selftest hermético (`scripts/hetzner-ssh-lockdown.selftest.sh`, 29 mutantes). Nenhum passo é comando improvisado ao vivo: cada um só avança com a PROVA do anterior e os dois que podem trancar o servidor para fora (`ufw`, `rootcut`) armam, antes de agir, um timer que desfaz sozinho em 10 min.

## Estado medido em 11/11

* A chave do `runner` (`hetzner_teste_urblink`, só existe no mini) entra como **root**; o `runner` não tem sudo. Por isso quem aplica isto é o dog do mini (ou o Athos), nunca um `dog-remote-N`.
* `ufw` instalado e **inativo** (`ENABLED=no`); `fail2ban` **ausente** (disponível no apt, 1.0.2); sshd 9.6p1 com `ssh.socket`; `Include /etc/ssh/sshd_config.d/*.conf` no topo (drop-in vale).
* Única porta pública: 22. O túnel de volta é `127.0.0.1:2293` (não passa pelo firewall); o espelho git usa a mesma 22.
* O mini tem 2 conexões vivas que não podem cair: o túnel 2293 e o espelho. Os dois entram como `runner`.

## O que o Athos precisa dar (3 itens, nenhum é técnico)

1. **A chave pública do admin** (ed25519, a privada fica só no Bitwarden dele; nenhum agente a lê). Um arquivo `.pub` com uma linha.
2. **Um token da API da Hetzner Cloud com permissão de firewall**, guardado no Bitwarden no item `hcloud`. Sem ele a camada "firewall da nuvem" não existe (o `ufw` do nó cobre o essencial até lá).
3. **Confirmar que consegue abrir o console da Hetzner** (a saída de emergência se um passo trancar o servidor).

## Instalação (root, uma vez)

Numa sessão de root no nó (a chave de root do mini, ou o console):

```bash
install -m 0700 -o root -g root /caminho/do/repo/.gascity-gastown-hq/scripts/hetzner-ssh-lockdown.sh /usr/local/sbin/gt-ssh-lockdown
gt-ssh-lockdown status      # só lê
gt-ssh-lockdown origins     # só lê: de que IP o runner/root entram hoje
```

`origins` responde "o IP do mini é fixo?" a partir do `auth.log`. Enquanto isso não estiver provado, `ufw --ssh-from any` + fail2ban é o padrão (o IP do Athos também precisa entrar como admin); uma lista de IPs só entra depois de provada.

## A ordem e cada passo

**Aplique a trava 1 (ga-qg1dw5z.1, usuário `dados`) ANTES do `rootcut`**: ela usa o root atual. O `rootcut` recusa se o usuário `dados` não existir (override explícito: `--sem-trava1 "motivo"`, que fica no log do nó).

1. `gt-ssh-lockdown admin --user NOME --pubkey-file /caminho/admin.pub`. Cria o usuário (sudo, senha travada), instala SÓ a chave pública (ed25519/ecdsa, sem opções, uma única) e grava a hora e o fingerprint. Recusa nome reservado (`root`, `runner`, `dados`…), chave privada, RSA, duas chaves, e trocar a chave de um admin que já existe (precisa de `--replace`).
2. **Prova do admin (quem faz é o Athos)**: de uma **sessão NOVA**, `ssh NOME@2.31.41.222` com a chave dele e `sudo -n true`. Não feche a sessão de root. O script não tem a chave privada e não precisa dela: o `rootcut` lê o **journal do sshd** e só segue se achar `Accepted publickey for NOME` com o fingerprint gravado, depois da instalação.
3. `gt-ssh-lockdown fail2ban --ignoreip IP_DO_MINI` (o `--ignoreip` é obrigatório: sem ele um ban cortaria o túnel e o espelho). Instala (`apt`), grava o drop-in `jail.d/gt-sshd.local` (5 tentativas em 10 min, ban de 1 h), sobe, espera a jail responder e lê o `ignoreip` de volta; qualquer falha desfaz e para o fail2ban.
4. `gt-ssh-lockdown ufw --ssh-from any` (ou `IP,IP,…` se o IP do mini for provado fixo). Libera a 22, só depois muda a política para `deny incoming`, arma o timer `gt-ufw-revert` e só então liga. **Conexões abertas sobrevivem ao enable; o erro só aparece na próxima** → abra uma conexão NOVA, confira, e rode `gt-ssh-lockdown confirm ufw`. Sem confirmar, o ufw desliga sozinho em 10 min.
5. `gt-ssh-lockdown rootcut`. Só roda com as 5 provas: admin gravado · usuário `dados` (ou override) · ufw ativo · jail `sshd` de pé · login real do admin no journal + `sudo -n -l -U NOME` com `NOPASSWD: ALL`. Grava `/etc/ssh/sshd_config.d/10-gt-lockdown.conf` (`PermitRootLogin no`), confere pelo `sshd -T` que o efetivo é `no` (se não for, remove o drop-in e falha), arma o timer `gt-rootcut-revert` e recarrega. Prove (seção abaixo) e rode `gt-ssh-lockdown confirm rootcut`.

## As provas da história (rodar depois do rootcut, antes do confirm)

* `ssh root@2.31.41.222` do mini → **recusado** (`Permission denied`).
* `ssh NOME@2.31.41.222 sudo -n true` → entra.
* `fail2ban-client status sshd` → a jail existe; `ufw status` → `Status: active` com a 22 liberada.
* Os trabalhadores remotos continuam: o túnel 2293 de pé e o espelho git respondendo como `runner`.

## Redes de segurança e como desfazer

| Passo | Rede | Desfazer à mão |
|---|---|---|
| `ufw` | `gt-ufw-revert.timer` desliga o ufw em 10 min | `gt-ssh-lockdown undo ufw` |
| `rootcut` | `gt-rootcut-revert.timer` remove o drop-in e recarrega o ssh em 10 min | `gt-ssh-lockdown undo rootcut` |
| `fail2ban` | falha desfaz sozinho (drop-in removido, fail2ban parado) | `systemctl stop fail2ban; rm /etc/fail2ban/jail.d/gt-sshd.local` |

Sem timer armado o passo NÃO roda. Se o servidor ficar inalcançável: console da Hetzner → `gt-ssh-lockdown undo ufw` e `undo rootcut`. Códigos de saída: 0 ok · 2 recusado (nada mudou) · 3 não consegui ler (nada mudou; nunca vira "vazio") · 98 falhou (a mensagem diz o que ficou no nó).

## Firewall da Hetzner Cloud (fica para quando houver token)

Fora do escopo do script: não há token da nuvem no Bitwarden hoje. Quando o item `hcloud` existir, o dog confere (`GET /v1/firewalls`) se já há firewall no servidor e propõe uma regra de entrada só para a 22. Lista de IPs só se o IP do mini estiver provado fixo; o firewall da nuvem **não tem desfazer automático**, então o primeiro corte é sempre "22 de qualquer origem" e a lista vem depois.

## O que este script NÃO prova

O selftest usa stubs de `useradd`, `ufw`, `fail2ban-client`, `sshd`, `systemctl`, `journalctl` e `sudo`; prova a lógica (ordem, recusas, desfazer, três estados), não o comportamento do sshd/ufw/fail2ban de verdade. Isso só a execução no nó prova, e por isso cada passo vivo tem timer de 10 min e prova por conexão nova.
