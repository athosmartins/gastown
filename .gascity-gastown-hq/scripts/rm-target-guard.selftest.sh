#!/usr/bin/env bash
# rm-target-guard.selftest.sh (ga-id0im4e) — hermético: HOME e scratch de teste em tmp, sem rede, nenhum rm de verdade (rm/unlink/rmdir/shred/find FALSOS gravam o que o shell entregou). Quatro blocos (o 3º tem dois fuzzers):
# tabela (B bloqueia, P passa; `:s|:b|:p|:h` troca o cwd), ponta a ponta (exit code, mensagem, falha do guarda), fuzzers diferenciais contra o bash REAL (todo comando que entregou um alvo proibido
# a um rm falso tem de bloquear; o 2º gera cd/pushd/popd em qualquer posição e põe o `pwd` no lugar do rm: rm recursivo rodado numa pasta proibida tem de bloquear) e mutantes (cada guarda apagada tem de reprovar a tabela). Uso: rm-target-guard.selftest.sh [N-do-fuzzer, padrão 200]. RMTG_UNDER_TEST=<arquivo> roda a
# suíte contra outra cópia do guarda. Exit 0 = tudo passou. Os payloads com os.system/shell=True/rm -rf abaixo são TEXTO de teste, deliberados: o guarda só os lê, nada os executa.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I - "${RMTG_UNDER_TEST:-$HERE/rm-target-guard.py}" "${1:-200}" <<'PYEOF'
import importlib.util, json, os, random, re, shlex, shutil, subprocess, sys, tempfile

sys.dont_write_bytecode = True  # mutantes são reescritos em sequência: um .pyc velho (mesmo mtime e tamanho) faria o próximo rodar o código do anterior

GUARD, N = sys.argv[1], int(sys.argv[2])
H = os.path.realpath(tempfile.mkdtemp(prefix="rmtgst."))  # HOME de teste: fica em /tmp de propósito (o HOME vence o scratch)
S = os.path.realpath(tempfile.mkdtemp(prefix="rmtgsc."))  # scratch de verdade, fora do HOME
for d in (".dolt-data/ga/.dolt/noms", ".beads", "proj/.git/objects", "proj/.git/refs", "proj/src", "proj/build", "proj/node_modules/p", "proj/__pycache__", "proj2/.git/objects", "proj2/.git/refs", "gt-remote/keys", "gt-remote/git/gascity/repo.git/objects",
          "gt-remote/git/gascity/repo.git/refs", "gt-remote/git/gascity/wt/s1/src", ".cache/pip", "Library/CloudStorage/d", "gt/rig/shared/data/ga", "gt/rig/crew/bob", "gt/wa/shared", "shared/data", "gt/rig/.gc-worktrees/w", "bin",
          "gt-remote/big/zrepo/.git", "work2/open", "work2/locked", "work2/xonly", "work2/rdonly"):
    os.makedirs(f"{H}/{d}")
for f in ("notes.txt", "proj/src/a.py", "proj/src/m.pyc", "proj/build/x.o", "proj/.git/HEAD", "proj/.git/index.lock", "proj/.git/config", "proj2/.git/HEAD", "gt-remote/keys/gt_mirror", "gt-remote/git/gascity/repo.git/HEAD",
          "gt-remote/git/gascity/wt/s1/.git", "gt-remote/git/gascity/wt/s1/src/a", ".dolt-data/ga/.dolt/noms/manifest", ".beads/b", ".cache/pip/w", "gt/rig/crew/bob/x.py", "proj/__pycache__/m.pyc", "shared/data/prod.db", "shared/note.txt"):
    open(f"{H}/{f}", "w").write("x\n")
for i in range(100):  # mais de 80 entradas e o repo é a ÚLTIMA: o teto antigo de 80 não o via
    os.makedirs(f"{H}/gt-remote/big/a{i:03d}")
for d in ("work/a", "work/b", "work/.git", "srepo/.git", "srepo/src", "many"):
    os.makedirs(f"{S}/{d}")
for i in range(5):
    open(f"{S}/many/f{i}", "w").write("x")
os.symlink(f"{H}/proj/.git", f"{S}/lnkgit"); os.symlink(f"{S}/work", f"{S}/lnkok")
# layout REAL da máquina (ga-id0im4e, 4ª rodada): o dado de produção mora em ~/shared/data e o rig só o aponta (gt/wa/shared/data -> ~/shared/data, gt/wa/data -> shared/data); L e Ld são links que o texto normalizado perde ao subir com `..`
os.symlink(f"{H}/shared/data", f"{H}/gt/wa/shared/data"); os.symlink("shared/data", f"{H}/gt/wa/data"); os.symlink(f"{H}/gt/rig/shared/data/ga", f"{S}/L"); os.symlink(f"{H}/.dolt-data/ga", f"{S}/Ld"); os.symlink(f"{H}/shared/data", f"{S}/lnkdata"); os.symlink(f"{S}/many", f"{H}/.beads/lnkout"); os.symlink(f"{S}/many", f"{H}/shared/data/yo")  # lnkout, yo: o `..` LÓGICO do cd cai em .beads / num link para shared/data, o físico cai fora
os.chmod(f"{H}/work2/locked", 0); os.chmod(f"{H}/work2/xonly", 0o100); os.chmod(f"{H}/work2/rdonly", 0o400)
DENIES = not os.access(f"{H}/work2/locked", os.R_OK | os.X_OK) and not os.access(f"{H}/work2/xonly", os.R_OK) and not os.access(f"{H}/work2/rdonly", os.X_OK)  # root (ou FS sem modo) lê tudo: sem negação não há o que provar
os.environ["HOME"] = H
CWD = f"{H}/proj"
CWDS = {"w": f"{H}/gt/wa", "s": f"{S}/work", "b": f"{H}/proj/build", "p": f"{S}/work/a", "h": H, "z": "/zzh/a/b"}  # z = HOME sintético fundo e vazio (/zzh/a/b): sem repo por perto para esconder as regras de HOME


def load(path):
    spec = importlib.util.spec_from_file_location("rmtg_" + str(abs(hash(path))), path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def nest(k):
    c = "rm -rf @S/work"
    for _ in range(k):
        c = "bash -c " + shlex.quote(c)
    return c


# linhas "V cmd ‖ V cmd": V = B bloqueia, P passa; V:s|b|p|h|z|w = cwd (w=@H/gt/wa, s=@S/work, b=proj/build, p=@S/work/a, h=@H, z=/zzh/a/b com HOME=/zzh/a/b); sem tag o cwd é @H/proj (raiz de repo)
# união de cwd (5º FAIL do gate): com QUALQUER cd/pushd/popd no pedido o rm de alvo relativo, curinga, $PWD ou $(pwd) é julgado em cada pasta de {cwd original} ∪ {destino de todo cd}; o cd que o `||`, o pipe ou o `!` pulam não tira nenhuma pasta da união. Os `P` provam que a união não barra o que só toca pasta de scratch
DSL = r"""
B rm -fr ~/gt-remote ‖ B rm -r -f ~/gt-remote ‖ B rm --recursive --force ~/gt-remote ‖ B /bin/rm -rf ~/gt-remote ‖ B bash -c 'rm -rf ~/gt-remote' ‖ B env rm -rf ~/gt-remote ‖ B python3 -c "import subprocess; subprocess.run(['rm','-rf','@H/gt-remote'])" ‖ B rm -Rf ~/gt-remote ‖ B rm -rfv ~/gt-remote
B rm -f -r ~/gt-remote ‖ B rm --recur --forc ~/gt-remote ‖ B rm ~/gt-remote -rf ‖ B rm -rf -- ~/gt-remote ‖ B rm -rf --no-preserve-root ~/gt-remote ‖ P rm ~/gt ‖ P rm -f ~/gt ‖ B sudo rm -rf ~/gt-remote ‖ B sudo -u bob rm -rf ~/gt-remote ‖ B env -i rm -rf ~/gt-remote ‖ B env A=1 rm -rf ~/gt-remote
B command rm -rf ~/gt-remote ‖ B nohup rm -rf ~/gt-remote ‖ B timeout 5 rm -rf ~/gt-remote ‖ B timeout -s KILL 5 rm -rf ~/gt-remote ‖ B nice -n 5 rm -rf ~/gt-remote ‖ B ionice -c 3 rm -rf ~/gt-remote ‖ B time rm -rf ~/gt-remote ‖ B exec rm -rf ~/gt-remote ‖ B stdbuf -oL rm -rf ~/gt-remote
B doas rm -rf ~/gt-remote ‖ B flock /tmp/l rm -rf ~/gt-remote ‖ B env -S 'rm -rf ~/gt-remote' ‖ B A=1 rm -rf ~/gt-remote ‖ B busybox rm -rf ~/gt-remote ‖ B strace -o /dev/null rm -rf ~/gt-remote ‖ B npx rimraf ~/gt-remote ‖ B rimraf ~/gt-remote ‖ B nohup timeout 5 env A=1 rm -rf ~/gt-remote
B ssh host 'rm -rf ~/gt-remote' ‖ B watch rm -rf ~/gt-remote ‖ B true; rm -rf ~/gt-remote ‖ B true && rm -rf ~/gt-remote ‖ B false || rm -rf ~/gt-remote ‖ B echo x | rm -rf ~/gt-remote ‖ B (rm -rf ~/gt-remote) ‖ B { rm -rf ~/gt-remote; } ‖ B if true; then rm -rf ~/gt-remote; fi
B while true; do rm -rf ~/gt-remote; done ‖ B case x in x) rm -rf ~/gt-remote;; esac ‖ B f() { rm -rf ~/gt-remote; }; f ‖ B for d in ~/gt-remote; do rm -rf "$d"; done ‖ B D=~/gt-remote; rm -rf "$D" ‖ B D=~; rm -rf $D/gt-remote ‖ B export D=~/gt-remote; rm -rf $D ‖ B rm -rf ~/gt-remote &
B >/dev/null rm -rf ~/gt-remote ‖ B for d in a ~/gt-remote; do rm -rf $d; done ‖ B rm -rf ~/gt-remote # c ‖ B rm -rf ~/gt-remote >/dev/null 2>&1 ‖ B sh -c 'rm -rf ~/gt-remote' ‖ B bash -lc "rm -rf ~/gt-remote" ‖ B eval 'rm -rf ~/gt-remote' ‖ B eval rm -rf ~/gt-remote ‖ B echo $(rm -rf ~/gt-remote)
B echo `rm -rf ~/gt-remote` ‖ B x="$(rm -rf ~/gt-remote)" ‖ B echo 'rm -rf ~/gt-remote' | bash ‖ B echo rm -rf ~/gt-remote | sh -s ‖ B bash <<< 'rm -rf ~/gt-remote' ‖ B timeout 5 bash -c 'rm -rf ~/gt-remote' ‖ B bash -c "bash -c 'rm -rf ~/gt-remote'" ‖ B bash <(echo 'rm -rf ~/gt-remote')
B bash <(echo rm -rf ~/gt-remote) ‖ B source <(printf 'rm -rf ~/gt-remote') ‖ B . <(echo rm -rf ~/gt-remote) ‖ B diff <(rm -rf ~/gt-remote) x ‖ P bash <(echo ls) ‖ P cat <(echo hi) ‖ B $(echo rm) -rf ~/gt-remote ‖ B ${R:-rm} -rf ~/gt-remote ‖ B /bin/r? -rf ~/gt-remote ‖ B R=rm; $R -rf ~/gt-remote
B R=rm; "$R" -rf ~/gt-remote ‖ P $EDITOR file ‖ P $(echo ls) -la @S/work ‖ P [ -r ~/gt-remote ] ‖ P [[ -r x ]] ‖ B r""m -rf ~/gt-remote ‖ B \rm -rf ~/gt-remote ‖ B 'rm' -rf ~/gt-remote ‖ B $'rm' -rf ~/gt-remote ‖ B $'\x72m' -rf ~/gt-remote ‖ B rm -rf "$HOME/gt-remote" ‖ B rm -rf ${HOME}/gt-remote
B rm -rf $HOME/gt-remote ‖ B rm -rf "$HOME"/gt-remote ‖ B rm -rf ~/gt-r''emote ‖ B rm -rf ~/gt-remote/ ‖ B rm -rf ~//gt-remote ‖ B rm -rf ~/./gt-remote ‖ B rm -rf ~/x/../gt-remote ‖ B rm -rf ~/gt-r* ‖ B rm -rf ~/{gt-remote,zz} ‖ B rm -rf ~/gt-remot? ‖ B rm -rf ~/[g]t-remote ‖ B rm -rf ~/.dolt-data
B rm -rf ~/.dolt-data/ga ‖ B rm ~/.dolt-data/ga/.dolt/noms/manifest ‖ B rm -rf ~/.beads ‖ B rm -rf @H/proj/.git ‖ B rm -f @H/proj/.git/HEAD ‖ B rm -rf ~/gt/rig/.gc-worktrees ‖ B rm -rf ~/gt/rig/crew/bob ‖ B rm ~/gt/rig/crew/bob/x.py ‖ P rm -f @H/proj/.git/index.lock
B rm -f @H/proj/.git/refs/heads/x.lock ‖ B rm -f @H/proj/.git/index.lock/x ‖ B rm -rf @H/proj/.GIT ‖ B rm -rf @H/.Dolt-Data ‖ B rm -rf @H/Library/CLOUDSTORAGE/d ‖ B rm -rf /ETC ‖ B rm -rf @H/gt/rig/CREW/bob ‖ B rm -rf @HUP/gt-remote ‖ B rm -rf ~/Library/CloudStorage/d ‖ B rm -rf ~/gt/rig/shared/data
B rm ~/gt/rig/shared/data/db ‖ P rm -rf ~/gt/rig/zz ‖ B rm -rf ~ ‖ B rm -rf / ‖ B rm -rf /* ‖ B rm -rf /etc ‖ B rm -rf /usr/local/x ‖ B rm -rf /home ‖ B rm -rf @H/.. ‖ B rm -rf ~/.. ‖ B rm -rf /tmp ‖ B rm -rf /tmp/ ‖ B rm -rf /tmp/claude-1000 ‖ B rm -rf /tmp/claude-1000/proj
P rm -rf /tmp/claude-1000/proj/sess ‖ P rm -rf /tmp/claude-1000/proj/sess/scratchpad/x ‖ B rm -rf /tmp/tmux-1000 ‖ B rm -rf /tmp/tmux-1000/default ‖ B rm -rf /private/tmp ‖ B rm -rf /private/tmp/claude-501 ‖ P rm -rf /private/tmp/claude-501/p/s/x ‖ B rm -rf /var/tmp ‖ P rm -rf /var/tmp/x
P rm -rf /tmp/anything ‖ P rm -rf /dev/shm/x ‖ B rm -rf /private/var/folders/ab/cd ‖ P rm -rf /private/var/folders/ab/cd/T/x ‖ B rm -rf ~/gt ‖ B rm -rf ~/.claude ‖ B rm -r ~/proj ‖ P rm ~/notes.txt ‖ P rm -rf ~/notes.txt ‖ B rm -rf ~/nonexistent ‖ P rm -rf ~/.cache ‖ P rm -rf ~/.cache/pip
P rm -rf ~/.npm/_cacache ‖ P rm -rf ~/Library/Caches/go-build ‖ P rm -rf ~/node_modules ‖ P rm -rf ~/gone.pyc ‖ P rmdir ~/gt ‖ P unlink ~/notes.txt ‖ P shred ~/notes.txt ‖ B rm -rf ~/.CACHE ‖ B rm -rf @H/proj ‖ B rm -rf @H/proj2 ‖ B rm -rf @H/gt-remote/git ‖ B rm -rf @H/gt-remote/git/gascity
B rm -rf @H/gt-remote/git/gascity/repo.git ‖ B rm -rf @H/gt-remote/git/gascity/wt ‖ B rm -rf @H/gt-remote/git/gascity/wt/s1 ‖ P rm -rf @H/gt-remote/git/gascity/wt/s1/src ‖ B rm -rf @H/gt-remote/big ‖ P rm -rf @H/proj/src ‖ P rm -rf @H/proj/build ‖ P rm -rf @H/proj/node_modules
P rm @H/proj/src/a.py ‖ P rm -rf @H/proj/__pycache__ ‖ P rm -f @H/proj/build/x.o ‖ P rm -f @H/proj/src/m.pyc ‖ B rm -rf . ‖ B rm -rf ./ ‖ B rm -rf ../proj2 ‖ B rm -rf .. ‖ P rm -rf ./build ‖ P rm -rf build src ‖ P rm -rf ./src/../build ‖ B rm -rf * ‖ B rm -rf ./* ‖ B rm -rf .* ‖ B rm -rf .[!.]*
B rm -rf ?* ‖ B rm -f * ‖ B rm -rf ~/* ‖ B rm -rf ~/.* ‖ P rm -rf build/* ‖ P rm -rf src/*.py ‖ P rm -rf ./build/*.o ‖ P:b rm -rf *.o ‖ P:b rm -rf * ‖ B cd ~/gt-remote/git && rm -rf * ‖ P rm -rf @S/work ‖ P rm -rf @S/work/a @S/work/b ‖ P rm -rf @S/srepo ‖ B rm -rf @S/work/.git
B rm -rf @S/srepo/.git ‖ B rm -rf @S/lnkgit ‖ B rm -rf @S/lnkgit/HEAD ‖ P rm -rf @S/lnkok ‖ P rm -rf @S/many/* ‖ P rm -rf @S/work/{a,b} ‖ P rm -rf @S ‖ P rm -f @S/many/f1 @S/many/f2 ‖ B rm -rf @S/work/{a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q} ‖ B rm -rf $UNSET ‖ B rm -rf "$UNSET/x" ‖ B rm -rf $(cat l)
B rm -rf `cat l` ‖ B rm -rf ~root/x ‖ P rm -f $UNSET ‖ P rm $UNSET/x ‖ B while read f; do rm -rf "$f"; done < l ‖ B ls | xargs rm -rf ‖ B cat l | xargs -0 rm -rf ‖ P ls | xargs rm ‖ B echo ~/gt-remote | xargs rm -rf ‖ P echo @S/work | xargs rm -rf ‖ B printf '%s\n' ~/gt-remote | xargs -n1 rm -rf
B find @S -name x | xargs rm -rf ‖ P find @S -name x | xargs rm ‖ B xargs rm -rf < l ‖ P rm -rf $(mktemp -d) ‖ P rm -rf "$(mktemp -d)/x" ‖ P rm -rf `mktemp -d` ‖ B rm -rf $(pwd) ‖ B rm -rf $PWD ‖ B rm -rf "$PWD" ‖ P:p rm -rf $PWD ‖ B find ~ -delete ‖ B find ~/gt-remote -mindepth 1 -delete
B find ~ -name '*.pyc' -delete ‖ B find / -delete ‖ B find ~ -exec rm -rf {} + ‖ B find ~ -exec rm -rf {} \; ‖ B find ~/proj -type f -delete ‖ B find ~/gt-remote -execdir rm -rf {} + ‖ B find @H/.dolt-data -name x -delete ‖ B find @H/proj/.git -delete ‖ B find . -delete ‖ B find -delete
B find ~/proj -exec sh -c 'rm -rf "$1"' _ {} \; ‖ B find @H/proj -name '*' -delete ‖ B find @H/proj -name '.*' -delete ‖ B find @H/proj -regex '.*' -delete ‖ B find @H/proj -mtime +1 -delete ‖ B find @H/gt-remote/git -name HEAD -delete ‖ P find @S -mindepth 1 -delete
P find @S/work -name '*.o' -delete ‖ P find . -name '*.pyc' -delete ‖ P find ~/proj -name '*.pyc' -delete ‖ P find @H/proj/build -delete ‖ P find ~/proj -name x ‖ P find ~ -name x -print ‖ P find ~ -type f ‖ P find ~ -exec grep x {} + ‖ P find @H/proj/build -mindepth 1 -delete
P find @H/proj -name '*.o' -delete ‖ B cd ~ && rm -rf * ‖ B cd ~; rm -rf gt-remote ‖ B (cd ~ && rm -rf gt-remote) ‖ B cd @H && rm -rf gt-remote ‖ B pushd ~ >/dev/null; rm -rf gt-remote ‖ B cd .. && rm -rf proj2 ‖ B:h cd gt-remote/git && rm -rf gascity ‖ P cd ~/proj && rm -rf build
P cd @S/work && rm -rf a ‖ B cd @S/work && rm -rf * ‖ B cd @S/work; rm -rf * ‖ B cd @S/work || true; rm -rf * ‖ B cd @S/work & rm -rf * ‖ B popd; rm -rf * ‖ B cd $UNSET && rm -rf * ‖ B cd "$X" && rm -rf build ‖ P cd "$X" && rm -f build ‖ B (cd @S/work; rm -rf *) ‖ P:s rm -rf * ‖ B:h rm -rf proj2
P echo rm -rf ~/gt-remote ‖ P printf '%s\n' 'rm -rf ~' ‖ P git commit -m "rm -rf ~/gt-remote" ‖ P grep -rn 'rm -rf' ~/gt-remote ‖ P man rm ‖ P which rm ‖ P command -v rm ‖ P type rm ‖ P ls ~/gt-remote ‖ P cat ~/notes.txt ‖ P # rm -rf ~ ‖ P echo "rm -rf ~" > note.txt ‖ P alias rm='rm -i' ‖ P rm
P rm -rf ‖ P git rm -rf --cached x ‖ P bd show ga-1 ‖ P cd ~ ‖ P ls ‖ B python3 -c "import shutil; shutil.rmtree('@H/gt-remote')" ‖ B python3 -c "import os; os.system('rm -rf @H/gt-remote')" ‖ B python3 -c "import os; os.system('rm -rf ~/gt-remote')"
B node -e "require('fs').rmSync('@H/gt-remote',{recursive:true,force:true})" ‖ B node -e "require('child_process').execSync('rm -rf @H/gt-remote')" ‖ B perl -e 'system("rm -rf @H/gt-remote")' ‖ B perl -e 'use File::Path qw(rmtree); rmtree("@H/gt-remote")'
B ruby -e "require 'fileutils'; FileUtils.rm_rf('@H/gt-remote')" ‖ B awk 'BEGIN{system("rm -rf @H/gt-remote")}' ‖ B python3 -c "import subprocess; subprocess.run(['rm','-rf',x])" ‖ B node -e "require('child_process').execFileSync('rm',['-rf','@H/gt-remote'])"
B python3 -c "import subprocess; subprocess.run(['/bin/rm','-fr','@H/gt-remote'])" ‖ P python3 -c "import shutil; shutil.rmtree('@S/work')" ‖ P python3 -c "print(open('@H/notes.txt').read())" ‖ P python3 -c "import os; print(os.listdir('@H/gt-remote'))" ‖ P node -e "console.log(1)"
P python3 -c "import subprocess; subprocess.run(['rm','-rf','@S/work'])" ‖ P python3 -c "import subprocess; subprocess.run(['ls','@H/gt-remote'])" ‖ P python3 -c "import os; os.system('ls ~/gt-remote')"
B cd @S/work; cd @S/work/a; cd @S/work/b; cd @S/srepo; cd @S/srepo/src; cd @S/many; cd @H/proj/src; cd @H/proj/build; cd @H; rm -rf gt-remote ‖ B python3 -c "import os; os.system('rm -rf ' + '@H/gt-remote')" ‖ B npx -c 'rm -rf ~/gt-remote' ‖ B flock /tmp/l -c 'rm -rf ~/gt-remote'
B $(echo rm) --r ~/gt-remote ‖ B $(echo rm) --rec ~/gt-remote ‖ B $X ~/.dolt-data/ga ‖ P $X ~/proj ‖ B $SHELL -c 'rm -rf ~/gt-remote' ‖ B find @H/proj -name '*.pyc' -o -type f -delete ‖ B find @H/proj ! -name '*.pyc' -delete ‖ B find @H/proj -not -name '*.o' -delete
B find @H/proj -regex '.*[a-z].*' -delete ‖ P find @H/proj -regex '.*\.pyc' -delete ‖ P find @H/proj -name x -delete ‖ B node -e "const fs=require('fs'); fs.rm('@H/gt-remote',{recursive:true},()=>{})" ‖ B:h python3 -c "import shutil; shutil.rmtree('gt-remote')"
B:h python3 -c "import shutil; d='gt-remote'; shutil.rmtree(d)" ‖ P:h python3 -c "import os; os.remove(f); x='{y}'; z='$Q'; w='a b c'; s='/'" ‖ B python3 -c "import shutil; shutil.rmtree('$ZZ/gt')" ‖ P:h python3 -c "x='gt-remote'" ‖ B:h python3 -c "import os; os.remove('gt')" ‖ P:h python3 -c "import os; os.remove(f); w='gt'" ‖ B ruby -e "require 'fileutils'; FileUtils.rm_rf '@H/gt-remote'" ‖ B ruby -e "require 'fileutils'; FileUtils.rm_f('@H/.dolt-data/ga/x')"
B export D=~/.dolt-data/ga; unlink $D ‖ B declare D=~/.dolt-data/ga; shred $D
P export D=@S/work; rm -rf $D ‖ B time for f in @H/gt/rig/.gc-worktrees/./w; do shred "$f"; done ‖ P rm -f /tmp/claude-1000/mt.out ‖ B rm -rf /tmp/claude-1000/mt.out ‖ B rm -rf @S/*/*/*/x ‖ B find @H/proj -name HEAD -delete ‖ B find @H/gt-remote/git -name zzz -delete
B find @H/proj -name '*.lock' -delete ‖ B find @H/proj -path '*/objects/*' -delete ‖ B find @H/proj -name 'pack*' -delete ‖ P find @H/proj/build -name HEAD -delete ‖ P find @H/proj -name '*.pyc' -delete ‖ B python3 -c "import pathlib; pathlib.Path('@H/gt-remote').rmdir()"
B node -e "require('fs').unlinkSync('@H/.dolt-data/ga/x')" ‖ B python3 -c "import shutil; d='@H/gt-remote'; shutil.rmtree(d)" ‖ P python3 -c "import shutil; d='@S/work'; shutil.rmtree(d)" ‖ B unlink @H/*/*/*/.dolt/x ‖ P rm -f @S/*/*/*/x ‖ P python3 -c "l=[1]; l.remove(1); open('@H/gt-remote/x')"
B rm -rf /zzroot ‖ B:z rm -rf /zzh/a ‖ B:z rm -rf /zzh/a/b ‖ B:z rm -rf /zzh/a/b/c ‖ P:z rm -rf /zzh/a/b/c/d ‖ B:z rm -rf ~ ‖ B:z rm -rf ~/x ‖ P for d in @S/work/a; do rm -rf "$d"; done ‖ P R=ls; $R -la ~ ‖ B rm -f @H/proj/.gi*/HEAD ‖ B rimraf ~/gt ‖ B popd; rm -rf node_modules
B find @H/proj -regex '.*\w.*' -delete ‖ B rm -f @H/proj/.gi{t,x}/HEAD
B fish -c 'rm -rf ~/gt-remote' ‖ B tcsh -c 'rm -rf ~/gt-remote' ‖ B pypy3 -c "import shutil; shutil.rmtree('@H/gt-remote')" ‖ B Rscript -e 'unlink("@H/gt-remote", recursive=TRUE)' ‖ B julia -e 'rm("@H/gt-remote", recursive=true)' ‖ B osascript -e 'do shell script "rm -rf ~/gt-remote"' ‖ B xonsh -c 'rm -rf ~/gt-remote' ‖ B echo 'rm -rf ~/gt-remote' | fish ‖ P git -c core.editor=true commit -m 'rm -rf ~' ‖ P cut -c1-5 notes.txt ‖ P xonsh -c 'ls ~' ‖ P echo "rm -rf ~/gt-remote" ‖ P grep -e 'rm -rf ~' notes.txt
B rm -rf ~/gt/rig/shared ‖ B rm -r ~/gt/rig/shared/ ‖ B find ~/gt/rig/shared -delete ‖ B rm -rf ~/gt/rig/sha* ‖ B rm -rf ~/gt/rig/s* ‖ B rm -rf ~/gt/rig/shared/data/../../shared ‖ B rm -rf ~/gt/rig ‖ B find ~/gt/rig -delete ‖ B find ~/gt/rig/shared -name '*.db' -delete ‖ B find ~/gt/rig -name '*.pyc' -delete ‖ P rm -f ~/gt/rig/shared ‖ P rm ~/gt/rig/shared/note.txt ‖ P rm -rf ~/gt/rig/shared/note.txt ‖ P rm -rf ~/gt/rig/zz
B HOME=/tmp/x rm -rf $HOME/gt-remote ‖ B D=~/gt-remote; D=/tmp/ok rm -rf $D ‖ B D=~/gt-remote; D=/tmp/ok true; rm -rf $D ‖ B D=~/gt-remote; (D=/tmp/ok); rm -rf "$D" ‖ B D=~/gt-remote; D=/tmp/ok | cat; rm -rf "$D" ‖ B D=~/gt-remote; true && (D=/tmp/ok; true); rm -rf "$D" ‖ B D=~/gt-remote; f() { D=/tmp/ok; }; rm -rf "$D" ‖ B D=~/gt-remote; env D=/tmp/ok rm -rf $D
B D=/tmp/ok; read D <<< ~/gt-remote; rm -rf $D ‖ B D=/tmp/ok; eval "D=$HOME/gt-remote"; rm -rf $D ‖ B D=/tmp/ok; printf -v D %s ~/gt-remote; rm -rf $D ‖ B D=~/gt-remote; false && D=/tmp/ok; rm -rf $D ‖ B D=~/gt-remote; if false; then D=/tmp/ok; fi; rm -rf $D ‖ B D=~/gt-remote; if false; then D=/tmp/ok; else rm -rf $D; fi ‖ B D=~/gt-remote; case x in y) D=/tmp/ok;; esac; rm -rf $D
B D=/tmp/ok; for i in 1 2; do rm -rf $D; D=~/gt-remote; done ‖ B D=/tmp/ok; f() { rm -rf $D; }; D=~/gt-remote; f ‖ B D=/tmp/ok; echo ~/gt-remote | while read D; do rm -rf $D; done ‖ B D=@H/proj/.gi; D+=t; rm -rf $D ‖ B D=@H; D+=/gt-remote; rm -rf $D ‖ B D=@S/work; source ./e.sh; rm -rf $D ‖ B D=@S/work; mapfile -t D < l; rm -rf $D ‖ B function f { D=~/gt-remote; }; D=/tmp/ok; f; rm -rf $D ‖ B f() { D=~/gt-remote; }; D=/tmp/ok; f; rm -rf $D ‖ B D=~/gt-remote; function f { D=/tmp/ok; }; rm -rf $D
P D=~/gt-remote; D=@S/work; rm -rf $D ‖ P D=@S/work; D=@H/gt-remote rm -rf $D ‖ P (D=@S/work; rm -rf $D) ‖ P D=@S/work; D=@S/work/a rm -rf $D ‖ P D=@S/work; true && D=@S/work/a; rm -rf $D ‖ P for f in a b; do T=@S/work/$f; rm -rf "$T"; done ‖ P D=@S/work; if true; then D=@S/work/a; fi; rm -rf $D ‖ P f() { D=@S/work; rm -rf $D; }; f ‖ P D=@S/work; for f in a b; do rm -rf $D/$f; done ‖ P rm -rf @H/work2/open
B D="/tmp/ok $HOME/gt-remote"; rm -rf $D ‖ B D="@S/work $HOME/gt-remote"; rm -rf $D ‖ B T="@S/work $HOME/gt-remote"; for t in $T; do rm -rf "$t"; done ‖ B C='rm -rf @H/gt-remote'; $C ‖ B C='rm -rf @H/gt-remote'; eval "$C" ‖ B C='rm -rf @H/gt-remote'; bash -c "$C" ‖ B C='rm -rf @H/gt-remote'; sh -c "$C" ‖ B for C in 'ls' 'rm -rf @H/gt-remote'; do $C; done ‖ P D="@S/work @S/work/a"; rm -rf $D ‖ P C='ls -la'; $C
B rm -rf ~/.dolt-dat{a..a}/ga ‖ B rm -rf ~/proj/.g{i..i}t ‖ B echo ~/gt-remote | xargs -J % rm -rf % ‖ B echo ~/gt-remote | xargs -S 100 rm -rf ‖ B echo ~/gt-remote | xargs -R 1 rm -rf ‖ B sudo -s 'rm -rf ~/gt-remote' ‖ B sudo -u bob -i rm -rf ~/gt-remote ‖ B doas -s 'rm -rf ~/gt-remote' ‖ P sudo -s 'ls ~'
B true && C='rm -rf @H/proj2'; $C ‖ B C='rm -r -f @H/gt-remote/git/gas*'; $C ‖ B C='unlink @H/.dolt-data/ga/.dolt/noms/man*'; bash -c "$C" ‖ B true && C='rm @H/proj2'; eval "$C" ‖ B true && R=rm; $R @H/proj2 ‖ P D=@S/work; true && C='rm -rf @S/work/a'; $C ‖ P C='/bin/r? -rf @S/work/a'; $C ‖ B time D=@H/proj/.git/HEAD; f() { D=/tmp/ok; }; unlink "$D" ‖ B time C='shred @H/proj2'; $C ‖ P D=@S/work; env D=@H/proj2; rm -rf "$D" ‖ P D=@S/work; command D=@H/proj2; rm -rf "$D" ‖ B D=@H/proj2; env A=1; rm -f "$D" ‖ B echo ~/proj2 | while read D; do rm -f "$D"; done ‖ B true && echo @H/gt-remote/git | while read D; do rmdir "$D"; done ‖ B echo ../proj2 | while read D; do shred "$D"; done ‖ P echo @S/work | while read D; do rm "$D"; done ‖ B echo @H/.beads/{b,zz} | while read D; do rmdir "$D"; done ‖ B rm @H/pro{j..j} ‖ B shred @H/gt-remote/git/gascity/wt/s{1..1} ‖ B rm @H/gt-remote/git/gascity/wt/s{0..1} ‖ B rm @H/proj/.gi{t..t}/HEAD ‖ P rm @H/proj/build/x.{o..o} ‖ B T='@S/work @H/proj/.git/x.p{y..y}'; for t in $T; do rm "$t"; done ‖ B printf -v D %s @H/proj2; unlink "$D" ‖ P printf -v D %s @S/work; D=@H/proj2 true; unlink "$D" ‖ B D=@H/proj2; false && read D <<< @S/work; unlink "$D" ‖ B D='@H/proj/.git/x{1..100}'; rm "$D" ‖ B D='@H/proj/.git/x{1..100}'; rm $D ‖ P D='@S/work/x{1..100}'; rm "$D" ‖ B true && C='shred @H/proj/.git/index.loc{k..k}'; $C ‖ B C='rm @H/proj/.git/index.loc{k..k}'; $C ‖ B select d in @H/proj2 x; do unlink "$d"; done ‖ P select d in @S/work x; do unlink "$d"; done ‖ B D=@H/proj2 bash -c 'rm "$D"' ‖ P D=@S/work bash -c 'rm "$D"' ‖ B D=@H/proj2; { D=@S/work; } | cat; unlink "$D" ‖ P D=@S/work; { D=@S/work/a; }; rm -rf "$D" ‖ B D=@H/proj2; echo ${D:=@S/work} | cat; unlink "$D" ‖ B D=@S/work; while true; do unlink "$D"; D=@H/proj2; done ‖ P D=@S/work; while true; do unlink "$D"; D=@S/work/a; done ‖ B n=D; D=@S/work; read "$n" <<< @H/proj2; rm -rf "$D" ‖ B D=@H/proj/; rm "${D%/}/.git/HEAD" ‖ B D=@H/proj/.git/HEAD.bak; unlink "${D%.bak}" ‖ B unlink "${U:-@H/proj/.git/HEAD}" ‖ B D=@H/proj/.git/HEAD; unlink "${D:-@S/work}" ‖ B D=xx@H/proj/.git/HEAD; unlink "${D#xx}" ‖ B D=@H/proj/.git/zz; unlink "${D/zz/HEAD}" ‖ B D=@H/proj/.git/HEAD; rm ${D%%/zz} ‖ P D=@S/work/a; rm "${D%/a}/b" ‖ P unlink "${U:-@S/work}" ‖ B D=@S/work; unlink "${D:+@H/proj/.git/HEAD}"
B time f() { D=@H/proj/.git/HEAD; }; D=/tmp/ok; f; unlink "$D" ‖ B ! f() { D=@H/proj/.git/HEAD; }; D=/tmp/ok; f; unlink "$D" ‖ B time -p f() { D=@H/proj/.git/HEAD; }; D=/tmp/ok; f; unlink "$D" ‖ P time f() { echo hi; }; f; unlink @S/work/a ‖ B D+=/gascity; shred "$D" ‖ B unset D; D+=/gascity; shred "$D" ‖ B nohup D=@S/work; D+=/gascity; shred "$D" ‖ P D=@S/work; D+=/a; unlink "$D" ‖ P D+=@S/work/a; unlink "$D" ‖ B D=@H/proj/.git.bak; rm -rf "${D%.bak}" ‖ P D=@H/proj/.git.bak; rm -rf "$D" ‖ B D=@H/proj/.git.bak.bak; rm -rf "${D%%.bak*}" ‖ P D=@H/proj/.git.bak.bak; rm -rf "${D%.bak}" ‖ B D=xx@H/proj2; rm -rf "${D#xx}" ‖ P D=xx@H/proj2; rm -rf "$D" ‖ B D=ab@H/proj2; rm -rf "${D##a?}" ‖ B D=@H/proj/gitx; rm "${D/gitx/.git}" ‖ P D=@H/proj/gitx; rm "$D" ‖ B unlink ${U:-@H/proj/.git/HEA{D..D}} ‖ B D=x; shred "${D:+"${HOME}/gt-remote/big"}" ‖ P D=x; shred "${D:+"${HOME}/notes.txt"}" ‖ B unlink "${U:-${HOME}/proj/.git/HEAD}" ‖ P unlink "${U:-${HOME}/notes.txt}" ‖ B D=@H/proj/.git.bak; E=.bak; rm -rf "${D%$E}" ‖ P D=@H/proj/.git.bak; E=.zz; rm -rf "${D%$E}" ‖ B D=@H/proj2; "D=@S/work"; rm -rf "$D" ‖ B D=@H/proj2; 'D=@S/work'; rm -rf "$D" ‖ P D=@S/work; "D=@H/proj2"; rm -rf "$D" ‖ P D=@H/proj2; D="@S/work"; rm -rf "$D" ‖ B D=@S/work; env "D=@H/proj2" bash -c 'rm -rf "$D"' ‖ P D=@S/work; env "D=@S/work/a" bash -c 'rm -rf "$D"' ‖ B D=x; shred ${D:+"${HOME}/gt-remote/big"} ‖ B rm -r ${U:-@H/gt/rig/.gc-worktrees/{w,zz}} ‖ B bash -c 'rm -f ${U:-"${HOME}/gt/rig/shared/data"}' ‖ B eval 'D="${HOME}/gt/rig"; rm "${D:+"${HOME}/gt/rig"}" -r' ‖ B D=@H/proj/.git; unlink "${U:-${D}/HEAD}" ‖ P unlink ${U:-"${HOME}/notes.txt"} ‖ P D=x; unlink "${D:+"@S/work/a"}" ‖ B unlink "${U:-}"@H/proj/.git/HEAD ‖ B:z unlink ${U:-}${U:-"@H"}/proj/.git/HEAD ‖ B:s D=@H/proj/.git; unlink ${U:-${D}/HEAD;x} ‖ B:s unlink ${U:-"} ;"@H/proj/.git/HEAD} ‖ B:s unlink ${U:-'} ;'@H/proj/.git/HEAD} ‖ P:z unlink ${U:-"} ;"@S/work/a} ‖ P:z unlink ${U:-'}'@S/work/a}
B env -C @H/gt-remote rm -rf git ‖ B env -C@H/gt-remote rm -rf git ‖ B env --chdir=@H/gt-remote rm -rf git ‖ B env --chdir @H/gt-remote rm -rf git ‖ B sudo -D @H/gt-remote rm -rf git ‖ B sudo --chdir=@H/gt-remote rm -rf git ‖ B sudo --chdir @H/gt-remote rm -rf git ‖ P env -C @S/work rm -rf a ‖ P env --chdir=@S/work rm -rf a ‖ P sudo -D @S/work rm -rf a
B env -C "$X" rm -rf build ‖ P env -C "$X" rm -f build ‖ B env -C .. rm -rf proj2 ‖ B env -C @H/gt-remote bash -c 'rm -rf git' ‖ B env -C @H/gt-remote find . -mindepth 1 -delete ‖ B {rm,-rf,@H/proj} ‖ B r{m,} -rf @H/proj ‖ B {rm,-rf} @H/proj ‖ P {ls,-la,@H/proj} ‖ B rm --{recursive,force} @H/gt/rig/shared ‖ B rm -{r,f} @H/gt/rig/shared ‖ P rm -{f,v} @H/gt/rig/shared
B if true; then cd @H/gt-remote; rm -rf git; fi ‖ B { cd @H/gt-remote; rm -rf git; } ‖ B while true; do cd @H/gt-remote; rm -rf git; done ‖ B f() { cd @H/gt-remote; rm -rf git; }; f ‖ P if true; then cd @S/work; rm -rf a; fi
B x="$(echo "a\"b")"; rm -rf @H/proj ‖ P x="$(echo "a\"b")"; rm -f @S/work/a ‖ B echo "$(echo hi; rm -rf @H/proj ‖ B echo "oi; rm -rf @H/proj ‖ P echo "oi; ls ‖ B echo ${x:-oi; rm -rf @H/proj
B echo 'oi; rm -rf @H/proj ‖ P echo 'oi; ls ‖ B echo `echo '`; rm -rf @H/proj; echo '`' ‖ B echo "oi; r""m -rf @H/proj ‖ B echo "oi; $'\x72m' -rf @H/proj ‖ B rm --{a,b,c}{a,b,c}{a,b,c}{a,b,c} @H/gt/rig/shared
B F=-rf; rm $F ~/gt ‖ B F=-fr; rm $F ~/gt ‖ B F='-r -f'; rm $F ~/gt ‖ B F=-rf; rm "$F" ~/gt ‖ B F=-rf; rm ~/gt $F ‖ B F=--recursive; rm $F ~/gt ‖ B F=-rf; rm $F ~/gt/rig/shared ‖ B F=-rf; rm $F ~/.ssh ‖ B F=-rf; sudo rm $F ~/gt
B F=-rf; env rm $F ~/gt ‖ B F=-rf; command rm $F ~/gt ‖ B F=-rf; echo ~/gt | xargs rm $F ‖ B export F=-rf; bash -c 'rm $F ~/gt' ‖ B F=-rf; eval 'rm $F ~/gt' ‖ B for f in -rf; do rm $f ~/gt; done ‖ B for f in -v -rf; do rm $f ~/gt; done
B rm ${RMFLAGS:--rf} ~/gt/rig/shared ‖ B rm ${RMFLAGS:--rf} ~/gt ‖ B rm $RMFLAGS ~/gt/rig/shared ‖ B rm $RMFLAGS ~/.claude ‖ B rm $(echo -rf) ~/gt ‖ B rm `echo -rf` ~/gt ‖ B rm {-rf,~/gt} ‖ B rm ~/gt {-rf,x} ‖ B rm {-r,-f} ~/gt
B rm $UNSET ~/gt ‖ B rm -f $UNSET ~/gt ‖ P rm $UNSET ~/notes.txt ‖ P unlink $UNSET ~/gt ‖ P rm -f $UNSET ‖ P rm $UNSET/x ‖ P F=-f; rm $F ~/gt ‖ P F='-f -v'; rm $F ~/gt ‖ P F=-v; rm "$F" ~/gt ‖ P F=-rf; rm -- $F ~/gt ‖ P rm -- $F ~/gt
B C='rm -rf ~/gt $(date)'; eval "$C" ‖ B C='rm -rf ~/gt $(date)'; $C ‖ B C='rm $(echo -rf) ~/gt'; bash -c "$C" ‖ B true && C='rm ~/.beads/{b..b} $(echo -f)'; $C ‖ P C='ls -la $(pwd)'; $C ‖ P C='echo $(date)'; eval "$C"
B rm -rf {~/gt,x} ‖ B rm -rf x {y,~/gt} ‖ B rm --{a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q} $UNSET ‖ P rm -rf {x,@S/work/a}
B F=-rf; rm $F -- ~/gt ‖ P rm ${U:-a,b} ‖ P U=; rm -rf ${U:-/tmp/ok,@H/gt} ‖ P D=aaaa; rm -rf ${D%%a} ‖ P F=-rf; unlink $F ~/gt
B:w rm -f data/x.db ‖ B:w rm -f ./data/* ‖ B rm -f ~/gt/wa/data/x.db ‖ B rm -f @H/gt/wa/data/x.db ‖ B rm -f @H/shared/data/x.db ‖ B rm @H/shared/data/prod.db ‖ B rm -rf @H/shared/data ‖ B rm -f ~/gt/wa/shared/data/x.db ‖ B rm -f @S/lnkdata/x.db ‖ B rm -rf @S/lnkdata ‖ B cd @H/gt/wa && rm -f data/x.db ‖ B cd @S/lnkdata && rm -f x.db
B find @H/shared -name '*.db' -delete ‖ B find @H/shared/data -name x -delete ‖ B find @H/gt/wa/data -name '*.db' -delete ‖ B rm -rf @H/shared ‖ P rm -f @H/shared/note.txt ‖ P rm -f ~/shared/other.txt ‖ P rm @H/shared/note.txt
B rm -f @S/L/../ga2.db ‖ B rm -f @S/Ld/../ga2.db ‖ B rm -f @S/L/../ga*.db ‖ B find @S/Ld/.. -name 'ga2*' -delete ‖ B D=@S/L/..; rm -f $D/ga2.db ‖ B cd @S/L && rm -rf ../ga2.db ‖ B cd @S/Ld && rm -f ../ga2.db ‖ B (cd @S/L; rm -f ../ga2.db) ‖ B pushd @S/L >/dev/null; rm -f ../ga2.db
B env -C @S/L rm -f ../ga2.db ‖ B sudo -D @S/Ld rm -f ../ga2.db ‖ B bash -c 'cd @S/L && rm -f ../ga2.db' ‖ B cd -P @S/L/.. && rm -f ga2.db ‖ B cd -P @S/Ld/.. && rm -f ga2.db ‖ B rm -rf */ ‖ B cd @H/.beads/lnkout/.. && rm -f b ‖ B env -C @H/.beads/lnkout/.. rm -f b ‖ B cd @S/lnkdata/yo/.. && rm -f prod.db ‖ B env -C @S/lnkdata/yo/.. rm -f prod.db ‖ B sudo -D @S/lnkdata/yo/.. rm -f prod.db ‖ P rm -f @S/lnkok/../many/f1 ‖ P cd @S/lnkok && rm -f ../many/f1 ‖ P rm -rf @S/lnkok/../many/f1
B cd D && true; rm -rf * ‖ B cd D && true || true; rm -rf * ‖ B pushd D >/dev/null && true; rm -rf * ‖ B cd D && true & rm -rf * ‖ B cd D && cd E; rm -rf * ‖ B cd D && (true); rm -rf * ‖ B (cd D && true; rm -rf *) ‖ B cd D && true | cat; rm -rf * ‖ B:h cd /nonexistent && true; rm -rf gt-remote ‖ B cd D && true; cd E && true; rm -rf *
P cd @S/work && true; rm -rf a ‖ P cd @S/work && rm -rf a; true ‖ B cd @S/work && (rm -rf *) ‖ B cd @S/work && (true; rm -rf *) ‖ B cd @S/work && true && rm -rf * ‖ P (cd @S/work && true); rm -rf build ‖ B cd @S/work && echo hi | rm -rf * ‖ P cd @H/proj/build && true; rm -rf *.o
B:p cd ~/gt-remote; rm -rf "$PWD" ‖ B:p cd ~; rm -rf $PWD ‖ B:p (cd ~; rm -rf $PWD) ‖ B:p pushd ~ >/dev/null; rm -rf $PWD ‖ B:p cd ~; D=$PWD; rm -rf "$D" ‖ B:p cd ~ && true; rm -rf $PWD ‖ B:p cd ~ && true; rm -rf $(pwd)/x ‖ B:p cd ~; rm -rf "$(pwd)" ‖ B:p cd ~; for d in $PWD; do rm -rf "$d"; done ‖ B:p cd ~; rm -rf ${PWD} ‖ B:p cd ~; rm -rf `pwd` ‖ B:p cd ~; D=$PWD/gt-remote; rm -rf "$D" ‖ B:p popd; rm -rf $PWD
P:p cd @S/work; rm -rf $PWD ‖ P:p cd @S/work && true; rm -rf $PWD ‖ P:p rm -rf "$PWD" ‖ P:p cd ..; D=$PWD; rm -rf "$D"
B rm -rf ** ‖ B rm -rf *** ‖ B rm -rf *? ‖ B rm -rf [!.]* ‖ B rm -rf [^.]* ‖ B rm -rf ./** ‖ B rm -rf ./[!.]* ‖ B rm -rf .?* ‖ P rm -rf x* ‖ P rm -rf _* ‖ P rm -rf 1* ‖ P rm -rf é* ‖ P rm -rf build* ‖ P rm -rf s*c ‖ P:b rm -rf ** ‖ P:b rm -rf [!.]*
B:p find -E @H/gt-remote -regex '.*' -delete ‖ B:p find -x @H/gt-remote -delete ‖ B:p find -d @H/gt-remote -delete ‖ B:p find -s @H/gt-remote -delete ‖ B:p find -X @H/gt-remote -delete ‖ B:p find -O3 @H/gt-remote -delete ‖ B:p find -D tree @H/gt-remote -delete ‖ B:p find -H -x @H/gt-remote -delete ‖ B:p find -f @H/gt-remote -delete ‖ B:p find -f @S/work -f @H/gt-remote -delete ‖ B:p find -E @H/gt-remote -mindepth 1 -delete ‖ B:p find -x @H/proj -name '*' -delete
P find -x @S/work -mindepth 1 -delete ‖ P find -x @H/proj/build -delete ‖ P:h find -D tree @S/work -mindepth 1 -delete ‖ P:p find -f @S/work -mindepth 1 -delete ‖ P find -x ~/proj -name '*.pyc' -delete
B shopt -s extglob; rm -rf !(x) ‖ B bash -O extglob -c 'rm -rf !(x)' ‖ B shopt -s ext''glob; rm -rf !(x) ‖ P shopt -s extglob ‖ P echo extglob ‖ P grep extglob notes.txt
B python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' @H/gt-remote ‖ B node -e "require('fs').rm(process.argv[1],{recursive:true},()=>{})" @H/gt-remote ‖ P node -e "require('fs').rm(process.argv[1],()=>{})" @S/work/a ‖ B node -e "require('fs').rmSync(process.argv[1],{recursive:true})" @H/gt-remote ‖ B perl -e 'use File::Path qw(rmtree); rmtree($ARGV[0])' @H/gt-remote ‖ B python3 -c "import shutil,os; shutil.rmtree(os.environ['D'])" ‖ B ruby -e "require 'fileutils'; FileUtils.rm_rf(ARGV[0])" @H/gt-remote ‖ P python3 -c "import os,sys; os.remove(sys.argv[1])" @S/work/a ‖ P python3 -c "import sys; print(sys.argv[1])" x ‖ P python3 -c "import shutil; shutil.rmtree('@S/work/a'); import sys; print(sys.argv)"
B:p find -xE @H/gt-remote -delete ‖ B:p find -Ex @H/gt-remote -delete ‖ B:p find -xEd @H/gt-remote -delete ‖ B:p find -HLP @H/gt-remote -delete ‖ B:p find -EX @H/gt-remote -mindepth 1 -delete ‖ B:p find -f@H/gt-remote -delete ‖ B:p find -xf@H/gt-remote -delete ‖ B:p find -- @H/gt-remote -delete ‖ B:p find -x -- @H/gt-remote -delete ‖ B find -fprint @S/out -delete ‖ B find -fls @S/out -delete ‖ B find -fprintf @S/out %p -delete ‖ B find -fstype ext4 -delete ‖ B find -follow -delete ‖ B find -false -o -delete ‖ B find -fstype ext4 -mindepth 1 -delete ‖ P:p find -fstype ext4 -mindepth 1 -delete ‖ P find -fprint @S/out -name x ‖ P:p find -fprint /dev/null -mindepth 1 -delete ‖ P:p find -fls /dev/null -mindepth 1 -delete ‖ P:p find -fprint0 /dev/null -mindepth 1 -delete ‖ P:p find -fprintf /dev/null %p -mindepth 1 -delete ‖ B:b find -fprint/../../../gt-remote -delete ‖ B:b find -xfprint/../../../gt-remote -delete
P find -xE @S/work -mindepth 1 -delete ‖ P find -- @S/work -mindepth 1 -delete ‖ P:p find -HLP @S/work -mindepth 1 -delete ‖ P:h find -xEd @S/work -mindepth 1 -delete
B for a in /tmp/a1 /tmp/a2 /tmp/a3 /tmp/a4 /tmp/a5 /tmp/a6 /tmp/a7 /tmp/a8 ~/gt-remote; do for b in "" -1 -2 -3 -4 -5 -6 -7 -8; do rm -rf "$a$b"; done; done ‖ P for a in /tmp/a1 /tmp/a2 /tmp/a3 /tmp/a4 /tmp/a5 /tmp/a6 /tmp/a7 /tmp/a8; do for b in "" -1 -2 -3 -4 -5 -6 -7; do rm -rf "$a$b"; done; done ‖ B echo "import shutil,sys; shutil.rmtree(sys.argv[1])" | python3 - @H/gt-remote
P echo $'C:\Users\bob' ‖ P grep -c $'\x' notes.txt ‖ P echo x{1..99999999999999999999} ‖ B rm -rf ~/x{1..99999999999999999999}
B true || cd @S/work && rm -rf * ‖ B cd . || cd @S/work && rm -rf * ‖ B [ -d . ] || cd @S/work && rm -rf * ‖ B echo x | cd @S/work && rm -rf * ‖ B ! cd /nonexistent && rm -rf *
B true || pushd @S/work >/dev/null && rm -rf * ‖ B bash -c 'true || cd @S/work && rm -rf *' ‖ B (true || cd @S/work) && rm -rf * ‖ B cd @S/work |& cd @S/work && rm -rf * ‖ B:s cd @H/proj || cd @S/work/a && rm -rf *
B:s true || cd @H/proj && rm -rf "$PWD" ‖ B:s echo x | cd @H/proj && rm -rf "$(pwd)" ‖ B:s ! cd @H/proj && rm -rf $PWD ‖ B:s eval "cd @H/proj"; rm -rf * ‖ B:s bash -c "cd @H/proj"; rm -rf *
B:s pushd @H/proj >/dev/null; popd >/dev/null; rm -rf * ‖ B:s cd @H/proj; cd @S/work && rm -rf * ‖ B:s cd @S/work/a; cd @H/proj; cd @S/work/b || rm -rf . ‖ B:s true || cd "$UNSET" && rm -rf x ‖ B:s cd - ; rm -rf x
B:s popd >/dev/null 2>&1; rm -rf x ‖ B:s pushd >/dev/null 2>&1; rm -rf x ‖ B:p while true; do cd ..; rm -rf x; done ‖ B:p for i in 1 2 3; do cd ..; done; rm -rf x ‖ B:p f() { cd ..; }; f; f; rm -rf x
B:p f() { cd sub; }; f; f; rm -rf x ‖ B:p for i in 1 2; do cd $PWD/a; done; rm -rf x ‖ P:p cd .. && rm -rf x ‖ P:p cd .. && rm -rf * ‖ P:p true || cd @S/work/b && rm -rf *
P:p echo x | cd @S/work && rm -rf "$PWD" ‖ P:p ! cd @S/work/a && rm -rf $(pwd) ‖ P:p for d in a b; do cd @S/work/$d; done; rm -rf x ‖ P:p cd @S/work/a; cd @S/work/b; rm -rf * ‖ P:p f() { cd @S/work; }; f; f; rm -rf x
P:s pushd @S/work/a >/dev/null; rm -f x ‖ P:s cd "$UNSET" && rm -f x ‖ P cd @H/proj/build && rm -rf x ‖ P:p cd @S/work || rm -rf x ‖ B:s pushd >/dev/null; rm -rf x
B:s popd >/dev/null; rm -rf x ‖ P:s cd @S/work/a >/dev/null 2>&1 && rm -rf x ‖ B:p cd ../.. && cd lnkgit && rm -rf * ‖ B:p cd ../.. && cd lnkgit && rm -rf "$PWD" ‖ P:p cd .. && cd b && rm -rf *
P:p cd .. && cd .. && rm -rf x ‖ P:p for i in 1 2; do :; done; cd .. && rm -rf x ‖ P:p cd .. && rm -rf x; for i in 1; do : ‖ B:p while true; do cd ../..; rm -rf x; done
B:s FOO=1 cd @H/proj && rm -rf * ‖ B:s FOO=1 BAR=2 cd; rm -rf * ‖ B:s true || FOO=1 cd @H/proj && rm -rf * ‖ B:s FOO=1 pushd >/dev/null; rm -rf x ‖ P:s FOO=1 cd @S/work/a && rm -rf * ‖ P:s cd >/dev/null @S/work/a && rm -rf x ‖ P:s pushd >/dev/null @S/work/a && rm -rf x ‖ P:s cd 2>/dev/null @S/work/a && rm -rf x ‖ B:s cd >/dev/null; rm -rf x ‖ B:s pushd >/dev/null; rm -rf x
"""
X = [("B", "C=\"rm -rf 'a @H/proj b'\"; $C"), ("B", "C='rm -rf \"a @H/proj b\"'; $C"), ("B", "C='rm -rf a # @H/proj'; $C"), ("B", "C='rm -rf a\\ @H/proj'; $C"), ("B", "C='rm -rf \"@H/proj\"'; eval \"$C\""), ("B", "C=\"rm -rf '@H/proj'\"; bash -c \"$C\""), ("B", "C='rm -Rf \"${HOME}/proj2\"'; eval \"$C\""), ("B", "echo `echo '`; rm -f @S/work/a; echo `echo '`"), ("P", "x=$((1 << 3 \n + 1))\nrm -f @S/work/a"), ("P", "x=$(( (1<<3)\n + 1 )); echo $x"), ("B", "x=$((rm -rf @H/proj) | wc)"), ("P", "for ((i=0;i<1<<3;i++)); do :; done\nrm -f @S/work/a"), ("B", "cat <<E\"O\"F\nx\nEOF\nrm -rf @H/proj"), ("B", "echo \"$(cat <<'EOF'\nit's\nEOF\n)\"; rm -rf @H/proj"), ("B", "git commit -m \"$(cat <<'EOF'\nfix: don't break\nEOF\n)\" && rm -rf @H/proj"), ("P", "git commit -m \"$(cat <<'EOF'\nfix: don't use rm -rf ~/gt-remote\nEOF\n)\""),
     ("B", "((x = 1 << 3))\nrm -rf @H/proj"), ("P", "((x = 1 << 3))\nrm -f @S/work/a"), ("B", "for ((i=0;i<1<<3;i++)); do :; done\nrm -rf @H/proj"), ("P", "echo $((1 << 3))\nrm -f @S/work/a"), ("P", "x=\"$(echo \"a\\\"b\")\"\nrm -f @S/work/a"),
     ("B", "echo \"$(echo hi # it's\n)\"; rm -rf @H/proj"), ("B", "cat <<EOF\n$(rm -rf @H/proj)\nEOF"), ("B", "cat <<EOF\n`rm -rf @H/proj`\nEOF"), ("P", "cat <<'EOF'\n$(rm -rf @H/proj)\nEOF"), ("B", "bash -c \"$(cat <<'EOF'\nrm -rf @H/proj\nEOF\n)\""), ("B", "eval \"$(cat <<EOF\nrm -rf @H/proj\nEOF\n)\""),
     ("B", "tcsh <<'EOF'\nrm -rf ~/gt-remote\nEOF"),("B", "bash <<'EOF'\nrm -rf ~/gt-remote\nEOF"), ("B", "cat <<'EOF' | sh\nrm -rf ~/gt-remote\nEOF"), ("B", "python3 - <<'EOF'\nimport shutil\nshutil.rmtree('@H/gt-remote')\nEOF"), ("B", "echo \"import shutil; shutil.rmtree('@H/gt-remote')\" | python3 -"),
     ("P", "git commit -m \"$(cat <<'EOF'\nfix: stop using rm -rf ~/gt-remote\nEOF\n)\""), ("P", "cat <<'EOF'\nrm -rf ~\nEOF"), ("P", ""), ("P", "   "), ("B", "# c\nrm -rf ~/gt-remote"), ("B", "x=1\nrm -rf ~/gt-remote"),
     ("B", "X=~/gt-remote; bash <<'EOF'\nrm -rf \"$X\"\nEOF\nX=/tmp/safe"), ("B", "cd ~ && python3 - <<'EOF'\nimport shutil\nshutil.rmtree('gt-remote')\nEOF"), ("B", "cd ~ && bash <<'EOF'\nrm -rf gt-remote\nEOF"), ("P", "python3 - <<'EOF'\np = 'tests/foo.py'  # remove the old text, delete nothing\ns = open(p).read().replace('old', 'new')\nEOF"), ("B", nest(8)), ("P", nest(3)), ("B", "echo " + "x" * 300000), ("P", "echo " + "x" * 60000), ("B", "FOO=1 BAR=2 rm -rf ~/gt-remote")]
X += [("B", "D=" + "a" * 60 + "; rm -rf ${D%%*a*a*a*b}"), ("B", "D=" + "a" * 300 + "; rm -rf ${D%%a}")]  # ${ } com padrão de muitos `*` ou valor longo: o regex recuaria por minutos; vale "não sei" e a remoção recursiva é barrada
X += [("B", "cd build-xyz && make\nrm -rf *"), ("B", "cd D && true\nrm -rf *"), ("B", "cd D && true || true\nrm -rf *"), ("B", "pushd D >/dev/null && true\nrm -rf *"), ("P", "cd @S/work && true\nrm -rf a"), ("B", "shopt -s extglob\nrm -rf !(x)"), ("B", "cd nope && true; cd ~/gt-remote/git\nrm -rf gascity"), ("B", "python3 - <<'EOF'\nimport shutil,sys\nshutil.rmtree(sys.argv[1])\nEOF")]
X3 = [("B", "cd ~/gt-remote\nrm -rf \"$PWD\"", "p"), ("B", "cd ~\nD=$PWD\nrm -rf \"$D\"", "p"), ("B", "cd ~ && true\nrm -rf $(pwd)/x", "p"), ("P", "cd @S/work && true\nrm -rf $PWD", "p"), ("B", "cd ~/gt-remote && true\nrm -rf \"$PWD\"", "p")]  # (esperado, comando, tag do cwd): o rm só é barrado se `$PWD` valer o cwd de DEPOIS do cd, que não é o cwds[0]
TABLE = []
for line in DSL.strip().split("\n"):
    for part in line.split(" ‖ "):
        v, cmd = part.split(" ", 1)
        TABLE.append((v[0], cmd, CWDS.get(v[2:], CWD)))
TABLE += [(w, c, CWD) for w, c in X]
TABLE += [(w, c, CWDS[k]) for w, c, k in X3]
if DENIES:  # vazio → pasta sem nada passa (work2/open); falhou/ilegível (sem permissão de ler / de entrar) → vale como se guardasse um repo
    TABLE += [("B", "rm -rf @H/work2/locked", CWD), ("B", "rm -rf @H/work2/xonly", CWD), ("B", "rm -rf @H/work2/rdonly", CWD)]  # rdonly: lista mas não entra, então só o lstat do .git diz "não sei"
else:
    print("SKIP pasta ilegível: chmod 000/100/400 não nega aqui (root?): as 3 linhas work2/locked, xonly e rdonly e os 2 mutantes que dependem delas (lstat que falha, pasta ilegível) não rodam")


def run_table(m):
    bad = []
    for want, cmd, cwd in TABLE:
        cmd = cmd.replace("@HUP", H.upper()).replace("@H", H).replace("@S", S)
        os.environ["HOME"] = cwd if cwd == CWDS["z"] else H
        try:
            got = "B" if m.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}) else "P"
        except Exception as e:  # noqa: BLE001
            got = "ERRO " + repr(e)[:40]
        if got != want:
            bad.append(f"{cmd[:70]!r} esperado={want} veio={got}")
    os.environ["HOME"] = H
    return bad


def ceilings(m):
    """Os três tetos (GLOB_MAX, LS_BUDGET, LIMIT) só aparecem baixando-os: o módulo `m` é recarregado para não deixar o valor baixo para trás."""
    c, out = load(m.__file__), []
    c.GLOB_MAX = 3
    if not c.decide({"tool_name": "Bash", "tool_input": {"command": f"rm -rf {S}/many/*"}, "cwd": CWD}):
        out.append("teto GLOB_MAX")
    c.GLOB_MAX, c.LS_BUDGET = 20000, 0
    if not c.decide({"tool_name": "Bash", "tool_input": {"command": f"rm -rf {H}/proj/build"}, "cwd": CWD}):
        out.append("orçamento LS_BUDGET")
    c.LS_BUDGET, c.LIMIT = 20000, -1
    if not c.decide({"tool_name": "Bash", "tool_input": {"command": f"rm -rf {S}/work"}, "cwd": CWD}):
        out.append("prazo LIMIT")
    return out


def optglob(m):
    """`rm *` numa pasta que faz de HOME e guarda um arquivo `-rf`: o bash entrega `rm -rf d` (injeção por curinga). Sem o arquivo, o mesmo comando não apaga pasta nenhuma."""
    out, g = [], [os.path.realpath(tempfile.mkdtemp(prefix="rmtgop.")) for _ in (0, 1)]
    for p in g:
        os.makedirs(f"{p}/d")
    open(f"{g[0]}/-rf", "w").close()
    for p, cmd, want in ((g[0], "rm *", True), (g[1], "rm *", False), (g[0], "rm ./*", False)):  # `./*` entrega `./-rf` (operando, não opção): passa
        os.environ["HOME"] = p
        if bool(m.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": p})) != want:
            out.append(f"opção que vem de glob: `{cmd}` com {'`-rf`' if p == g[0] else 'a pasta sem `-rf`'} tem de {'bloquear' if want else 'passar'}")
    os.environ["HOME"] = H
    for p in g:
        shutil.rmtree(p, ignore_errors=True)
    return out


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("ok   " if ok else "FAIL ") + name + (" — " + detail if (detail and not ok) else ""))


m = load(GUARD)
bad = run_table(m)
check(f"tabela: {len(TABLE)} casos", not bad, "\n     ".join(bad[:40]))


def e2e(raw=None, tool="Bash", cmd="ls", guard=GUARD):
    p = subprocess.run(["python3", "-I", guard], input=raw if raw is not None else json.dumps({"tool_name": tool, "tool_input": {"command": cmd}, "cwd": CWD}), text=True, capture_output=True, timeout=30)
    return p.returncode, p.stderr


rc, err = e2e(cmd="rm -fr ~/gt-remote")
check("ponta a ponta: bloqueio sai 2 com a mensagem (alvo, regra, não é cancelamento, saída segura)", rc == 2 and all(s in err for s in ("[HOOK BLOCK: rm-target-guard]", "NÃO É CANCELAMENTO", "rm.home-child", "gt-remote", "safe-clean", "find <pasta>")), err[:200])
check("ponta a ponta: liberado sai 0 sem ruído; scratch também", e2e() == (0, "") and e2e(cmd=f"rm -rf {S}/work") == (0, ""))
check("ponta a ponta: stdin que não é um pedido legível (JSON quebrado, lixo, lista) bloqueia; stdin vazio libera; outra ferramenta libera",
      all(e2e(raw=r)[0] == 2 for r in ('{"command": ', "lixo", "[]")) and e2e(raw="")[0] == 0 and e2e(tool="Write", cmd="rm -rf ~")[0] == 0)
SRC = open(GUARD).read()
crash = f"{H}/crash.py"
open(crash, "w").write(SRC.replace("def decide(inp: dict):", "def decide(inp: dict):\n    raise RuntimeError('boom')", 1))
check("ponta a ponta: bytes inválidos no stdin (locale UTF-8 estrita: sem o decode com replace o guarda sairia 1 e NÃO bloquearia) e surrogate solto no comando continuam bloqueando", e2e(raw='{"tool_name":"Bash","tool_input":{"command":"rm -rf /\\ud800"},"cwd":"/tmp"}')[0] == 2 and subprocess.run(["python3", "-I", GUARD], input=b'{"tool_name":"Bash","tool_input":{"command":"rm -rf /\xff"},"cwd":"/tmp"}', capture_output=True, env={**os.environ, "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"}).returncode == 2)
rc, err = e2e(cmd="ls", guard=crash)
check("ponta a ponta: o guarda falhando num pedido Bash = bloqueado (nunca liberado)", rc == 2 and "o guarda falhou" in err, err[:120])
check("tetos: curinga além de GLOB_MAX = alvo desconhecido, pasta além de LS_BUDGET = guarda repo, prazo LIMIT estourado = bloqueado (com os tetos de verdade os mesmos comandos passam: linhas da tabela)", not ceilings(m), str(ceilings(m)))
check("opção do rm que vem de curinga: arquivo `-rf` na pasta faz `rm *` recursivo (e sem o arquivo passa)", not optglob(m), str(optglob(m)))

# --- fuzzer contra o bash REAL: rm/unlink/rmdir/shred/find são FALSOS (primeiros no PATH), gravam verbo, cwd e argv exatamente como o shell os entregou ---
LOG = f"{H}/log.bin"
FAKE = "#!/bin/sh\n{ printf '%%s\\0' \"${0##*/}\" \"$PWD\" \"$@\"; printf '\\1\\n'; } >> %s\n" % LOG
for n in ("rm", "unlink", "rmdir", "shred", "find"):
    open(f"{H}/bin/{n}", "w").write(FAKE); os.chmod(f"{H}/bin/{n}", 0o755)
DENY = {".dolt", ".dolt-data", ".beads", ".git", ".gc-worktrees", "crew"}
REPOS = [f"{H}/{r}" for r in ("proj", "proj2", "gt-remote/git/gascity/repo.git", "gt-remote/git/gascity/wt/s1", "gt-remote/big/zrepo")]
DATA = [f"{H}/gt-remote/git/gascity/repo.git"]


def holds(p, repos):
    return any(r == p or (r.startswith(p + "/") and r[len(p) + 1:].count("/") <= 1) for r in repos)


def verdict(p, rec, sel):
    """Independente do guarda: o que a árvore de teste diz sobre `p` (caminho absoluto já resolvido)."""
    parts = p.split("/")[1:]
    if len(parts) <= 1 or p == H or H.startswith(p.rstrip("/") + "/") or any(c in DENY and not (c == ".git" and i == len(parts) - 2 and parts[-1].endswith(".lock")) for i, c in enumerate(parts)):
        return True
    if not p.startswith(H + "/") or any(c in ("node_modules", "__pycache__") for c in parts) or p.startswith(H + "/.cache"):
        return False
    rel = p[len(H) + 1:].split("/")
    if rel[0] == "gt" and ((len(rel) >= 4 and rel[2:4] == ["shared", "data"]) or (rec and (len(rel) == 2 or (len(rel) == 3 and rel[2] == "shared")))):
        return True  # dado de produção do rig e os dois ancestrais que o levam junto
    if rel[:2] == ["shared", "data"] or (rec and rel == ["shared"]):
        return True  # o dado de produção MORA em ~/shared/data (o rig só o aponta por link): vale pelo caminho real, com qualquer operação
    if sel:
        return holds(p, DATA)
    return (len(p[len(H) + 1:].split("/")) == 1 and rec and not (os.path.exists(p) and not os.path.isdir(p))) or holds(p, REPOS)


FZ = [CWD]  # cwd do pedido que o fuzzer está julgando: a raiz de um repo, ou uma pasta de scratch onde `$PWD` e o caminho relativo são inofensivos


def touched(cmd):
    open(LOG, "wb").close(); rc = 0
    try:
        rc = subprocess.run(["bash", "-c", cmd], cwd=FZ[0], env={"PATH": f"{H}/bin:/usr/bin:/bin", "HOME": H}, capture_output=True, timeout=10).returncode
    except subprocess.TimeoutExpired:
        pass
    hit = False
    for rec in open(LOG, "rb").read().split(b"\x01\n"):
        if not rec:
            continue
        verb, cwd, *args = [x.decode("utf-8", "surrogateescape") for x in rec.split(b"\0")][:-1]
        if verb == "find":
            i = 0
            while i < len(args) and args[i] in ("-H", "-L", "-P"):
                i += 1
            j = i
            while j < len(args) and args[j][:1] not in ("-", "(", "!"):
                j += 1
            roots, expr = args[i:j] or ["."], args[j:]
            rmish = "-delete" in expr or any(t in ("-exec", "-execdir") and x + 1 < len(expr) and expr[x + 1] in ("rm", "unlink") for x, t in enumerate(expr))
            sel = any(t in ("-name", "-iname", "-regex") and x + 1 < len(expr) and re.search(r"[A-Za-z0-9]", re.sub(r"\[[^\]]*\]", "", expr[x + 1])) for x, t in enumerate(expr))
            ops, rec_ = (roots if rmish else []), True
        else:
            ops, sel = [a for a in args if not a.startswith("-")], False
            rec_ = verb == "rm" and any((a[:1] == "-" and a[:2] != "--" and set(a[1:]) & set("rR")) or a.startswith("--rec") for a in args)
        for a in ops:
            if not a or a[0] in "'\"" or (re.search(r"[*?\[]", a) and not os.path.lexists(os.path.join(cwd, a))):  # `rm ""` (wrapper que engole `D=x;`), texto com curinga que não existe e operando que começa com aspa LITERAL (bash 3.2 e 5 entregam `'/x/.git/y'` com as aspas dentro de `"${D:+'…'}"`: é um caminho relativo que ninguém citou): o rm não apaga nada
                continue
            full = os.path.join(cwd, a)
            hit = hit or verdict(os.path.normpath(full), rec_, sel) or verdict(os.path.realpath(full), rec_, sel)
    return hit, rc


rnd = random.Random(int(os.environ.get("RMTG_SEED", "7")))
BAD = ["proj/.git/config", "proj/.git/HEAD", "proj", "proj2", ".dolt-data/ga", ".dolt-data/ga/.dolt/noms/manifest", ".beads/b", "gt-remote", "gt-remote/keys/gt_mirror", "gt-remote/git", "gt-remote/git/gascity",
       "gt-remote/git/gascity/wt/s1", "gt-remote/big", "gt/rig", "gt/rig/shared", "gt/rig/shared/data", "gt/rig/crew/bob/x.py", "gt/rig/.gc-worktrees/w", "@S/lnkgit", "shared", "shared/data", "shared/data/prod.db", "gt/wa/data", "gt/wa/data/prod.db", "gt/wa/shared/data/prod.db", "@S/lnkdata", "gt/wa/shared"]
OK = ["proj/src/a.py", "proj/build", "proj/build/x.o", "proj/node_modules", "notes.txt", ".cache/pip/w", "proj/.git/index.lock", "gt-remote/git/gascity/wt/s1/src", "@S/work", "@S/work/a", "@S/srepo", "@S/many/f1", "proj/src/m.pyc", "shared/note.txt"]
FLAGS = ["-rf", "-fr", "-r -f", "-f -r", "-Rf", "-rfv", "--recursive --force", "--recur --forc", "-r", "-f", "", "-rf --", "--recursive", "-vr"]
WRAPS = ["env A=1", "command", "nohup", "nice -n 5", "time"] + [w for w in ("timeout 5", "stdbuf -oL") if shutil.which(w.split()[0])]
heredocs = [0]


HOPS = {}


def hop(P):
    """Link do scratch que aponta para o PRÓPRIO alvo: `hop/../nome` cai no pai do alvo pelo kernel (o texto normalizado cairia no scratch)."""
    if P not in HOPS:
        HOPS[P] = f"{S}/hop{len(HOPS)}"; os.symlink(P, HOPS[P])
    return HOPS[P]


def spell(rel):
    P = S + rel[2:] if rel.startswith("@S") else f"{H}/{rel}"
    d, b = os.path.split(P)
    opts = [P, "'" + P + "'", d + "//" + b, d + "/./" + b, P[:5] + "''" + P[5:], d + "/" + b[:3] + "*", d + "/{" + b + ",zz}", os.path.relpath(P, CWD), P + "/", hop(P) + "/../" + b]
    if b[-1:].isalnum():
        opts.append(d + "/" + b[:-1] + "{" + b[-1] + ".." + b[-1] + "}")
    if P.startswith(H + "/"):
        r = P[len(H) + 1:]
        opts += ["~/" + r, "$HOME/" + r, '"${HOME}/' + r + '"']
    return P, rnd.choice(opts)


def core(arg):
    v = rnd.choice(["rm"] * 5 + ["unlink", "shred", "rmdir"])
    f = rnd.choice(FLAGS) if v == "rm" else ""
    f = rnd.choice([f] * 4 + ["${U:-" + f + "}", "$(echo " + f + ")"]) if f else f  # a opção também pode não estar escrita: padrão de variável ou substituição
    return " ".join(rnd.choice([f"{v} {f} {arg}", f"{v} {arg} {f}"]).split())


def late(s, P):
    """Variável com escopo (o bash decide quem vê o quê): prefixo, subshell, pipeline, `&&`, if, laço, função, read/printf -v/eval, `+=`, valor com espaço, linha de comando numa variável, opção do rm numa variável."""
    d, b = os.path.split(P)
    q = shlex.quote(core(s))
    return [f"D={s}; D=/tmp/ok " + core('"$D"'), f"D={s}; (D=/tmp/ok); " + core('"$D"'), f"D={s}; D=/tmp/ok | cat; " + core('"$D"'), f"D=/tmp/ok; true && D={s}; " + core('"$D"'), f"D={s}; false && D=/tmp/ok; " + core('"$D"'),
            f"D={s}; f() {{ D=/tmp/ok; }}; " + core('"$D"'), f"f() {{ D={s}; }}; f; " + core('"$D"'), f"f() {{ D={s}; }}; D=/tmp/ok; f; " + core('"$D"'), f"read D <<< {s}; " + core('"$D"'), f"printf -v D %s {s}; " + core('"$D"'), f"eval D={s}; " + core('"$D"'),
            f"D=/tmp/ok; if true; then D={s}; fi; " + core('"$D"'), f"D={s}; if false; then D=/tmp/ok; fi; " + core('"$D"'), f"D=/tmp/ok; for i in 1 2; do " + core('"$D"') + f"; D={s}; done",
            f"D=/tmp/ok; f() {{ " + core('"$D"') + f"; }}; D={s}; f", f"D={shlex.quote(d)}; D+={shlex.quote('/' + b)}; " + core('"$D"'), f"D='/tmp/ok {s}'; " + core("$D"), f"T='/tmp/ok {s}'; for t in $T; do " + core('"$t"') + "; done",
            f"C={q}; $C", f"C={q}; eval \"$C\"", f"C={q}; bash -c \"$C\"", f"echo {s} | while read D; do " + core('"$D"') + "; done", f"case x in x) D={s};; esac; " + core('"$D"'), f"D={s}; case x in y) D=/tmp/ok;; esac; " + core('"$D"'),
            f"D={s}/; " + core('"${D%/}"'), f"D=x{s}; " + core('"${D#x}"'), f"D={s}; " + core('"${D:-/tmp/ok}"'), core('${U:-' + s + '}'), f"D={s}.bak; " + core('"${D%.bak}"'), f"D={s}; " + core('"${D/zz/}"'), f"D={s}; " + core('"${D:+' + s + '}"'),
            f"nohup D={s}; D+=/x; " + core('"$D"'),
            f"F={shlex.quote(rnd.choice(FLAGS))}; rm $F {s}", f"F={shlex.quote(rnd.choice(FLAGS))}; rm {s} \"$F\"", f"for f in {shlex.quote(rnd.choice(FLAGS))}; do rm $f {s}; done", f"export F={shlex.quote(rnd.choice(FLAGS))}; bash -c 'rm $F {s}'"]


def chain(s, P):
    """cd que pode falhar + `&&` + comando que roda DEPOIS do fim da cadeia (`;` newline `||` `&`): o rm roda no cwd de antes ou no de depois conforme o cd deu certo, e `$PWD`/`$(pwd)` valem o cwd REAL. Quem decide é o bash; o oráculo só lê onde o rm falso rodou."""
    d, b = os.path.split(P)
    ds = "~" + d[len(H):] if d.startswith(H) else d
    dst = rnd.choice([f"{S}/nope", f"{S}/nope", ds, ds, "~", f"{S}/work"])  # os dois primeiros não existem: o cd falha e o shell fica onde estava
    cd = rnd.choice([f"cd {dst}", f"cd {dst}", f"pushd {dst} >/dev/null"])
    sep = rnd.choice(["; ", "\n", " || true; ", " & ", " && true; "])
    rel = shlex.quote(os.path.relpath(P, CWD))
    return [f"{cd} && true{sep}" + core(rel), f"{cd} && echo hi{sep}" + core(s), f"{cd} && (true){sep}" + core(rel), f"({cd} && true; " + core(rel) + ")", f"{cd} && true | cat; " + core(rel),
            f"{cd}; D=$PWD; " + core('"$D"'), f"{cd} && true{sep}" + core('"$PWD/' + b + '"'), f"{cd}; " + core('"$PWD"'), f"({cd}; " + core('"$(pwd)"') + ")", f"{cd}; for d in $PWD; do " + core('"$d"') + "; done"]


def shape(s, P):
    d, b = os.path.split(P)
    ds = "~" + d[len(H):] if d.startswith(H) else d
    return rnd.choice([core(s), core(s), f"D={s}; " + core('"$D"'), f"export D={s}; " + core("$D"), f"cd {ds} && " + core(shlex.quote(b)), f"(cd {ds}; " + core(shlex.quote(b)) + ")", f"cd {hop(P)} && " + core(shlex.quote("../" + b)), f"echo {s} | xargs " + core(""),
                       f"for f in {s}; do " + core('"$f"') + "; done", f"find {s} " + rnd.choice(["-mindepth 1 -delete", "-name '*.o' -delete", "-exec rm -rf {} +", "-type f -delete", "-name x -exec rm {} \\;"]),
                       f"R=rm; $R {rnd.choice(FLAGS)} {s}", "f() { " + core(s) + "; }; f", "python3 -c " + shlex.quote("import subprocess; subprocess.run(['rm','-rf','%s'])" % P)] + late(s, P) + chain(s, P))


def wrap(c):
    for _ in range(rnd.choice([0, 1, 1, 2])):
        w = rnd.choice(["bash", "eval", "env", "paren", "and", "redir", "heredoc", "pipe", "wrapper", "procsub"]); heredocs[0] += 1; e = f"EOF{heredocs[0]}"
        c = {"bash": f"bash -c {shlex.quote(c)}", "eval": f"eval {shlex.quote(c)}", "env": f"env {c}", "paren": f"( {c} )", "and": f"true && {c}", "redir": f"{c} 2>/dev/null", "heredoc": f"bash <<'{e}'\n{c}\n{e}",
             "pipe": f"echo {shlex.quote(c)} | bash", "wrapper": f"{rnd.choice(WRAPS)} {c}", "procsub": f"bash <(echo {shlex.quote(c)})"}[w]
    return c


valid = byp = fp = nt = 0
miss = []
for i in range(N):
    P, s = spell(rnd.choice(BAD if rnd.random() < 0.6 else OK))
    FZ[0] = rnd.choice([CWD, CWD, f"{S}/work/a"])
    cmd = wrap(shape(s, P))
    t, rc = touched(cmd)
    if rc in (2, 126, 127):
        continue
    valid += 1; nt += t
    g = m.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": FZ[0]}) is not None
    byp += t and not g; fp += g and not t
    if t and not g:
        miss.append(cmd.replace(H, "$H").replace(S, "$S"))
check(f"fuzzer vs bash real: {valid} comandos válidos, {nt} entregaram alvo proibido a um rm falso, bypass={byp} (falso positivo={fp}, só informativo)", byp == 0 and nt > valid // 4, "\n     ".join(miss[:6]))

# --- fuzzer de cd/pushd/popd (5º FAIL do gate): gramática de comandos com cd em QUALQUER posição contra o bash REAL. O oráculo põe o `pwd` no lugar do rm: o rm falso grava a pasta onde o shell
# o rodou, e rm recursivo numa pasta proibida (`verdict` da pasta) tem de ser bloqueado. Todo operando da gramática é "a pasta onde estou" (`*`, `.`, `./*`, `$PWD`, `$(pwd)`), então só o cwd decide ---
CDDIRS = [f"{H}/proj", f"{H}/proj", f"{H}/proj/build", f"{H}/proj/src", f"{H}/proj2", f"{H}/gt-remote", f"{H}/gt-remote/git", H, "~", "~/proj", f"{S}/work", f"{S}/work/a", f"{S}/work/b", f"{S}/many", f"{S}/lnkgit", f"{S}/lnkok", f"{S}/nope",
          "..", "..", "../..", ".", "build", "src", "a", "b", "-", '"$U"', "$OLDPWD", f"{H}/proj/.git"]
CDCWD = [f"{S}/work/a", f"{S}/work/a", f"{S}/work", f"{S}/work/b", f"{H}/proj/build", f"{H}/proj/src", f"{H}/proj2", CWD, H]


def cdcmd():
    t = rnd.choice(CDDIRS)
    return rnd.choice([f"cd {t}", f"cd {t}", f"cd -P {t}", f"pushd {t} >/dev/null", f"pushd {t} >/dev/null 2>&1", "popd >/dev/null 2>&1", "cd", "pushd >/dev/null 2>&1", f"cd {t} 2>/dev/null", f"X=1 cd {t}", f"cd >/dev/null {t}", f"X=1 pushd {t} >/dev/null"])


def rmcmd():
    return "rm " + rnd.choice(["-rf", "-fr", "-r -f", "-Rf", "--recursive --force", "-rfv"]) + " " + rnd.choice(["*", "*", ".", "./*", "$PWD", '"$PWD"', "${PWD}", "$(pwd)", '"$(pwd)"', "`pwd`"])


def atom():
    r = rnd.random()
    return cdcmd() if r < .4 else rmcmd() if r < .75 else rnd.choice(["true", "false", "echo x", "[ -d . ]", "[ -d build ]", ":", "test -e src", "cd ."])


def stmt(d, neg=True):  # `a | ! b` é erro de sintaxe: o `!` só abre um pipeline
    r = rnd.random()
    if d < 2 and r < .45:
        inner = prog(d + 1)
        return rnd.choice([f"( {inner} )", f"{{ {inner}; }}", f"bash -c {shlex.quote(inner)}", f"eval {shlex.quote(inner)}", f"for i in 1 2; do {inner}; done", f"while true; do {inner}; break; done", f"if true; then {inner}; fi",
                           f"echo $({inner})", f"{{ f() {{ {inner}; }}; f; }}", f"{{ f() {{ {inner}; }}; f; f; }}", f"{{ {inner}; }} | cat", f"if {atom()}; then {inner}; else {atom()}; fi"])
    return ("! " if r > .93 and neg else "") + atom()


def prog(d=0):
    out = stmt(d)
    for _ in range(rnd.choice([0, 1, 1, 2, 2, 3, 4])):
        sep = rnd.choice([" ; ", " && ", " && ", " || ", " || ", " | ", " |& ", "\n", " & "])
        out += sep + stmt(d, sep.strip() not in ("|", "|&"))
    return out


def pwdhit(cmd):
    """(algum rm RECURSIVO rodou numa pasta proibida, código de saída) no bash REAL."""
    open(LOG, "wb").close(); rc = 0
    try:
        rc = subprocess.run(["bash", "-c", cmd + "\nwait"], cwd=FZ[0], env={"PATH": f"{H}/bin:/usr/bin:/bin", "HOME": H}, capture_output=True, timeout=10).returncode
    except subprocess.TimeoutExpired:
        pass
    hit = False
    for rec in open(LOG, "rb").read().split(b"\x01\n"):
        if not rec:
            continue
        verb, cwd, *args = [x.decode("utf-8", "surrogateescape") for x in rec.split(b"\0")][:-1]
        if verb == "rm" and any(a[:1] == "-" and a[:2] != "--" and set(a[1:]) & set("rR") or a.startswith("--rec") for a in args):
            hit = hit or verdict(os.path.normpath(cwd), True, False) or verdict(os.path.realpath(cwd), True, False)
    return hit, rc


cdvalid = cdbyp = cdfp = cdnt = 0
cdmiss = []
for i in range(N):
    FZ[0] = rnd.choice(CDCWD)
    cmd = prog()
    t, rc = pwdhit(cmd)
    if rc in (2, 126, 127):  # sintaxe que esta versão do bash recusa (`|&` no 3.2): nada rodou
        continue
    cdvalid += 1; cdnt += t
    g = m.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": FZ[0]}) is not None
    cdbyp += t and not g; cdfp += g and not t
    if t and not g:
        cdmiss.append(f"[cwd {FZ[0].replace(H, '$H').replace(S, '$S')}] " + cmd.replace(H, "$H").replace(S, "$S"))
check(f"fuzzer de cd/pushd vs bash real: {cdvalid} comandos válidos, {cdnt} rodaram um rm recursivo numa pasta proibida, bypass={cdbyp} (falso positivo={cdfp}, só informativo)", cdbyp == 0 and (cdnt > cdvalid // 8 or N < 20), "\n     ".join(cdmiss[:6]))

# --- mutantes: cada guarda apagada tem de reprovar a tabela ---
MUT = [('~/shared/data real', 'rel[:2] == ["shared", "data"]', 'False'), ('~/shared recursivo, mesmo com filtro de nome', 'rel == ["shared"]', 'False'), ('candidates: normpath antes do link', 'p = b if os.path.isabs(b) else os.path.join(cwd, b)', 'p = os.path.normpath(b if os.path.isabs(b) else os.path.join(cwd, b))'),
       ('cd: só a forma lógica', 'else (os.path.normpath(p), os.path.realpath(p))', 'else (os.path.normpath(p),)'), ('cd: só a forma real', 'else (os.path.normpath(p), os.path.realpath(p))', 'else (os.path.realpath(p),)'),
       ('cd_target sem dirs', 'new = dirs(args[0], cwds, env) if args else [home()]', 'new = [p for p, _ in candidates(args[0], cwds, env)] if args else [home()]'), ('env -C sem dirs', 'cwds = cap(dirs(d, cwds, env))', 'cwds = cap([p for p, _ in candidates(d, cwds, env)])'),
       ('mass: barra final do padrão', 'pat.rstrip("/").rsplit("/", 1)[-1]', 'pat.rsplit("/", 1)[-1]'),
       ('componente negado', 'if c in DENY_COMP and not (', 'if False and not ('), ('trava velha .git/*.lock', 'low[-1].endswith(".lock")', 'False'), ('raiz', 'if len(parts) <= 1:', 'if False:'), ('HOME e ancestrais', 'if any(low == hp[:len(low)] for hp in hps):', 'if False:'),
       ('pasta direta do HOME', 'if len(rel) == 1 and rec and not selective and not (', 'if False and not ('), ('CloudStorage', 'rel[:2] == ["library", "cloudstorage"]', 'False'), ('shared/data', 'rel[2:4] == ["shared", "data"]', 'False'),
       ('claude-<uid> compartilhado', 'rest[0].startswith("claude-") and len(rest) < 3', 'False'), ('tmux', 'rest[0].startswith("tmux-")', 'False'), ('pasta de sistema', 'if low[0] in SYSTEM:', 'if False:'), ('raiz de repo', 'return "rm.repo-root" if holds(f) else None', 'return None'),
       ('repo a 2 níveis', 'any(real(pb) and marked(pb, git) for pb in (os.path.join(pa, b) for b in kids(pa)))', 'False'), ('repo bare', 'os.path.isfile(j("HEAD"))', 'False'), ('estouro do orçamento', 'except OverflowError:\n        return True', 'except OverflowError:\n        return False'),
       ('curinga que esvazia', 'if pat and MASS.fullmatch(', 'if False and MASS.fullmatch('), ('find: filtro de nome', 'return check(roots, True, sel, cwds, env) if rmish else None', 'return check(roots, True, ("",), cwds, env) if rmish else None'),
       ('find: filtro trivial', 'return bool(re.search(r"[A-Za-z0-9]", s))', 'return True'), ('find: -o anula o filtro', '{"!", "-not", "-o", "-or"} & set(expr)', 'set()'), ('find: regex', 'if test in ("-regex", "-iregex") else s', 'if False else s'),
       ('find: só dado ignora .git', 'if git or n != ".git"', 'if True'), ('find: dado sob raiz seletiva', 'return "rm.repo-root" if holds(f, False) or', 'return "rm.repo-root" if False or'), ('alvo desconhecido', 'return "rm.target-unknown", raw.replace(UNK, "?")', 'continue'),
       ('link simbólico', 'for f in dict.fromkeys((os.path.normpath(p), os.path.realpath(p))):', 'for f in (os.path.normpath(p),):'), ('flags agrupadas', 'rec = rec or bool(set(a[1:]) & {"r", "R"})', 'rec = rec or a[1:] == "r"'),
       ('opção longa por prefixo', 'rec = rec or (bool(n) and "recursive".startswith(n))', 'rec = rec or n == "recursive"'), ('timeout DURATION', 'ws = ws[npos:]', 'ws = ws'), ('sudo -u valor', '"sudo": ("-u -g', '"sudo": ("-g'), ('bash -c', 'r"-[a-zA-Z]*[ceEpr]|', 'r"-[a-zA-Z]*[eEpr]|'),
       ('heredoc para shell', 'if any(w in SHELLS for w in recv) else None', 'if False else None'), ('argv de subprocess', 'for m in ARGV.finditer(code):', 'for m in []:'), ('inline: API de remoção liga os caminhos', 'deletes = bool(DELAPI.search(code)) or', 'deletes = bool(False) or'),
       ('inline: literal direto à API', 'strict = DELCALL.findall(code) +', 'strict = [] +'), ('inline: recursão do literal pelado vem da API', 'rec = bool(DELREC.search(code)) or', 'rec = True or'), ('inline: literal direto é sempre recursivo', 'return check(strict, True, False, cwds, env)', 'return check(strict, rec, False, cwds, env)'), ('heredoc: variável de fora é desconhecida', 'denv = {k: [UNK] for k in env}', 'denv = env'), ('FileUtils amplo', 'FileUtils\\.(?:rm|remove)\\w*', 'FileUtils\\.rm_rf?'), ('inline: literal pelado vale como alvo', 'or check(bare, rec, False, cwds, env, True)', 'or None'),
       ('inline: rm dentro de literal liga os caminhos', 'or any(RM_TEXT.search(x) for x in lits)', 'or False'), ('inline: sem API, nenhum caminho estrito', '[x for x in lits if deletes and x and not', '[x for x in lits if True and x and not'),
       ('inline: sem API, nenhum literal pelado', 'bare = [x for x in lits if deletes and x and len(x)', 'bare = [x for x in lits if True and x and len(x)'), ('curinga fundo: o texto do padrão é julgado', 'out += [(p, p), (None, None)]', 'out += [(None, None)]'),
       ('$( )', 'for body in substitutions(w):', 'for body in []:'), ('teto do glob', '([(None, None)] if len(hits) > GLOB_MAX else [])', '[]'),
       ('xargs', 'if verb == "xargs":', 'if False:'), ('find', 'if verb == "find":', 'if False:'), ('env -S', '(b == "env" and key in ("-S", "--split-string"))', 'False'),
       ('npx -c', '(b == "npx" and key in ("-c", "--call"))', 'False'), ('flock -c', 'if b == "flock" and ws[:1] in', 'if False and ws[:1] in'), ('verbo desconhecido + flag recursiva', 'return check(ops, rec, () if rec else ("",), cwds, env)', 'pass'), ('verbo desconhecido sem flag: regras absolutas', 'return check(ops, rec, () if rec else ("",), cwds, env)', 'return check(ops, rec, False, cwds, env)'),
       ('export', 'if verb in ("export", "declare", "typeset", "local", "readonly"):', 'if False:'), ('cd nunca descarta o mais novo', 'cap = lambda m: m if len(m) <= 8 else m[:7] + [None]', 'cap = lambda m: m[:4]'), ('curinga fundo', 'for c in p.split("/")) > 2:', 'for c in p.split("/")) > 200:'),
       ('prazo', 'if time.monotonic() > DEADLINE:', 'if False:'), ('pasta compartilhada: arquivo solto', 'dir_ = os.path.isdir(f) or (rec and not os.path.lexists(f))', 'dir_ = True'),
       ('find: nomes internos do git', '(holds(f) and any(GITNAMES.search(p) for p in selective))', 'False'), ('<( ) no lexer', 'c == "`" or (c in "<>" and nx == "(")', 'c == "`"'), ('saída de <( ) é programa', '(w[i] in "$<>" and w[i + 1:i + 2] == "(")', '(w[i] == "$" and w[i + 1:i + 2] == "(")'),
       ('echo|bash junta args', '[" ".join(ws[1:])] if ws and', '[] if ws and'), ('tamanho', 'if len(cmd) > MAX_CMD:', 'if False:'), ('profundidade', 'if depth > 6:', 'if depth > 600:'),
       ('tilde', 'return home() + s[1:] if s == "~" or s.startswith("~/")', 'return s if s == "~" or s.startswith("~/")'), ('glob', 'hits = sorted(itertools.islice(glob.iglob(p), GLOB_MAX + 1))', 'hits = []'), ('chave {a,b}', 'bs = [t] if UNK in t else [tilde(x) for x in braces(t)]', 'bs = [t]'),
       ('teto da chave', 'len(alts) <= 16', 'len(alts) <= 1600'), ('caixa', 'low = [unicodedata.normalize("NFC", x).casefold() for x in parts]', 'low = list(parts)'), ('HOME vence scratch', 'rel, relp = (low[k:], parts[k:]) if k is not None else (None, None)', 'rel, relp = None, None'),
       ('node_modules', 'any(c in ALLOW_COMP for c in parts)', 'False'), ('.cache', 'any(relp[:len(a)] == list(a) for a in ALLOW_HOME)', 'False'), ('pyc', '(f.endswith(".pyc") and not os.path.isdir(f))', 'False'), ('rimraf', 'or verb == "rimraf"', 'or False'),
       ('popd', 'if os.path.basename(ws[0]) == "popd" or', 'if False or'), ('cd -', 'or args[:1] == ["-"] or', 'or False or'), ('lançador opaco', 'if verb in OPAQUE:', 'if False:'), ('source e .', 'verb in ("eval", "source", ".")', 'verb == "eval"'), ('shells ampliados', '"ash", "csh", "tcsh", "fish", "mksh"', '"ash", "mksh"'), ('interpretadores: pypy', 'pypy[\\d.]*|', ''), ('interpretadores: R, julia, osascript', '|tclsh|wish|Rscript|julia|osascript|jshell|groovy', ''), ('rm( como API de remoção', '(?:unlink|rmdir|rm)(?=', '(?:unlink|rmdir)(?='), ('-c genérico para corredor desconhecido', 'if a in ("-c", "--command") and x + 1 < len(args)', 'if False and x + 1 < len(args)'),
       ('for depois do peel', 'if len(ws) > 3 and ws[0] in ("for", "select") and ws[2] == "in":', 'if False:'), ('select como for', 'ws[0] in ("for", "select") and ws[2] == "in"', 'ws[0] == "for" and ws[2] == "in"'),
       ('verbo por variável: valor que sei', 'known = [x for x in v if UNK not in x and x != ws[0]]', 'known = []'), ('verbo por variável: outro valor é "não sei"', 'known = [x for x in v if UNK not in x and x != ws[0]]', 'known = [x for x in v if len(v) == 1 and UNK not in x and x != ws[0]]'),
       ('rig: ancestrais só recursivos no ~/gt/<rig>', 'or (rec and (len(rel) == 2 or (len(rel) == 3 and rel[2] == "shared")))', 'or False'), ('rig: ~/gt/<rig>', '(len(rel) == 2 or (len(rel) == 3 and rel[2] == "shared"))', '(len(rel) == 3 and rel[2] == "shared")'),
       ('rig: ~/gt/<rig>/shared', '(len(rel) == 2 or (len(rel) == 3 and rel[2] == "shared"))', '(len(rel) == 2)'), ('rig: ancestral exige recursivo', '(rec and (len(rel) == 2 or', '((len(rel) == 2 or'),
       ('prefixo NOME=v vale para o comando de dentro', 'for a in pre: assign(a, cenv, cwds, False)', 'for a in pre: pass'), ('env/command sem comando não atribui', 'for a in pre if not wrapped else ():', 'for a in pre:'),
       ('embrulho marca a lista', 'if pre is not None and b != "time":', 'if False:'), ('time é palavra reservada', 'if pre is not None and b != "time":', 'if pre is not None:'),
       ('depois de && a atribuição é talvez', 'or prev in ("&&", "||")', ''), ('dentro de case a atribuição é talvez', 'weak = iso or bool(blk["cases"]) or', 'weak = iso or'),
       ('dentro de { } a atribuição é talvez', ' or bool(blk["grp"] and blk["grp"][-1] is None)', ''), ('pipe e & rodam em subshell', 'iso = t in ("|", "|&", "&") or prev in ("|", "|&")', 'iso = False'),
       ('o que o pipe muda entra como talvez', 'if before is not None: merge(env, before)', 'if before is not None: pass'), ('else volta ao ambiente do if', 'top[1].append(dict(env)); env.clear(); env.update(top[0]); top[2] = k == "elif"', 'top[1].append(dict(env)); top[2] = k == "elif"'),
       ('fi e done juntam os ramos', 'fr.pop(); merge(env, top[0], *top[1])', 'fr.pop()'), ('then abre quadro', 'elif k in ("while", "until") or (k == "then" and not (top and top[2])):', 'elif k in ("while", "until"):'),
       ('while alarga o ambiente', 'widen(env); ST["late"] = True; ST["lp"] += 1\n        elif k == "then":', 'ST["late"] = True; ST["lp"] += 1\n        elif k == "then":'), ('for alarga o ambiente', 'fr.append([dict(env), [], False, True]); widen(env); ST["late"] = True; ST["lp"] += 1', 'fr.append([dict(env), [], False, True]); ST["late"] = True; ST["lp"] += 1'),
       ('subshell devolve o ambiente', 'env.clear(); env.update(saved.pop())', 'saved.pop()'), ('chamada de função', 'if ws[0] in ST["funcs"]:', 'if False:'),
       ('cabeçalho f() {', 'if t == "(" and len(hd) == 1 and', 'if False and len(hd) == 1 and'), ('function f {', 'if k == "function":  #', 'if False:  #'),
       ('corpo de função alarga o ambiente', 'if b["fnew"]: ST["fn"] += 1; widen(env)', 'if b["fnew"]: ST["fn"] += 1'), ('2º passo', 'if not hit and ST["late"]:', 'if False:'),
       ('2º passo: valores já vistos', 'if ST["again"] else ():', 'if False else ():'), ('nome calculado vira "não sei"', 'if verb == "printf" else args)): wild(env)', 'if verb == "printf" else args)): pass'),
       ('escritor: valor que sei', 'setvar(env, n, vals if vals is not None and n == tgt else [UNK], strong)', 'setvar(env, n, [UNK], strong)'), ('printf -v', 'if verb == "printf" and len(args) == 4 and args[0] == "-v" and args[2] == "%s":', 'if False:'),
       ('read de here-string', 'src, tgt = tilde(here[0]) if len(here) == 1 else said(feed), names[-1]', 'src, tgt = None, names[-1]'), ('read do echo do pipe', 'src, tgt = tilde(here[0]) if len(here) == 1 else said(feed), names[-1]', 'src, tgt = (tilde(here[0]) if len(here) == 1 else None), names[-1]'),
       ('eval devolve o que atribuiu', 'if cenv.get(k) != v: setvar(env, k, v, strong)', 'if cenv.get(k) != v: pass'), ('source', 'if verb in ("source", "."):  # o arquivo que ele roda pode atribuir qualquer coisa\n        wild(env)', 'if verb in ("source", "."):  # o arquivo que ele roda pode atribuir qualquer coisa\n        pass'),
       ('+=', '("${%s}" % m.group(1) if m.group(2) else "")', '""'), ('pedaços do IFS', 'return ts + [q for t in ts if UNK not in t for q in sep.split(t) if q and q != t]', 'return ts'),
       ('sequência de chave', 'm = next((q for q in SEQ.finditer(s) if', 'm = next((q for q in [] if'), ('o texto com chave sem expandir também vale', 'if UNK not in t and t not in bs:', 'if False:'),
       ('param: padrão e alternativo', 'if k in "-=+":', 'if False:'), ('param: alternativo +', 'else [(w if c and v == "" else v) if k != "+" else (w if v or not c else "")]', 'else [v]'),
       ('param: N que não sei tem as duas', '([v, w] if k != "+" else [w, ""]) if UNK in v', '([v] if k != "+" else [""]) if UNK in v'), ('param: corte pelo fim', 'if k == "%": return', 'if False: return'),
       ('param: corte pelo começo', 'return [next((v[i:] for i in (r if op == "#" else reversed(r)) if re.fullmatch(g(w), v[:i])), v)]', 'return [v]'), ('param: troca', 'if k == "/": return [re.sub(', 'if False: return [re.sub('),
       ('param: o operador chega ao valor', 'for x in (param(v, m.group(3), w) if m.group(3) else [v])]', 'for x in [v]]'), ('xargs -J -S -R', 'XARGS_VAL = {"-I", "-J", "-S", "-R", ', 'XARGS_VAL = {"-I", '),
       ('sudo -s', 'shell = shell or (b in ("sudo", "doas") and key in ("-s", "-i", "--shell", "--login"))', 'shell = shell'), ('lstat que falha = existe', 'except (OSError, ValueError): return True', 'except (OSError, ValueError): return False'),
       ('pasta ilegível = guarda', 'except (OSError, ValueError): raise OverflowError(d)', 'except (OSError, ValueError): return []'), ('atribuição com aspas é comando', 'toks.append(Q(w) if q is not None and "=" in w and q <= w.index("=") else w)', 'toks.append(w)'),
       ('atribuição com aspas depois de embrulho', 'and (wrapped or not isinstance(ws[0], Q))', 'and True'), ('time e ! antes do cabeçalho de função', 'hd = [w for w in ws if w not in ("time", "!", "-p")]', 'hd = ws'),
       ('+= num nome que não sei pode estar vazio', 'if m.group(2) and UNK in "".join(env.get(m.group(1), [UNK])):', 'if False:'), ('aspas antes do = depois de embrulho ainda é atribuição', 'and (wrapped or not isinstance(ws[0], Q))', 'and not isinstance(ws[0], Q)'),
       ('${ }: chave aninhada $( ) e ${ } pulada', 'elif e == "}" and q != "\'" and (c == "`" or (c == "$" and t[j + 1:j + 2] in ("{", "("))): j = skip_subst(t, j) - 1', 'elif False: j = skip_subst(t, j) - 1'),
       ('${ }: a ponta da } sem aspas fecha', 'while j < n and not (t[j] == e and q is None):', 'while j < n and t[j] != e:'),
       ('${ }: a palavra do operador perde as aspas', 're.sub("[\\"\']", "", m.group(4))', 'm.group(4)'),
       ('${ }: a palavra do operador se expande', '(expand(re.sub("[\\"\']", "", m.group(4)), cwds, env) if m.group(3) else [""])', '([re.sub("[\\"\']", "", m.group(4))] if m.group(3) else [""])'),
       ('${ }: aspas protegem a }', 'elif e == "}" and c in "\'\\"": q = None if q == c else (q or c)', 'elif False: q = None'),
       ('${ }: só " protege a }', 'elif e == "}" and c in "\'\\"": q =', 'elif e == "}" and c in \'"\': q ='),
       ('${ }: a palavra aceita 1 nível de chave', '((?:[^{}]|\\{[^{}]*\\})*)', '((?:[^{}])*)'),
       ('heredoc dentro de $( ) é pulado', 'elif c == "\\n" and hd:', 'elif False and hd:'), ('$( ): a barra protege a aspa', '        if c == "\\\\": j += 1\n        elif c == \'"\': dq = not dq', '        if False: j += 1\n        elif c == \'"\': dq = not dq'),
       ('(( )) no lexer: << é deslocamento', 'if op in ("<<", "<<-") and not ar else None', 'if op in ("<<", "<<-") else None'), ('(( )) no lexer: for ((', 'toks[-1] in KEYWORDS | {"for"}', 'toks[-1] in KEYWORDS'),
       ('(( )) no lexer: no começo do comando', '(not toks or toks[-1] in KEYWORDS', '(False or toks[-1] in KEYWORDS'), ('rede: fecho perdido com rm no texto', 'if not hit and (ST["open"] or', 'if False and (ST["open"] or'),
       ('rede: aspas e ANSI não escondem o rm', '(re.sub(r"[\'\\"\\\\]", "", cmd), ansi(cmd))', '(cmd,)'), ('rede: crase e ${ } sem fecho', 'ST["open"] |= j >= n\n        return min(j + 1, n)', 'return min(j + 1, n)'),
       ('rede: heredoc sem delimitador', 'else: ST["open"] = True  # heredoc sem a linha do delimitador', 'else: pass  # heredoc sem a linha do delimitador'), ('rede: aspa dupla sem fecho', 'ST["open"] |= i >= n; i += 1', 'i += 1'),
       ('rede: aspa simples sem fecho', 'i = j + 1; ST["open"] |= j >= n', 'i = j + 1'), ('env -C', '{"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}.get(b, ())', '{"sudo": ("-D", "--chdir")}.get(b, ())'),
       ('sudo -D', '{"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}.get(b, ())', '{"env": ("-C", "--chdir")}.get(b, ())'), ('env --chdir leva valor', '"env": ("-u -C -S --unset --chdir --split-string", 0)', '"env": ("-u -C -S --unset --split-string", 0)'),
       ('sudo --chdir leva valor', '-T -U --user --group --chdir", 0)', '-T -U --user --group", 0)'), ('env/sudo: o comando roda na pasta de -C/-D', 'for d in cd:  #', 'for d in []:  #'),
       ('chave na palavra do verbo', 'bs = braces(ws[0])  #', 'bs = [ws[0]]  #'), ('chave na palavra do verbo: o regex a vê', '|\\{[^{}]*(?:,|\\.\\.)", ws[0])', '", ws[0])'),
       ('chave nas opções do rm', '(braces(a) if a[:1] == "-" and "{" in a else [a])', '[a]'), ('chave de opção além do teto vale recursiva', 'or (verb == "rm" and any(UNK in a for a in args))', 'or False'),
       ('cd depois de then/do/{', 'while ws and ws[0] in KEYWORDS | CTL | {"time", "command", "builtin"}: ws = ws[1:]', 'while ws and ws[0] in {"time", "command", "builtin"}: ws = ws[1:]'), ('heredoc sem aspas no delimitador executa $( )', 'for sb in () if qd else substitutions(body):', 'for sb in ():'),
       ('heredoc com delimitador entre aspas não executa $( )', 'm.group(3) is None or "\\\\" in m.group(0)', 'True'), ('heredoc: delimitador entre aspas ou com barra', 'm.group(3) is None or "\\\\" in m.group(0)', 'False'),
       ('bash -c "$( )": a saída é programa', 'for body in [b for a in args for b in substitutions(a)]:', 'for body in []:'), ('saída de $( ): heredoc é programa', 'code_of(tk) + [d for d, _, _ in dcs]', 'code_of(tk)'),
       ('crase: aspas não escondem o fecho', 'elif e == "}" and c in "\'\\"": q = None if q == c else (q or c)  #', 'elif c in "\'\\"": q = None if q == c else (q or c)  #'), ('$((: o corpo é lido como (( ))', 'w.startswith("$((", i)', 'False'), ('valor de variável: o bash só parte em branco (aspas e # dele são letras)', 'for rd in (x.split(), [str(t) for t in lex(x)[0]]):', 'for rd in ([str(t) for t in lex(x)[0]],):'),
       ('valor de variável: eval e bash -c leem o valor como texto de shell', 'for rd in (x.split(), [str(t) for t in lex(x)[0]]):', 'for rd in (x.split(),):'),
       ('opção que não está escrita vale como escrita', 'ops, rec = rm_args(verb, xo + args)', 'ops, rec = rm_args(verb, args)'), ('opção que não está escrita entra antes do --', 'ops, rec = rm_args(verb, xo + args)', 'ops, rec = rm_args(verb, args + xo)'),
       ('pedaço que não sei: os operandos que sei valem como recursivos', 'r = classify(p, rec or maybe, selective, pat)', 'r = classify(p, rec, selective, pat)'), ('pedaço que não sei: só o rm', 'maybe=maybe and verb == "rm")', 'maybe=maybe)'),
       ('há pedaço que não sei', 'any(UNK in t for t in ts)', 'False'), ('opção só antes do --', 'ws = args[:args.index("--") if "--" in args else len(args)]', 'ws = args'),
       ('opção: palavra com $ ou crase', 'for a in ws if re.search(r"[$`]", a) for t in pieces(a, cwds, env)]', 'for a in [] for t in pieces(a, cwds, env)]'),
       ('opção: arquivo `-rf` do curinga', '[os.path.basename(p) for a in ws if "/" not in a and re.search(r"[*?\\[]", a) for p, _ in candidates(a, cwds, env) if p]', '[]'),
       ('opção: curinga só em palavra sem barra', 'if "/" not in a and re.search(r"[*?\\[]", a) for p, _ in candidates', 'if re.search(r"[*?\\[]", a) for p, _ in candidates'),
       ('til dentro da chave: o bash expande a chave antes do til', 'bs = [t] if UNK in t else [tilde(x) for x in braces(t)]', 'bs = [t] if UNK in t else braces(t)'),
       ('variável vira comando: o texto recebido resolve, então a regra não dispara', 'if any(RM_TEXT.search(t) and UNK in "".join(expand(t, cwds, env)) for t in', 'if any(RM_TEXT.search(t) for t in'),
       ('opção: chave que gera opção (palavra que não começa com -)', '+ [b for a in ws if "{" in a for b in braces(a)] +', '+'),
       ('variável vira comando: valor com $( ) e texto que cita remoção', 'if any(RM_TEXT.search(t) and UNK in', 'if False and any(RM_TEXT.search(t) and UNK in'), ('o texto recebido pela variável é guardado', 'ST["raw"].setdefault(m.group(1), set()).add(w[m.end():])', 'pass'),
       ('param: valor longo', 'or len(v) > 256 or w.count("*") > 2: return [UNK]', 'or w.count("*") > 2: return [UNK]'), ('param: muitos *', 'or len(v) > 256 or w.count("*") > 2: return [UNK]', 'or len(v) > 256: return [UNK]'),
       ('união: o 2º varrido julga o rm contra todos os cd', 'if hit or union != ctx or uni(ctx, ST["cds"]) == ctx: break', 'if True: break'), ('união: todo cd entra', 'ST["cds"] = uni(ST["cds"], new)', 'pass'),
       ('união: o 1º varrido julga o cwd original', 'ST["cds"], union = [], ctx', 'ST["cds"], union = [], []'), ('união: o cd relativo parte de tudo que já vi', 'cd_target(cur, uni(cwds, ST["cds"]), env)', 'cd_target(cur, cwds, env)'),
       ('união: cd relativo em laço ou função não fecha', 'return new + [None] if (ST["lp"] or ST["fn"]) and args and any(', 'return new if False and args and any('), ('união: o cd em função também', '(ST["lp"] or ST["fn"]) and args and any(', '(ST["lp"]) and args and any('),
       ('união: o cd em laço também', '(ST["lp"] or ST["fn"]) and args and any(', '(ST["fn"]) and args and any('), ('união: a sonda sobe vários níveis', 'dirs(args[0], ["/.cdp" * 8], env)', 'dirs(args[0], ["/.cdp"], env)'),
       ('união: while conta como laço', '; ST["lp"] += 1\n        elif k == "then":', '\n        elif k == "then":'), ('união: for conta como laço', 'widen(env); ST["late"] = True; ST["lp"] += 1\n    b["fnew"]', 'widen(env); ST["late"] = True\n    b["fnew"]'),
       ('união: done fecha o laço', 'ST["lp"] -= top[3]', 'pass'), ('união: o 2º passo recomeça sem laço aberto', 'ST.update(again=True, fn=0, lp=0)', 'ST.update(again=True, fn=0)'),
       ('união: redirecionamento não é argumento do cd', 'and not (j and isinstance(ws[j - 1], Op) and REDIR.fullmatch(ws[j - 1]))]', ']'), ('união: atribuição não é argumento do cd', 'if not ASSIGN.match(w) and not isinstance(w, Op)', 'if not isinstance(w, Op)'),
       ('$PWD vale cada cwd', '[c or UNK for c in cwds] if name == "PWD" and cwds else', '[cwds[0] or UNK] if name == "PWD" and cwds else'), ('$PWD de cwd que não sei vale "não sei"', '[c or UNK for c in cwds] if name == "PWD" and cwds else', '[c for c in cwds if c] if name == "PWD" and cwds else'),
       ('$PWD na atribuição vale cada cwd', '+ w[m.end():], cwds, env)]', '+ w[m.end():], cwds[:1], env)]'), ('$PWD na palavra vale cada cwd', 'ts, ifs = expand(raw, cwds, env),', 'ts, ifs = expand(raw, cwds[:1], env),'), ('$PWD no for vale cada cwd', 'for x in pieces(w, cwds, env)], strong)', 'for x in pieces(w, cwds[:1], env)], strong)'),
       ('curinga em massa: o formato, não a lista de grafias', 'MASS = re.compile(r"(?:[*?.]|\\[[^\\]]*\\])+")', 'MASS = re.compile(r"\\.?\\*|\\.\\[!\\.\\]\\*|\\.\\?\\*|\\.\\.\\?\\*|\\?\\*")'), ('curinga em massa: letra ou número torna o padrão estreito', 'MASS = re.compile(r"(?:[*?.]|\\[', 'MASS = re.compile(r"(?:[*?.\\w]|\\['),
       ('find: só as opções -H -L -P (BSD -E -X -d -s -x fora)', 'r"-(?:[EHLPXdsx]+|[EHLPXdsx]*f', 'r"-(?:[HLP]+|[HLP]*f'), ('find: opções agrupadas (`-xE`, `-HLP`)', '[EHLPXdsx]+|[EHLPXdsx]*f', '[EHLPXdsx]|[EHLPXdsx]*f'),
       ('find: -f separado leva a raiz', 'else args[i + 1:i + 2]) if m.group(1) is not None', 'else []) if m.group(1) is not None'), ('find: -f colado leva a raiz', '([m.group(1), "."] if m.group(1) else args[i + 1:i + 2]) if', 'args[i + 1:i + 2] if'), ('find: -f colado também julga o `.` padrão (-fstype, -follow)', '[m.group(1), "."] if m.group(1)', '[m.group(1)] if m.group(1)'),
       ('find: -f não leva nenhuma raiz', 'fr += ([m.group(1), "."] if m.group(1) else args[i + 1:i + 2]) if m.group(1) is not None else []; ', ''), ('find: -D leva um valor', 'i += 1 + (m.group(1) == "" or m.group(2) == "D")', 'i += 1 + (m.group(1) == "")'),
       ('find: -O<n> é opção', '(D)|O\\d*|-)"', '(D)|-)"'), ('find: `--` termina as opções', '(D)|O\\d*|-)"', '(D)|O\\d*)"'), ('find: -fprint e -fls são predicados, não opções', 'f(?!(?:print0?|printf|ls)$)(.*)', 'f(.*)'), ('find: o predicado é a palavra INTEIRA (`-fprint/../x` é raiz colada)', '(?!(?:print0?|printf|ls)$)', '(?!print|ls$)'),
       ('expansão: passou do teto de 64 candidatos vale "não sei"', 'outs = nxt if len(nxt) <= 64 else nxt[:63] + [UNK]', 'outs = nxt[:64]'),
       ('extglob + remoção no texto', 'or any("extglob" in x for x in txt))', 'or False)'), ('extglob: o nome com aspas também vale', 'txt = (re.sub(r"[\'\\"\\\\]", "", cmd), ansi(cmd))', 'txt = (cmd,)'),
       ('código inline: remoção recursiva de argv/ambiente', 'if any(DELREC.search(m.group()) for m in ARGDEL.finditer(code)):', 'if False:'), ('código inline: só a API recursiva (os.remove de argv passa)', 'if any(DELREC.search(m.group()) for m in ARGDEL.finditer(code)):', 'if any(True for m in ARGDEL.finditer(code)):'),
       ('$\'\\x\' sem dígito é texto', ' if e[1:] else "\\\\" + e', ''), ('{1..N} enorme vale "não sei"', 'if abs(y - x) // k > 15: return [UNK]', 'if len(rng) > 16: return [UNK]')]
if not DENIES:
    MUT = [x for x in MUT if x[0] not in ("lstat que falha = existe", "pasta ilegível = guarda")]  # SKIP acima: sem a negação não há linha de tabela que esses dois mutantes possam reprovar
alive = []
for name, old, new in MUT:
    if SRC.count(old) != 1:
        alive.append(f"{name}: âncora ausente/duplicada ({SRC.count(old)}x)"); continue
    open(f"{H}/mut.py", "w").write(SRC.replace(old, new))
    try:
        mut = load(f"{H}/mut.py")
        if not set(run_table(mut) + ceilings(mut) + optglob(mut)) - set(bad):  # morto = produz linha de falha NOVA (com a tabela-base já falhando, qualquer mutante "reprovaria")
            alive.append(name + ": SOBREVIVEU")
    except Exception:  # noqa: BLE001 — mutante que quebra o import também foi pego
        pass
check(f"mutantes: {len(MUT)} guardas apagadas, todas reprovam a tabela", not alive, "; ".join(alive))
os.chmod(f"{H}/work2/locked", 0o755); os.chmod(f"{H}/work2/xonly", 0o755); os.chmod(f"{H}/work2/rdonly", 0o755)
shutil.rmtree(H, ignore_errors=True); shutil.rmtree(S, ignore_errors=True)
print(f"{sum(results)}/{len(results)} blocos ok")
sys.exit(0 if all(results) else 1)
PYEOF
