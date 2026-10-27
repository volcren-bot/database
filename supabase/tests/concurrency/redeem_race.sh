#!/usr/bin/env bash
# A share code must work exactly once, even when many accounts redeem it at the same moment.
# pgTAP runs in one transaction, so it cannot race; this script opens real parallel sessions
# against the local database (supabase start) and checks that exactly one redemption wins.
# Usage: supabase/tests/concurrency/redeem_race.sh [parallel sessions, default 20]
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
N="${1:-20}"
psql_() { psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

OWNER=aaaaaaaa-0000-0000-0000-000000000001
SCRIPT=bbbbbbbb-0000-0000-0000-000000000001
user_id() { printf 'cccccccc-0000-0000-0000-%012d' "$1"; }

cleanup() {
	psql_ -c "DELETE FROM scripts.scripts WHERE id = '$SCRIPT'" \
	      -c "DELETE FROM auth.users WHERE id = '$OWNER' OR id::text LIKE 'cccccccc-0000-0000-0000-%'" >/dev/null || true
}
trap cleanup EXIT
cleanup

signup() {
	psql_ -c "INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
	          VALUES ('$1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '$2@example.com',
	                  '{\"provider\":\"discord\"}', '{\"full_name\":\"$2\"}')"
}

signup "$OWNER" race-owner
psql_ -c "UPDATE profiles.profiles SET role = 'scripter' WHERE id = '$OWNER'"
for i in $(seq 1 "$N"); do signup "$(user_id "$i")" "race-$i"; done

# An unpublished official script: nobody can see it, so every redeemer is a real candidate
psql_ >/dev/null <<SQL
SELECT set_config('request.jwt.claims', '{"sub":"$OWNER","role":"authenticated"}', false);
INSERT INTO scripts.scripts (id, title, description, content) VALUES ('$SCRIPT', 'Race', 'd', 'c');
SQL
CODE=$(psql_ -At <<SQL
SELECT set_config('request.jwt.claims', '{"sub":"$OWNER","role":"authenticated"}', false);
SET ROLE authenticated;
SELECT code FROM scripts.create_share_code('$SCRIPT', now() + interval '1 day');
SQL
)
CODE=$(printf '%s\n' "$CODE" | tail -n 1)
[[ "$CODE" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: no code created ($CODE)"; exit 1; }

OUT=$(mktemp -d)
redeem() {
	psql_ -At >"$OUT/$1" <<SQL
SELECT set_config('request.jwt.claims', '{"sub":"$2","role":"authenticated"}', false);
SET ROLE authenticated;
SELECT status FROM scripts.redeem_share_code('$CODE');
SQL
}

# N different accounts redeem the code together, and one of them submits it three times at once
for i in $(seq 1 "$N"); do redeem "u$i" "$(user_id "$i")" & done
redeem "dup1" "$(user_id 1)" & redeem "dup2" "$(user_id 1)" &
wait

# set_config prints its own value on the first line; the status is the last one
statuses=$(for f in "$OUT"/*; do tail -n 1 "$f"; done | sort | uniq -c | tr '\n' ' ')
ok_count=$(for f in "$OUT"/*; do tail -n 1 "$f"; done | grep -c '^ok$' || true)
grants=$(psql_ -At -c "SELECT count(*) FROM scripts.grants WHERE script_id = '$SCRIPT'")
redeemed=$(psql_ -At -c "SELECT count(*) FROM scripts.share_codes WHERE script_id = '$SCRIPT' AND redeemed_at IS NOT NULL")

echo "statuses: $statuses"
echo "ok=$ok_count grants=$grants redeemed_codes=$redeemed"
rm -rf "$OUT"

if [[ "$ok_count" == 1 && "$grants" == 1 && "$redeemed" == 1 ]]; then
	echo "PASS: the code worked exactly once across $((N + 2)) concurrent redemptions"
else
	echo "FAIL: the code was not single-use"
	exit 1
fi
