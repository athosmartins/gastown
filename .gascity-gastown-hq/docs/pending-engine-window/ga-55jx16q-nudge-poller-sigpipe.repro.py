# Experiment: does `gc nudge poll` survive when its stdout/stderr are PIPES whose parent-side
# read ends are gone (what exec.Cmd{Stderr: io.Discard} + Release() + parent exit produces)?
# Control: same command with stdout/stderr on a real file. Harmless target: digo-wa (empty queue).
import subprocess, sys, time, os, signal
city, gc = sys.argv[1], sys.argv[2]
argv = [gc, "nudge", "poll", "--city", city, "--session", "digo-wa-gawisp9h0ryl", "digo-wa"]
def run(label, mk):
    out, err, closers = mk()
    p = subprocess.Popen(argv, stdout=out, stderr=err, start_new_session=True)
    for c in closers: c()          # parent drops its side, like the exited CLI process
    t0 = time.time(); rc = None
    while time.time() - t0 < 20:
        rc = p.poll()
        if rc is not None: break
        time.sleep(0.2)
    alive = rc is None
    if alive:
        p.send_signal(signal.SIGTERM)
        try: p.wait(5)
        except Exception: p.kill()
    print(f"{label}: alive_after_20s={alive} rc={p.returncode if not alive else 'killed-by-me'} elapsed={time.time()-t0:.1f}s", flush=True)
def pipes():
    r1, w1 = os.pipe(); r2, w2 = os.pipe()
    return w1, w2, [lambda: os.close(r1), lambda: os.close(r2), lambda: os.close(w1), lambda: os.close(w2)]
def devnull():
    f = open(os.devnull, "wb"); return f, f, [f.close]
run("A pipes-with-dead-reader (current ensureNudgePoller)", pipes)
run("B /dev/null file (control)", devnull)
