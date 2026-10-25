#!/usr/bin/env bash
set -euo pipefail

# Logflare's tables live in the _supabase database and are owned by supabase_admin,
# which shares the postgres password (PGPASSWORD) in this stack.
echo "Trimming old Logflare logs..."
psql --no-psqlrc -v ON_ERROR_STOP=1 -U supabase_admin -d _supabase \
	-c "SELECT analytics_cleanup_old_logs();" \
	-c "VACUUM ANALYZE;"
echo "Logs trimmed."
