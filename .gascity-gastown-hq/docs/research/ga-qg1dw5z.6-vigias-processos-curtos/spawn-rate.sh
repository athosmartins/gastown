#!/bin/sh
# spawn-rate.sh [seconds] [windows] — processes CREATED per second on this machine, read off the pid counter.
#
# A new process gets the next free pid, so the difference between two probes is every process created in
# between by anyone — including the ones that lived a millisecond (a `stat`, a `date`) and that a 1 s `ps`
# sampler (spawn-origin.py) almost never catches. It says HOW MANY, not WHO: use spawn-origin.py for the who.
# Read-only; one `sh` and one `sleep` per window. Pids wrap (99999 on macOS, /proc/sys/kernel/pid_max on
# Linux): a window that wraps is corrected once, so keep windows well under a wrap (a few seconds of
# hundreds of processes). Same hour of day before and after a change, or the comparison is the day's noise.
secs=${1:-30}
wins=${2:-1}
case "$secs$wins" in ''|*[!0-9]*) echo "usage: spawn-rate.sh [seconds] [windows]" >&2; exit 64 ;; esac
max=99999
if [ -r /proc/sys/kernel/pid_max ]; then max=$(cat /proc/sys/kernel/pid_max); fi
w=0
while [ "$w" -lt "$wins" ]; do
    p0=$(sh -c 'echo $$')
    sleep "$secs"
    p1=$(sh -c 'echo $$')
    # the probes themselves cost about four pids per window: noise below one process per second
    awk -v a="$p0" -v b="$p1" -v s="$secs" -v m="$max" 'BEGIN {
        d = b - a; if (d < 0) d += m
        printf "%.1f processes/s (%d created in %d s)\n", d / s, d, s }'
    w=$((w + 1))
done
