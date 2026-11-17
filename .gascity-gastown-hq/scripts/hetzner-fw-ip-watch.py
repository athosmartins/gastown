#!/usr/bin/env python3
"""hetzner-fw-ip-watch.py — o IP público do mini ainda é o que o firewall da nuvem aceita? Uma leitura a cada 10 min; mudou → aviso ao Mayor com o IP novo e o passo a passo. (ga-1h1b7vq)

Contents
  Por que existe · Regra · Arquivos · Como reconhecer a troca · Uso

POR QUE EXISTE  O firewall da Hetzner Cloud 'so-ssh-do-mini' (projeto teste-urblink, id 11795835) libera ENTRADA só para o IP público do mini (179.197.107.78 em 17/11). Internet residencial costuma ter IP dinâmico:
  se o provedor trocar o IP, o túnel, o espelho git, os dogs remotos e os revisores remotos param TODOS juntos, e o sintoma parece "o nó caiu". Este vigia lê o IP e avisa antes de alguém investigar o nó.
REGRA  cada leitura tem TRÊS estados (igual ao liberado / diferente / não consegui saber), e "não consegui" nunca vira "mudou" nem "igual".
  leitura  2 fontes (api.ipify.org e ifconfig.me, por `curl -4`): as duas têm de responder um IPv4 público VÁLIDO e igual. Falha de uma, resposta que não é IP, IP privado/loopback ou discordância entre as fontes = "não sei":
           não toca no IP visto, não avisa de troca, só conta a falha. N falhas SEGUIDAS (padrão 3 = 30 min) → 1 aviso "vigia cego" (cooldown 6 h); uma leitura boa zera a conta.
  diferente  as duas fontes concordam e o IP != o liberado no firewall → mail ao Mayor (`gc mail send mayor`, não nudge: ga-eldeu). Repete a cada 3 h enquanto o IP seguir diferente do liberado (o problema persiste e o trabalho
           remoto está parado); um IP NOVO avisa na hora. O mail que falha NÃO gasta o cooldown (tenta de novo na rodada seguinte).
  liberado  o IP que o firewall aceita. Semente: HETZNER_FW_IP_ALLOWED (padrão 179.197.107.78). Depois de trocar a regra no console, `--ack` grava o IP atual como liberado e encerra o episódio.
  O vigia só LÊ e AVISA. Não muda o firewall: não há o item 'hcloud' (token da API de firewall) no cofre (17/11), e o firewall da nuvem não tem desfazer. Com o token, a atualização pela API
  (PUT /v1/firewalls/11795835/actions/set_rules) fica para uma fatia própria, com chave .on e prova de que o ssh volta.
ARQUIVOS (só em <cidade>/.gc)  hetzner-fw-ip.state.json (liberado, visto, falhas seguidas, últimos avisos) · hetzner-fw-ip.lock (instância única: o launchd não empilha rodadas).
  Estado corrompido (não é UTF-8, não é JSON, JSON fundo demais, campo de tipo errado ou texto que não grava) não some: a cópia fica em <arquivo>.corrupt-<epoch> e o vigia recomeça da semente (caso comum: um aviso a mais; se o IP voltar justo ao da semente com o firewall em outro, lê 'igual' até o --ack).
USO  hetzner-fw-ip-watch.py [--dry-run] [--print] [--ack [IP]]
  (sem argumento) uma rodada: lê, compara, avisa se for o caso, grava o estado, imprime UMA linha.   --dry-run  não grava nem manda mail.   --print  imprime o estado e sai.
  --ack [IP]  o firewall já foi atualizado: grava IP (ou, sem argumento, o IP que as duas fontes dizem agora) como liberado.
  exit 0 ok (inclui "outra instância rodando" e "não sei") · 1 crash (traceback no stderr) · 3 configuração inválida, não consegui ler/gravar o estado, ou IP do --ack ilegível
  Config por ambiente: HETZNER_FW_IP_ALLOWED · HETZNER_FW_IP_SOURCES (URLs separadas por vírgula) · HETZNER_FW_IP_BLIND_AFTER (3) · HETZNER_FW_IP_COOLDOWN_S (10800) · HETZNER_FW_IP_BLIND_COOLDOWN_S (21600)
  · HETZNER_FW_IP_CURL_TIMEOUT_S (10) · HETZNER_FW_IP_ALARM=0 (só mede) · GC_CITY_PATH · GC_BIN · CURL_BIN · HETZNER_FW_IP_NOW (epoch, só para teste)
"""
import argparse
import errno
import fcntl
import ipaddress
import json
import os
import signal
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

DEFAULT_CITY = "/Users/athos/gt/.gascity-gastown-hq"
SEED_ALLOWED = "179.197.107.78"
DEFAULT_SOURCES = "https://api.ipify.org,https://ifconfig.me/ip"
FIREWALL = "so-ssh-do-mini (projeto teste-urblink, id 11795835)"
STATE_NAME = "hetzner-fw-ip.state.json"
LOCK_NAME = "hetzner-fw-ip.lock"
MAX_BODY = 64  # um IPv4 tem ≤ 15 caracteres; resposta maior que isto não é um IP (página de erro, captive portal)


class Fail(Exception):
    def __init__(self, msg, rc=3):
        Exception.__init__(self, msg)
        self.rc = rc


# ---- configuração ------------------------------------------------------------------------------------------------------------------------------------
def parse_ip(text):
    """IPv4 público válido (str normalizada) ou None. Privado, loopback, link-local, reservado, v6 e lixo = None."""
    if not isinstance(text, str):  # número, lista, None, bool... não é um IP (e não tem .strip())
        return None
    s = text.strip()
    if not s or len(s) > 15:
        return None
    try:
        ip = ipaddress.IPv4Address(s)
    except ValueError:
        return None
    return str(ip) if ip.is_global else None


def writable_text(x):
    """True se x é texto que grava em UTF-8 (str sem surrogate solto). Número, lista, None e str com U+D800 = False."""
    if not isinstance(x, str):
        return False
    try:
        x.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _int(env, key, default, lo):
    v = int(env.get(key, default))
    if v < lo:
        raise ValueError("%s=%r abaixo do mínimo %r" % (key, v, lo))
    return v


def load_config(env):
    city = env.get("GC_CITY_PATH") or DEFAULT_CITY
    allowed = parse_ip(env.get("HETZNER_FW_IP_ALLOWED", SEED_ALLOWED))
    if allowed is None:
        raise ValueError("HETZNER_FW_IP_ALLOWED=%r não é um IPv4 público" % env.get("HETZNER_FW_IP_ALLOWED"))
    sources = [s.strip() for s in env.get("HETZNER_FW_IP_SOURCES", DEFAULT_SOURCES).split(",") if s.strip()]
    if len(sources) < 2:
        raise ValueError("HETZNER_FW_IP_SOURCES precisa de ao menos 2 fontes (uma só não tem com quem concordar)")
    return SimpleNamespace(
        city=city, gc_dir=os.path.join(city, ".gc"), allowed_seed=allowed, sources=sources,
        blind_after=_int(env, "HETZNER_FW_IP_BLIND_AFTER", 3, 1),
        cooldown_s=_int(env, "HETZNER_FW_IP_COOLDOWN_S", 10800, 0),
        blind_cooldown_s=_int(env, "HETZNER_FW_IP_BLIND_COOLDOWN_S", 21600, 0),
        curl_timeout_s=_int(env, "HETZNER_FW_IP_CURL_TIMEOUT_S", 10, 1),
        alarm_on=env.get("HETZNER_FW_IP_ALARM", "1") != "0",
        gc_bin=env.get("GC_BIN", "gc"), curl_bin=env.get("CURL_BIN", "curl"),
        now=int(env["HETZNER_FW_IP_NOW"]) if env.get("HETZNER_FW_IP_NOW") else None,
    )


# ---- processos e arquivos ----------------------------------------------------------------------------------------------------------------------------
def run_cmd(argv, timeout):
    """(rc, stdout, stderr, porque). porque: None = rodou até o fim · 'timeout' (o grupo de processos inteiro morre) · 'nao-executou'."""
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, errors="replace", start_new_session=True)
    except OSError as e:
        return None, "", str(e), "nao-executou"
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=5)
        except Exception:
            pass
        return None, "", "", "timeout"
    return p.returncode, out, err, None


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except (OSError, ValueError) as e:  # ValueError: UnicodeEncodeError (texto com surrogate solto não grava em UTF-8)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise Fail("não consegui gravar %s: %s" % (path, e))


def take_lock(gc_dir):
    """fd do travamento; None se outra instância já o tem. Não conseguir nem abrir o arquivo = Fail (rc 3)."""
    try:
        os.makedirs(gc_dir, exist_ok=True)
        fd = os.open(os.path.join(gc_dir, LOCK_NAME), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as e:
        raise Fail("não consegui gravar em %s: %s" % (gc_dir, e))
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return None
        raise Fail("não consegui travar %s: %s" % (gc_dir, e))
    return fd


def new_state(c):
    return {"v": 1, "allowed_ip": c.allowed_seed, "seen_ip": None, "seen_epoch": None, "fails": 0, "fail_reason": None,
            "alarm_ip": None, "alarm_epoch": None, "blind_alarm_epoch": None}


def load_state(c, now, dry):
    """O estado gravado, ou um estado de semente. Ausente = semente (1ª rodada); corrompido (não é texto UTF-8, não é JSON, JSON fundo demais, campo de tipo errado — inclusive fail_reason que não grava de volta e v que não é o inteiro 1) = a cópia fica em <arquivo>.corrupt-<epoch> (menos no --dry-run) e recomeça da semente."""
    path = os.path.join(c.gc_dir, STATE_NAME)
    # vazio → arquivo ausente = semente (liberado = o IP padrão); não consegui ler (OSError) → Fail (rc 3, nada é decidido); formato errado (bytes que não são UTF-8, JSON ilegível ou fundo demais, campo de tipo errado) → guarda a cópia e recomeça da semente. A semente pode estar velha (um --ack depois dela):
    # o caso comum é UM aviso a mais; o contrário (o IP voltar justo ao da semente com o firewall já em outro) o vigia lê como 'igual' até o próximo --ack
    raw = None
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return new_state(c)
    except UnicodeDecodeError:
        pass  # os bytes lidos não são texto UTF-8: formato errado (raw fica None), não "não consegui ler"
    except OSError as e:
        raise Fail("não consegui ler %s: %s" % (path, e))
    ok, st = False, None
    if raw is not None:
        try:
            st = json.loads(raw)
            ok = isinstance(st, dict) and isinstance(st.get("v"), int) and not isinstance(st.get("v"), bool) and st["v"] == 1 and parse_ip(st.get("allowed_ip")) is not None
            ok = ok and isinstance(st.get("fails"), int) and not isinstance(st.get("fails"), bool) and st["fails"] >= 0
            for k in ("seen_epoch", "alarm_epoch", "blind_alarm_epoch"):
                ok = ok and (st.get(k) is None or (isinstance(st[k], int) and not isinstance(st[k], bool)))
            for k in ("seen_ip", "alarm_ip"):
                ok = ok and (st.get(k) is None or parse_ip(st[k]) is not None)
            ok = ok and (st.get("fail_reason") is None or writable_text(st["fail_reason"]))  # a única chave de texto livre: com surrogate solto ela quebraria --print e a gravação seguinte
        except (ValueError, RecursionError):  # JSON ilegível (ValueError) ou fundo demais para o parser (RecursionError, que não é ValueError)
            ok = False
    if ok:
        base = new_state(c)
        base.update({k: st[k] for k in base if k in st})  # só as chaves conhecidas (todas validadas acima): lixo a mais no arquivo não passa para o estado novo (e não trava a gravação)
        for k in ("allowed_ip", "seen_ip", "alarm_ip"):
            if base[k] is not None:
                base[k] = parse_ip(base[k])  # guarda a forma NORMALIZADA (sem espaços): o que foi validado é o que é comparado e gravado
        return base
    dest = "%s.corrupt-%d" % (path, now)
    if not dry:
        try:
            os.replace(path, dest)
        except OSError as e:
            raise Fail("não consegui guardar a cópia de %s: %s" % (path, e))
    print("hetzner-fw-ip-watch: AVISO: %s estava corrompido; %s %s" % (path, "(--dry-run) a cópia iria para" if dry else "a cópia ficou em", dest), file=sys.stderr)
    return new_state(c)


# ---- a leitura do IP ---------------------------------------------------------------------------------------------------------------------------------
def read_source(c, url):
    """(ip, None) ou (None, motivo). vazio/lixo/não-público → motivo 'resposta-invalida'; curl que falha ou trava → motivo; nunca um IP inventado."""
    rc, out, _err, why = run_cmd([c.curl_bin, "-4", "-fsS", "--max-time", str(c.curl_timeout_s), url], c.curl_timeout_s + 5)
    if why == "timeout":
        return None, "timeout"
    if why or rc != 0:
        return None, "curl-falhou"
    if len(out) > MAX_BODY:
        return None, "resposta-grande"
    ip = parse_ip(out)
    return (ip, None) if ip else (None, "resposta-invalida")


def read_public_ip(c):
    """(ip, None) se TODAS as fontes responderam o mesmo IPv4 público; senão (None, motivo). Discordância é 'não sei', não 'mudou'."""
    ips, motivos = [], []
    for url in c.sources:
        ip, why = read_source(c, url)
        if ip:
            ips.append(ip)
        else:
            motivos.append(why)
    if motivos:
        return None, "fonte-sem-resposta(%s)" % ",".join(sorted(set(motivos)))
    if len(set(ips)) != 1:
        return None, "fontes-discordam"
    return ips[0], None


# ---- o aviso -----------------------------------------------------------------------------------------------------------------------------------------
def send_mail(c, subj, body):
    rc, _o, _e, why = run_cmd([c.gc_bin, "--city", c.city, "mail", "send", "mayor", "-s", subj, "-m", body], 45)
    return why is None and rc == 0


def changed_message(c, allowed, seen):
    subj = "Nó Hetzner: o IP do mini mudou (%s → %s); a regra do firewall da nuvem, pelo registro do vigia, é %s" % (allowed, seen, allowed)
    body = "\n".join([
        "O IP público do mini agora é %s (as 2 fontes %s concordam). O firewall da nuvem %s, pelo registro do vigia (semente ou último --ack; ele não consulta o firewall), libera ENTRADA só para %s." % (seen, " e ".join(u.split("//")[-1].split("/")[0] for u in c.sources), FIREWALL, allowed),
        "",
        "Efeito: o túnel, o espelho git, os dogs remotos e os revisores remotos do nó Hetzner estão parados ou vão parar; o sintoma parece 'o nó caiu', mas o nó está de pé.",
        "",
        "Para consertar (alguém com acesso ao console):",
        "1. Entrar em https://console.hetzner.cloud (login no item 'hetzner' do cofre: `secret hetzner`).",
        "2. Projeto teste-urblink → Firewalls → so-ssh-do-mini → regra de entrada: trocar %s por %s/32 → Aplicar." % (allowed, seen),
        "3. Provar com uma conexão NOVA: `ssh hetzner-teste true`.",
        "4. Dizer ao vigia que acabou: `python3 %s/scripts/hetzner-fw-ip-watch.py --ack` (grava %s como liberado e encerra o aviso)." % (c.city, seen),
        "",
        "O vigia só lê e avisa; não muda o firewall (não há o item 'hcloud' no cofre). Repete a cada %d h enquanto o IP seguir diferente do liberado. Desligar o aviso: HETZNER_FW_IP_ALARM=0 no plist." % (c.cooldown_s // 3600),
    ])
    return subj, body


def blind_message(c, st):
    subj = "Nó Hetzner: o vigia do IP do mini está cego há %d leituras seguidas (%s)" % (st["fails"], st["fail_reason"])
    body = "\n".join([
        "Nas últimas %d rodadas (10 min cada) as fontes de IP não deram uma resposta utilizável: %s." % (st["fails"], st["fail_reason"]),
        "Sem a leitura não sei se o IP do mini ainda é o que o firewall %s aceita (%s). Não é um aviso de troca: é um aviso de que o vigia não está enxergando." % (FIREWALL, st["allowed_ip"]),
        "Causas comuns: o mini sem internet, DNS, ou as duas fontes fora ao mesmo tempo. Conferir: `curl -4 https://api.ipify.org` e `curl -4 https://ifconfig.me/ip`.",
        "Próximo aviso deste tipo em no mínimo %d h; uma leitura boa zera a contagem." % (c.blind_cooldown_s // 3600),
    ])
    return subj, body


# ---- a rodada ----------------------------------------------------------------------------------------------------------------------------------------
def due(last, now, cooldown):
    """Passou o cooldown desde o último aviso? Nunca avisou → sim. Relógio que recuou (last no futuro) → sim: melhor um aviso a mais que ficar mudo."""
    return last is None or now < last or now - last >= cooldown


def run_once(c, now, dry):
    """(linha_para_imprimir, estado_novo, mail_saiu). Muda o estado em memória; quem chama grava."""
    st = load_state(c, now, dry)
    ip, why = read_public_ip(c)
    alarme = "-"
    if ip is None:
        st["fails"] += 1
        st["fail_reason"] = why
        estado = "nao-sei"
        if st["fails"] >= c.blind_after and c.alarm_on and due(st["blind_alarm_epoch"], now, c.blind_cooldown_s):
            if dry:
                alarme = "cego-dry-run"
            else:
                subj, body = blind_message(c, st)
                if send_mail(c, subj, body):
                    st["blind_alarm_epoch"] = now
                    alarme = "cego-enviado"
                else:
                    alarme = "cego-mail-falhou"
    else:
        st["fails"], st["fail_reason"] = 0, None
        st["seen_ip"], st["seen_epoch"] = ip, now
        if ip == st["allowed_ip"]:
            estado = "igual"
            st["alarm_ip"], st["alarm_epoch"] = None, None  # voltou ao liberado: o próximo desvio é um episódio novo e avisa na hora
        else:
            estado = "diferente"
            if not c.alarm_on:
                alarme = "desligado"
            elif st["alarm_ip"] == ip and not due(st["alarm_epoch"], now, c.cooldown_s):
                alarme = "cooldown"
            elif dry:
                alarme = "dry-run"
            else:
                subj, body = changed_message(c, st["allowed_ip"], ip)
                if send_mail(c, subj, body):
                    st["alarm_ip"], st["alarm_epoch"] = ip, now
                    alarme = "enviado"
                else:
                    alarme = "mail-falhou"  # não grava alarm_*: a rodada seguinte tenta de novo
    line = "hetzner-fw-ip-watch: %s ip=%s liberado=%s estado=%s falhas=%d alarme=%s%s" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), ip or "?", st["allowed_ip"], estado, st["fails"], alarme, (" motivo=" + why) if why else "")
    return line, st, alarme in ("enviado", "cego-enviado")


def do_ack(c, arg, now, dry):
    st = load_state(c, now, dry)
    if arg:
        ip = parse_ip(arg)
        if ip is None:
            raise Fail("--ack %r não é um IPv4 público" % arg)
    else:
        ip, why = read_public_ip(c)
        if ip is None:
            raise Fail("--ack sem IP: não consegui ler o IP atual (%s); passe o IP: --ack <IP>" % why)
    antes = st["allowed_ip"]
    st["allowed_ip"], st["alarm_ip"], st["alarm_epoch"] = ip, None, None
    if not dry:
        save(c, st)
    print("hetzner-fw-ip-watch: %sliberado %s -> %s" % ("(--dry-run) " if dry else "", antes, ip))


def save(c, st):
    write_atomic(os.path.join(c.gc_dir, STATE_NAME), json.dumps(st, ensure_ascii=False, sort_keys=True, indent=1) + "\n")


def main(argv, env):
    ap = argparse.ArgumentParser(description="vigia do IP público do mini contra o firewall da nuvem Hetzner (ga-1h1b7vq)")
    ap.add_argument("--dry-run", action="store_true", help="não grava estado nem manda mail")
    ap.add_argument("--print", dest="show", action="store_true", help="imprime o estado gravado e sai")
    ap.add_argument("--ack", nargs="?", const="", default=None, metavar="IP", help="o firewall foi atualizado: grava IP (ou o IP atual) como liberado")
    a = ap.parse_args(argv)
    try:
        c = load_config(env)
    except ValueError as e:
        print("hetzner-fw-ip-watch: configuração inválida: %s" % e, file=sys.stderr)
        return 3
    now = c.now if c.now is not None else int(time.time())
    fd = take_lock(c.gc_dir)
    if fd is None:
        print("hetzner-fw-ip-watch: outra instância está rodando; saindo", file=sys.stderr)
        return 0
    try:
        if a.show:
            print(json.dumps(load_state(c, now, True), ensure_ascii=False, sort_keys=True, indent=1))
            return 0
        if a.ack is not None:
            do_ack(c, a.ack, now, a.dry_run)
            return 0
        line, st, mail_saiu = run_once(c, now, a.dry_run)
        if not a.dry_run:
            try:
                save(c, st)
            except Fail:
                if mail_saiu:  # o mail não se desfaz: sem esta linha o mail repetido da rodada seguinte não teria explicação no log
                    print("hetzner-fw-ip-watch: mail enviado, estado não gravado (o aviso se repete na rodada seguinte)", file=sys.stderr)
                    print(line)
                raise
        print(line)
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:], os.environ))
    except Fail as e:
        print("hetzner-fw-ip-watch: %s" % e, file=sys.stderr)
        sys.exit(e.rc)
    except Exception:
        traceback.print_exc()
        sys.exit(1)
