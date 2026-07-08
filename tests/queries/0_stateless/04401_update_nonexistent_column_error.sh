#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Issue #51146: ALTER TABLE ... UPDATE of a non-existent column must report the clear
# NO_SUCH_COLUMN_IN_TABLE message ("There is no column `n` in table"), not the confusing
# "Column `n` is updated but not requested to read" it regressed to in 23.5. Assert the
# actual human-facing message text, not only the error code.

${CLICKHOUSE_CLIENT} --query="DROP TABLE IF EXISTS mt_04401; CREATE TABLE mt_04401 (d Date) ENGINE = MergeTree ORDER BY tuple();"

err=$(${CLICKHOUSE_CLIENT} --query="ALTER TABLE mt_04401 UPDATE n = 2 WHERE 1;" 2>&1)

echo "$err" | grep -qF 'There is no column `n` in table' && echo "OK: clear message" || echo "FAIL: missing clear message: $err"
echo "$err" | grep -qF 'updated but not requested to read' && echo "FAIL: regressed message: $err" || echo "OK: no regressed message"

${CLICKHOUSE_CLIENT} --query="DROP TABLE mt_04401;"
