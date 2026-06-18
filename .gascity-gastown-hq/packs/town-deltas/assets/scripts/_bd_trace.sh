#!/usr/bin/env bash
# No-op bd trace wrapper — emits trace lines only when GC_BD_TRACE is set.
# Sourced by gate-sweep.sh and other scripts.
_BD_TRACE_CALLER="${1:-unknown}"
