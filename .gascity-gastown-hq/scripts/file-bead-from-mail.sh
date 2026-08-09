#!/usr/bin/env bash
# file-bead-from-mail.sh — file a new bead that cites a mail message as its
# source, carrying the mail's real envelope author/recipient/timestamp
# forward as structured bead metadata instead of relying on free-text prose
# ("ACHADO DE X, verificado em Y") that has no disputable-proof value and
# doesn't survive the source mail eventually being archived/purged.
#
# Root problem (ga-3rqwa): a bead filed from a mail, citing it only in prose,
# leaves NO way to answer "who actually wrote this?" once the mail is gone —
# and mail *does* eventually go away (wisp-compact TTL purge, retention
# policy, or just human error). The fix is to copy the mail's sender/
# timestamp/recipient onto the NEW bead at creation time, so the answer lives
# on the work item itself and never depends on the source mail's continued
# existence or on anyone's memory of what it said.
#
# Usage:
#   file-bead-from-mail.sh --mail-id <mail-bead-id> [bd create args...]
#   file-bead-from-mail.sh [bd create args...]              # no mail source
#
# All positional/flag args you'd normally pass to `bd create` (title,
# --description, --type, --priority, ...) are forwarded verbatim. If you also
# pass your own --metadata, its keys are preserved — this script only adds
# the mail.* keys into that same JSON object.
#
# Negative-test guarantee (ga-3rqwa acceptance criterion): if --mail-id is
# omitted, this is a plain passthrough to `bd create` — no mail.* key is ever
# added, and no author is ever invented. An absent field is an honest answer;
# a wrong author is worse than no author.
set -euo pipefail

MAIL_ID=""
USER_METADATA="{}"
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --mail-id)
            MAIL_ID="${2:?--mail-id requires a value}"
            shift 2
            ;;
        --metadata)
            USER_METADATA="${2:?--metadata requires a value}"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# ${ARGS[@]} on a zero-element array throws "unbound variable" under
# set -u on bash <4.4 (this box's /usr/bin/env bash resolves to the
# macOS-shipped 3.2) — length-check first rather than relying on the
# ${ARGS[@]+"${ARGS[@]}"} idiom, which is easy to get subtly wrong.
run_bd_create() {
    if [ "${#ARGS[@]}" -gt 0 ]; then
        exec bd create "${ARGS[@]}" --metadata "$1"
    else
        exec bd create --metadata "$1"
    fi
}

if [ -z "$MAIL_ID" ]; then
    run_bd_create "$USER_METADATA"
fi

MAIL_JSON=$(bd show "$MAIL_ID" --json 2>/dev/null) || {
    echo "file-bead-from-mail: could not read mail bead '$MAIL_ID' — aborting rather than filing without checking. Verify the id with 'bd show $MAIL_ID'." >&2
    exit 1
}

MAIL_TYPE=$(echo "$MAIL_JSON" | jq -r '.[0].issue_type // ""' 2>/dev/null)
if [ "$MAIL_TYPE" != "message" ]; then
    echo "file-bead-from-mail: '$MAIL_ID' has issue_type='$MAIL_TYPE', not 'message' — refusing to treat a non-mail bead as a mail source. Pass the actual mail bead id, or drop --mail-id if this new bead has no mail origin." >&2
    exit 1
fi

AUTHOR=$(echo "$MAIL_JSON" | jq -r '.[0].sender // ""' 2>/dev/null)
RECIPIENT=$(echo "$MAIL_JSON" | jq -r '.[0].assignee // ""' 2>/dev/null)
SENT_AT=$(echo "$MAIL_JSON" | jq -r '.[0].created_at // ""' 2>/dev/null)

if [ -z "$AUTHOR" ]; then
    echo "file-bead-from-mail: mail '$MAIL_ID' has no recorded sender — filing WITHOUT mail.author (absent is honest; a guessed author is worse than none)." >&2
fi

MERGED_METADATA=$(jq -nc \
    --argjson user "$USER_METADATA" \
    --arg source_id "$MAIL_ID" \
    --arg author "$AUTHOR" \
    --arg recipient "$RECIPIENT" \
    --arg sent_at "$SENT_AT" \
    '$user
     | .["mail.source_id"] = $source_id
     | if $author    != "" then .["mail.author"]    = $author    else . end
     | if $recipient != "" then .["mail.recipient"] = $recipient else . end
     | if $sent_at    != "" then .["mail.sent_at"]    = $sent_at    else . end')

run_bd_create "$MERGED_METADATA"
