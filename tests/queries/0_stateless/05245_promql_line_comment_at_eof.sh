#!/usr/bin/env bash
# Tags: no-fasttest, no-replicated-database
# no-fasttest: the PromQL grammar requires ANTLR4, which is disabled in the fast-test build.
# no-replicated-database: the experimental TimeSeries table engine does not round-trip through DatabaseReplicated.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 -m --query "
CREATE TABLE ts ENGINE = TimeSeries;
INSERT INTO ts (metric_name, tags, samples) VALUES ('up', map('instance', 'host1'), [(toDateTime64(1700000000, 3), 30)]);
"

echo "-- PromQL line comments may end at EOF"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query "up # trailing comment" | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --query "SELECT * FROM prometheusQuery(ts, 'up # trailing comment', 1700000000)" | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query "up #!comment" | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --query "SELECT * FROM prometheusQuery(ts, 'up #!comment', 1700000000)" | cut -f1,3

echo "-- The text after '#' needs no space"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query "up #comment" 2>&1 | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --query "SELECT * FROM prometheusQuery(ts, 'up #comment', 1700000000)" 2>&1 | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query "up#comment" 2>&1 | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --query "SELECT * FROM prometheusQuery(ts, 'up#comment', 1700000000)" 2>&1 | cut -f1,3

echo "-- A bare '#' at EOF is an empty comment"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query "up #" 2>&1 | cut -f1,3
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --query "SELECT * FROM prometheusQuery(ts, 'up #', 1700000000)" 2>&1 | cut -f1,3

echo "-- A comment the SQL lexer reads as an unclosed string, at EOF"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 --query $'up #don\'t' 2>&1 | cut -f1,3

echo "-- A semicolon in a comment at EOF does not end the statement"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 -m --query $'up{instance="host1"}; sum(up) #a ; b' 2>&1 | cut -f1,3

echo "-- A bare CR ends a PromQL comment, so the next statement is not swallowed"
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 -m --query $'up #comment\r; SET dialect = \'clickhouse\'; SELECT \'next statement\'' | cut -f1,3
# The SQL lexer reads `# comment\r; ...` as one comment up to the newline, so the end is ambiguous: an error, not a wrong split.
$CLICKHOUSE_CLIENT --allow_experimental_time_series_table 1 --dialect promql --promql_table ts --promql_evaluation_time 1700000000 -m --query $'up # comment\r; SET dialect = \'clickhouse\'; SELECT \'next statement\'' 2>&1 | grep -o -m1 'Cannot find the end of the PromQL statement'

$CLICKHOUSE_CLIENT --query "DROP TABLE ts"
