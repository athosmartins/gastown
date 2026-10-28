#!/usr/bin/env bash
# rm-target-guard.selftest.sh (ga-id0im4e) — hermético: HOME e scratch de teste em tmp, sem rede, nenhum rm de verdade (rm/unlink/rmdir/shred/find FALSOS gravam o que o shell entregou). Quatro blocos:
# tabela (B bloqueia, P passa; `:s|:b|:p|:h` troca o cwd), ponta a ponta (exit code, mensagem, falha do guarda), fuzzer diferencial contra o bash REAL (todo comando que entregou um alvo proibido
# a um rm falso tem de bloquear) e mutantes (cada guarda apagada tem de reprovar a tabela). Uso: rm-target-guard.selftest.sh [N-do-fuzzer, padrão 200]. RMTG_UNDER_TEST=<arquivo> roda a
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
          "gt-remote/git/gascity/repo.git/refs", "gt-remote/git/gascity/wt/s1/src", ".cache/pip", "Library/CloudStorage/d", "gt/rig/shared/data", "gt/rig/crew/bob", "gt/rig/.gc-worktrees/w", "bin",
          "gt-remote/big/zrepo/.git"):
    os.makedirs(f"{H}/{d}")
for f in ("notes.txt", "proj/src/a.py", "proj/src/m.pyc", "proj/build/x.o", "proj/.git/HEAD", "proj/.git/index.lock", "proj/.git/config", "proj2/.git/HEAD", "gt-remote/keys/gt_mirror", "gt-remote/git/gascity/repo.git/HEAD",
          "gt-remote/git/gascity/wt/s1/.git", "gt-remote/git/gascity/wt/s1/src/a", ".dolt-data/ga/.dolt/noms/manifest", ".beads/b", ".cache/pip/w", "gt/rig/crew/bob/x.py", "proj/__pycache__/m.pyc"):
    open(f"{H}/{f}", "w").write("x\n")
for i in range(100):  # mais de 80 entradas e o repo é a ÚLTIMA: o teto antigo de 80 não o via
    os.makedirs(f"{H}/gt-remote/big/a{i:03d}")
for d in ("work/a", "work/b", "work/.git", "srepo/.git", "srepo/src", "many"):
    os.makedirs(f"{S}/{d}")
for i in range(5):
    open(f"{S}/many/f{i}", "w").write("x")
os.symlink(f"{H}/proj/.git", f"{S}/lnkgit"); os.symlink(f"{S}/work", f"{S}/lnkok")
os.environ["HOME"] = H
CWD = f"{H}/proj"
CWDS = {"s": f"{S}/work", "b": f"{H}/proj/build", "p": f"{S}/work/a", "h": H, "z": "/zzh/a/b"}  # z = HOME sintético fundo e vazio (/zzh/a/b): sem repo por perto para esconder as regras de HOME


def load(path):
    spec = importlib.util.spec_from_file_location("rmtg_" + str(abs(hash(path))), path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def nest(k):
    c = "rm -rf @S/work"
    for _ in range(k):
        c = "bash -c " + shlex.quote(c)
    return c


# linhas "V cmd ‖ V cmd": V = B bloqueia, P passa; V:s|b|p|h|z = cwd (s=@S/work, b=proj/build, p=@S/work/a, h=@H, z=/zzh/a/b com HOME=/zzh/a/b); sem tag o cwd é @H/proj (raiz de repo)
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
P cd @S/work && rm -rf a ‖ P cd @S/work && rm -rf * ‖ B cd @S/work; rm -rf * ‖ B cd @S/work || true; rm -rf * ‖ B cd @S/work & rm -rf * ‖ B popd; rm -rf * ‖ B cd $UNSET && rm -rf * ‖ B cd "$X" && rm -rf build ‖ P cd "$X" && rm -f build ‖ B (cd @S/work; rm -rf *) ‖ P:s rm -rf * ‖ B:h rm -rf proj2
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
"""
X = [("B", "bash <<'EOF'\nrm -rf ~/gt-remote\nEOF"), ("B", "cat <<'EOF' | sh\nrm -rf ~/gt-remote\nEOF"), ("B", "python3 - <<'EOF'\nimport shutil\nshutil.rmtree('@H/gt-remote')\nEOF"), ("B", "echo \"import shutil; shutil.rmtree('@H/gt-remote')\" | python3 -"),
     ("P", "git commit -m \"$(cat <<'EOF'\nfix: stop using rm -rf ~/gt-remote\nEOF\n)\""), ("P", "cat <<'EOF'\nrm -rf ~\nEOF"), ("P", ""), ("P", "   "), ("B", "# c\nrm -rf ~/gt-remote"), ("B", "x=1\nrm -rf ~/gt-remote"),
     ("B", "X=~/gt-remote; bash <<'EOF'\nrm -rf \"$X\"\nEOF\nX=/tmp/safe"), ("B", "cd ~ && python3 - <<'EOF'\nimport shutil\nshutil.rmtree('gt-remote')\nEOF"), ("B", "cd ~ && bash <<'EOF'\nrm -rf gt-remote\nEOF"), ("P", "python3 - <<'EOF'\np = 'tests/foo.py'  # remove the old text, delete nothing\ns = open(p).read().replace('old', 'new')\nEOF"), ("B", nest(8)), ("P", nest(3)), ("B", "echo " + "x" * 300000), ("P", "echo " + "x" * 60000), ("B", "FOO=1 BAR=2 rm -rf ~/gt-remote")]
TABLE = []
for line in DSL.strip().split("\n"):
    for part in line.split(" ‖ "):
        v, cmd = part.split(" ", 1)
        TABLE.append((v[0], cmd, CWDS.get(v[2:], CWD)))
TABLE += [(w, c, CWD) for w, c in X]


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


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("ok   " if ok else "FAIL ") + name + (" — " + detail if (detail and not ok) else ""))


m = load(GUARD)
bad = run_table(m)
check(f"tabela: {len(TABLE)} casos", not bad, "\n     ".join(bad[:8]))


def e2e(raw=None, tool="Bash", cmd="ls", guard=GUARD):
    p = subprocess.run(["python3", "-I", guard], input=raw if raw is not None else json.dumps({"tool_name": tool, "tool_input": {"command": cmd}, "cwd": CWD}), text=True, capture_output=True, timeout=30)
    return p.returncode, p.stderr


rc, err = e2e(cmd="rm -fr ~/gt-remote")
check("ponta a ponta: bloqueio sai 2 com a mensagem (alvo, regra, não é cancelamento, saída segura)", rc == 2 and all(s in err for s in ("[HOOK BLOCK: rm-target-guard]", "NÃO É CANCELAMENTO", "rm.home-child", "gt-remote", "safe-clean", "find <pasta>")), err[:200])
check("ponta a ponta: liberado sai 0 sem ruído; scratch também", e2e() == (0, "") and e2e(cmd=f"rm -rf {S}/work") == (0, ""))
check("ponta a ponta: JSON ilegível que cita command bloqueia; lixo sem command libera; stdin vazio libera; outra ferramenta libera",
      e2e(raw='{"command": ')[0] == 2 and e2e(raw="lixo")[0] == 0 and e2e(raw="")[0] == 0 and e2e(tool="Write", cmd="rm -rf ~")[0] == 0)
SRC = open(GUARD).read()
crash = f"{H}/crash.py"
open(crash, "w").write(SRC.replace("def decide(inp: dict):", "def decide(inp: dict):\n    raise RuntimeError('boom')", 1))
check("ponta a ponta: bytes inválidos no stdin (locale UTF-8 estrita: sem o decode com replace o guarda sairia 1 e NÃO bloquearia) e surrogate solto no comando continuam bloqueando", e2e(raw='{"tool_name":"Bash","tool_input":{"command":"rm -rf /\\ud800"},"cwd":"/tmp"}')[0] == 2 and subprocess.run(["python3", "-I", GUARD], input=b'{"tool_name":"Bash","tool_input":{"command":"rm -rf /\xff"},"cwd":"/tmp"}', capture_output=True, env={**os.environ, "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"}).returncode == 2)
rc, err = e2e(cmd="ls", guard=crash)
check("ponta a ponta: o guarda falhando num pedido Bash = bloqueado (nunca liberado)", rc == 2 and "o guarda falhou" in err, err[:120])
check("tetos: curinga além de GLOB_MAX = alvo desconhecido, pasta além de LS_BUDGET = guarda repo, prazo LIMIT estourado = bloqueado (com os tetos de verdade os mesmos comandos passam: linhas da tabela)", not ceilings(m), str(ceilings(m)))

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
    if sel:
        return holds(p, DATA)
    return (len(p[len(H) + 1:].split("/")) == 1 and rec and not (os.path.exists(p) and not os.path.isdir(p))) or holds(p, REPOS)


def touched(cmd):
    open(LOG, "wb").close(); rc = 0
    try:
        rc = subprocess.run(["bash", "-c", cmd], cwd=CWD, env={"PATH": f"{H}/bin:/usr/bin:/bin", "HOME": H}, capture_output=True, timeout=10).returncode
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
            if not a or (re.search(r"[*?\[]", a) and not os.path.lexists(os.path.join(cwd, a))):  # `rm ""` (wrapper que engole `D=x;`) e texto com curinga que não existe: o rm não apaga nada
                continue
            full = os.path.join(cwd, a)
            hit = hit or verdict(os.path.normpath(full), rec_, sel) or verdict(os.path.realpath(full), rec_, sel)
    return hit, rc


rnd = random.Random(int(os.environ.get("RMTG_SEED", "7")))
BAD = ["proj/.git/config", "proj/.git/HEAD", "proj", "proj2", ".dolt-data/ga", ".dolt-data/ga/.dolt/noms/manifest", ".beads/b", "gt-remote", "gt-remote/keys/gt_mirror", "gt-remote/git", "gt-remote/git/gascity",
       "gt-remote/git/gascity/wt/s1", "gt-remote/big", "gt/rig/crew/bob/x.py", "gt/rig/.gc-worktrees/w", "@S/lnkgit"]
OK = ["proj/src/a.py", "proj/build", "proj/build/x.o", "proj/node_modules", "notes.txt", ".cache/pip/w", "proj/.git/index.lock", "gt-remote/git/gascity/wt/s1/src", "@S/work", "@S/work/a", "@S/srepo", "@S/many/f1", "proj/src/m.pyc"]
FLAGS = ["-rf", "-fr", "-r -f", "-f -r", "-Rf", "-rfv", "--recursive --force", "--recur --forc", "-r", "-f", "", "-rf --", "--recursive", "-vr"]
WRAPS = ["env A=1", "command", "nohup", "nice -n 5", "time"] + [w for w in ("timeout 5", "stdbuf -oL") if shutil.which(w.split()[0])]
heredocs = [0]


def spell(rel):
    P = S + rel[2:] if rel.startswith("@S") else f"{H}/{rel}"
    d, b = os.path.split(P)
    opts = [P, "'" + P + "'", d + "//" + b, d + "/./" + b, P[:5] + "''" + P[5:], d + "/" + b[:3] + "*", d + "/{" + b + ",zz}", os.path.relpath(P, CWD), P + "/"]
    if P.startswith(H + "/"):
        r = P[len(H) + 1:]
        opts += ["~/" + r, "$HOME/" + r, '"${HOME}/' + r + '"']
    return P, rnd.choice(opts)


def core(arg):
    v = rnd.choice(["rm"] * 5 + ["unlink", "shred", "rmdir"])
    f = rnd.choice(FLAGS) if v == "rm" else ""
    return " ".join(rnd.choice([f"{v} {f} {arg}", f"{v} {arg} {f}"]).split())


def shape(s, P):
    d, b = os.path.split(P)
    ds = "~" + d[len(H):] if d.startswith(H) else d
    return rnd.choice([core(s), core(s), f"D={s}; " + core('"$D"'), f"export D={s}; " + core("$D"), f"cd {ds} && " + core(shlex.quote(b)), f"(cd {ds}; " + core(shlex.quote(b)) + ")", f"echo {s} | xargs " + core(""),
                       f"for f in {s}; do " + core('"$f"') + "; done", f"find {s} " + rnd.choice(["-mindepth 1 -delete", "-name '*.o' -delete", "-exec rm -rf {} +", "-type f -delete", "-name x -exec rm {} \\;"]),
                       f"R=rm; $R {rnd.choice(FLAGS)} {s}", "f() { " + core(s) + "; }; f", "python3 -c " + shlex.quote("import subprocess; subprocess.run(['rm','-rf','%s'])" % P)])


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
    cmd = wrap(shape(s, P))
    t, rc = touched(cmd)
    if rc in (2, 126, 127):
        continue
    valid += 1; nt += t
    g = m.decide({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": CWD}) is not None
    byp += t and not g; fp += g and not t
    if t and not g:
        miss.append(cmd.replace(H, "$H").replace(S, "$S"))
check(f"fuzzer vs bash real: {valid} comandos válidos, {nt} entregaram alvo proibido a um rm falso, bypass={byp} (falso positivo={fp}, só informativo)", byp == 0 and nt > valid // 4, "\n     ".join(miss[:6]))

# --- mutantes: cada guarda apagada tem de reprovar a tabela ---
MUT = [('componente negado', 'if c in DENY_COMP and not (', 'if False and not ('), ('trava velha .git/*.lock', 'low[-1].endswith(".lock")', 'False'), ('raiz', 'if len(parts) <= 1:', 'if False:'), ('HOME e ancestrais', 'if any(low == hp[:len(low)] for hp in hps):', 'if False:'),
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
       ('$( )', 'for body in substitutions(w):', 'for body in []:'), ('cd só com &&', 'here = new if t == "&&" else merged if len(merged) <= 8 else merged[:7] + [None]', 'here = new'), ('teto do glob', '([(None, None)] if len(hits) > GLOB_MAX else [])', '[]'),
       ('for depois do peel', 'if len(ws) > 3 and ws[0] == "for" and ws[2] == "in":', 'if False:'), ('xargs', 'if verb == "xargs":', 'if False:'), ('find', 'if verb == "find":', 'if False:'), ('env -S', '(b == "env" and key in ("-S", "--split-string"))', 'False'),
       ('npx -c', '(b == "npx" and key in ("-c", "--call"))', 'False'), ('flock -c', 'if b == "flock" and ws[:1] in', 'if False and ws[:1] in'), ('verbo por variável', 'if len(v) == 1 and UNK not in v[0] and not re.search(r"[*?\\[]", v[0]):', 'if False:'),
       ('verbo desconhecido + flag recursiva', 'return check(ops, rec, () if rec else ("",), cwds, env)', 'pass'), ('verbo desconhecido sem flag: regras absolutas', 'return check(ops, rec, () if rec else ("",), cwds, env)', 'return check(ops, rec, False, cwds, env)'),
       ('export', 'if verb in ("export", "declare", "typeset", "local", "readonly"):', 'if False:'), ('cd nunca descarta o mais novo', 'merged if len(merged) <= 8 else merged[:7] + [None]', 'merged[:4]'), ('curinga fundo', 'for c in p.split("/")) > 2:', 'for c in p.split("/")) > 200:'),
       ('prazo', 'if time.monotonic() > DEADLINE:', 'if False:'), ('pasta compartilhada: arquivo solto', 'dir_ = os.path.isdir(f) or (rec and not os.path.lexists(f))', 'dir_ = True'),
       ('heredoc de shell: cwd de todos os cd', 'hit = scan_bash(body, ever, depth + 1, denv) if', 'hit = scan_bash(body, cwds, depth + 1, denv) if'), ('heredoc de interpretador: cwd de todos os cd', 'inline(body, ever, depth + 1, denv)', 'inline(body, cwds, depth + 1, denv)'),
       ('find: nomes internos do git', '(holds(f) and any(GITNAMES.search(p) for p in selective))', 'False'), ('<( ) no lexer', 'elif c in "<>" and nx == "(":', 'elif False:'), ('saída de <( ) é programa', 'for w in code_of(lex(body)[0]):', 'for w in []:'),
       ('echo|bash junta args', '[" ".join(ws[1:])] if ws and', '[] if ws and'), ('tamanho', 'if len(cmd) > MAX_CMD:', 'if False:'), ('profundidade', 'if depth > 6:', 'if depth > 600:'),
       ('tilde', 'return home() + s[1:] if s == "~" or s.startswith("~/")', 'return s if s == "~" or s.startswith("~/")'), ('glob', 'hits = sorted(itertools.islice(glob.iglob(p), GLOB_MAX + 1))', 'hits = []'), ('chave {a,b}', 'bs = [t] if UNK in t else braces(t)', 'bs = [t]'),
       ('teto da chave', 'len(alts) <= 16', 'len(alts) <= 1600'), ('caixa', 'low = [unicodedata.normalize("NFC", x).casefold() for x in parts]', 'low = list(parts)'), ('HOME vence scratch', 'rel, relp = (low[k:], parts[k:]) if k is not None else (None, None)', 'rel, relp = None, None'),
       ('node_modules', 'any(c in ALLOW_COMP for c in parts)', 'False'), ('.cache', 'any(relp[:len(a)] == list(a) for a in ALLOW_HOME)', 'False'), ('pyc', '(f.endswith(".pyc") and not os.path.isdir(f))', 'False'), ('rimraf', 'or verb == "rimraf"', 'or False'),
       ('popd', 'if os.path.basename(ws[0]) == "popd":', 'if False:'), ('lançador opaco', 'if verb in OPAQUE:', 'if False:'), ('source e .', 'verb in ("eval", "source", ".")', 'verb == "eval"')]
alive = []
for name, old, new in MUT:
    if SRC.count(old) != 1:
        alive.append(f"{name}: âncora ausente/duplicada ({SRC.count(old)}x)"); continue
    open(f"{H}/mut.py", "w").write(SRC.replace(old, new))
    try:
        mut = load(f"{H}/mut.py")
        if not set(run_table(mut) + ceilings(mut)) - set(bad):  # morto = produz linha de falha NOVA (com a tabela-base já falhando, qualquer mutante "reprovaria")
            alive.append(name + ": SOBREVIVEU")
    except Exception:  # noqa: BLE001 — mutante que quebra o import também foi pego
        pass
check(f"mutantes: {len(MUT)} guardas apagadas, todas reprovam a tabela", not alive, "; ".join(alive))
shutil.rmtree(H, ignore_errors=True); shutil.rmtree(S, ignore_errors=True)
print(f"{sum(results)}/{len(results)} blocos ok")
sys.exit(0 if all(results) else 1)
PYEOF
