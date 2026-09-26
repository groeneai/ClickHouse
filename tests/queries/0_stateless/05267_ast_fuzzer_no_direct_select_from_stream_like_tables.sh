#!/usr/bin/env bash
# Queries run by the server-side AST fuzzer (`ast_fuzzer_runs`) must not read a stream-like table directly, even when
# the original query allows it: such a read consumes the table's messages, which may belong to another test.

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

DATA_DIR="${USER_FILES_PATH}/${CLICKHOUSE_TEST_UNIQUE_NAME}"
PROFILE="profile_direct_select_${CLICKHOUSE_DATABASE}"
mkdir -p "$DATA_DIR"
printf '1\n2\n3\n' > "$DATA_DIR/a.csv"

$CLICKHOUSE_CLIENT -m -q "
SET ast_fuzzer_runs = 0;
DROP SETTINGS PROFILE IF EXISTS $PROFILE;
CREATE SETTINGS PROFILE $PROFILE SETTINGS stream_like_engine_allow_direct_select = 1;
CREATE TABLE file_log (k UInt64) ENGINE = FileLog('$DATA_DIR/', 'CSV');
"

# The query allows direct reads through a settings profile and through the setting itself, and reads the rows.
# Sent over HTTP: the native client applies a query's own SETTINGS locally, where no settings profile exists.
${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}" -d "SELECT k FROM file_log ORDER BY k SETTINGS profile = '$PROFILE', stream_like_engine_allow_direct_select = 1, ast_fuzzer_runs = 30"

# Every copy the fuzzer ran for it must have had direct reads disabled.
$CLICKHOUSE_CLIENT -m -q "
SET ast_fuzzer_runs = 0;
SYSTEM FLUSH LOGS query_log;
SELECT count() > 0, countIf(Settings['stream_like_engine_allow_direct_select'] != '0') = 0
FROM system.query_log
WHERE current_database = currentDatabase() AND is_internal;
DROP TABLE file_log;
DROP SETTINGS PROFILE $PROFILE;
"

rm -rf "${USER_FILES_PATH:?}/${CLICKHOUSE_TEST_UNIQUE_NAME:?}"
