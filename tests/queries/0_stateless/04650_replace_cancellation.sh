#!/usr/bin/env bash
# Tags: long, no-fasttest, no-msan, no-parallel, no-coverage, no-flaky-check
# no-msan: that build has no embedded compiler, so case 22 would assert nothing.
# no-parallel: case 21 samples the process-wide `CurrentMetrics::QueryNonInternal`.
# no-coverage: per-test coverage instrumentation makes the fixed side of cases 8 and 16 unstable.
# no-flaky-check: timeout-based, so rerun-based flakiness detection does not apply.

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

# Every case bounds the elapsed time the server reports in its `TIMEOUT_EXCEEDED` message. Each is sized
# so its uninterruptible prologue stays a small part of the deadline on the slowest build while its total
# work outlasts the deadline on the fastest. Coverage never reaches CXX_FLAGS, so it is read separately.
DEADLINE=1
DEADLINE_MS=1000
SCALE=1
[ -n "$(${CLICKHOUSE_CLIENT} --query "SELECT value FROM system.build_options WHERE name = 'CXX_FLAGS' AND value LIKE '%sanitize=%'")" ] && SCALE=2
case "$(${CLICKHOUSE_CLIENT} --query "SELECT value FROM system.build_options WHERE name = 'WITH_COVERAGE'")" in ON|1) SCALE=2 ;; esac
BOUND=$((SCALE * 2000))
# How late the stop may be, on top of the deadline. A case setting an earlier deadline keeps the same
# allowance, so at the shared deadline its bound is exactly $BOUND.
ALLOWANCE=$((BOUND - DEADLINE_MS))

# $1 = label, $2 = query, $3 = overflow mode (default "throw"), $4 = query id (default none),
# $5 = "fold" if the call is constant-folded (no pipeline), empty for a pipeline case,
# $6 = this case's own deadline in seconds (default $DEADLINE)

# Regexp compilation is pinned off everywhere but case 22: the compiled-regexp cache is server-global with
# a compile threshold of 3, and this test runs up to 5 times, so an earlier run's pattern would be cached.

# Only `checkTimeLimit` reports an elapsed number; `addPipelineExecutor` and `throwIfKilled` pass a literal
# zero. For a FOLD nothing else can produce one, so requiring the number is what tells the builds apart -
# a missing number means the case is mis-sized, not that the function is broken.
run() {
    local label="$1" query="$2" mode="${3:-throw}" query_id="${4:-}" shape="${5:-}" deadline="${6:-$DEADLINE}"
    local output rc elapsed_ms reported_max_ms bound_ms
    # shellcheck disable=SC2086
    output=$(timeout 600 ${CLICKHOUSE_CLIENT} --max_execution_time "$deadline" --timeout_overflow_mode "$mode" \
        --compile_regular_expressions 0 \
        ${query_id:+--query_id "$query_id"} \
        --query "$query" 2>&1)
    rc=$?
    elapsed_ms=$(printf '%s' "$output" | grep -oP 'elapsed \K[0-9]+(?=\.)' | head -1)
    reported_max_ms=$(printf '%s' "$output" | grep -oP 'maximum: \K[0-9]+(?= ms)' | head -1)
    bound_ms=$(printf '%.0f' "$(echo "$deadline" | awk '{print $1 * 1000}')")
    # A fractional deadline is a Seconds setting truncated to whole milliseconds, so read back what the
    # server actually enforced rather than assuming it is what was asked for.
    if [ -n "$reported_max_ms" ] && [ "$reported_max_ms" != "$bound_ms" ]; then
        echo "$label: DEADLINE NOT ENFORCED AS SET, asked ${bound_ms} ms and the server enforced ${reported_max_ms} ms"
        return
    fi
    bound_ms=$((bound_ms + ALLOWANCE))
    # A verdict rather than the number itself keeps the reference stable across machine speeds.
    if [ -n "$elapsed_ms" ]; then
        if [ "$elapsed_ms" -lt "$bound_ms" ]; then
            echo "$label: stopped within bound"
        else
            echo "$label: OVERSHOT ${elapsed_ms} ms"
        fi
    elif [ "$rc" = 0 ]; then
        # Named apart from a missing checkpoint: the remedy is re-sizing the case, not fixing the function.
        echo "$label: completed without hitting the deadline"
    elif ! printf '%s' "$output" | grep -q TIMEOUT_EXCEEDED; then
        # Anything else - a memory limit, say - leaves the deadline untested either way.
        echo "$label: inconclusive, failed with code $(printf '%s' "$output" | grep -oP 'Code: \K[0-9]+' | head -1)"
    elif [ "$shape" = fold ]; then
        echo "$label: stopped without reaching the in-function checkpoint"
    else
        echo "$label: cancelled before the pipeline started"
    fi
}

# 1. Constant folding: no pipeline exists while this runs. Many small folds rather than one large one,
#    because the budget is only consulted between folds, so one fold is the smallest interruptible step.
FOLD_REGEXP=$(python3 -c "print('arraySum([' + ', '.join(\"length(replaceRegexpAll(repeat('%04d', 250000), '[0-9]{1,3}', 'x'))\" % i for i in range(200)) + '])')")
run "fold regexp" "SELECT $FOLD_REGEXP FORMAT Null" throw "" fold 0.4

# 2. The same work in the pipeline, which makes case 1 non-vacuous: the defect is the missing in-function
#    checkpoint, not something specific to constant folding. All three arguments must be materialized -
#    materializing only the haystack selects the JIT-accelerated implementation (case 22).
run "pipe regexp" \
    "SELECT length(replaceRegexpAll(materialize(repeat(repeat('1', 1000000), 60)), materialize('[0-9]((a|b)(c|d)|(e|f)(g|h))?'), materialize('x'))) FROM numbers(1) FORMAT Null"

# 3. Many small rows: the per-row loops, which a checkpoint scoped to a single value would never reach.
#    max_block_size is pinned in every per-row case: the runner randomizes it down to 8000, and a split
#    block would let the unconditional end-of-call check bound the query on its own.
run "many rows" \
    "SELECT sum(length(replaceRegexpAll(materialize(repeat('1', 20000)), materialize('[0-9]{1,3}'), materialize('x')))) FROM numbers(10000) SETTINGS max_block_size = 10000"

# 4. Folds too small to reach a throttled checkpoint, so only the unconditional per-call checks can stop
#    this - the sole cover for the bulk-copy fast paths, which enter no loop. Size by PATTERN BYTES, not
#    match count, or the in-loop check fires. An array, not a '+' chain: formatting one overruns the stack.
FOLDS=$(python3 -c "print('arraySum([' + ', '.join(\"length(replaceRegexpAll('zzz%d', repeat('[a-z0-9]{1,2}', 2500), 'x'))\" % i for i in range(240)) + '])')")
run "many folds" "SELECT $FOLDS FORMAT Null" throw "" fold 0.4

# 5. One match per iteration with a replacement much larger than the match: the whole cost is generated
#    output, which accounting scoped to the searched input would price at zero. Split across folds so each
#    output is released before the next starts, keeping the case inside the test memory profile.
EXPAND=$(python3 -c "print(' + '.join(\"length(replaceAll(repeat('%s', 500), '%s', repeat('Y', 1000000)))\" % (c, c) for c in 'qwertyuiopas'))")
run "expanding replacement" "SELECT $EXPAND FORMAT Null" throw "" fold

# 6. The literal-search implementation reached through the regexp function's trivial-pattern shortcut. The
#    needle must be a plain literal, or the shortcut is not taken and this duplicates case 2. Materializing
#    happens before the call, so the value stays small and the cost is carried by the replacement length.
run "regexp fallback to literal" \
    "SELECT length(replaceRegexpAll(materialize(repeat(repeat('ab', 1000000), 60)), 'ab', 'YZYZYZYZYZYZYZYZYZYZYZYZYZYZYZYZ')) FROM numbers(1) FORMAT Null"

# 7. The same work reached directly through replaceAll rather than through that shortcut. Split like case 5,
#    with a distinct value per fold so none is shared.
SPLIT_ALL=$(python3 -c "print('arraySum([' + ', '.join(\"length(replaceAll(repeat(repeat('%s', 1000000), 30), '%s', 'YZ'))\" % (p, p) for p in ['ab','cd','ef','gh','ij','kl','mn','op','qr','st']) + '])')")
run "replaceAll" "SELECT $SPLIT_ALL FORMAT Null" throw "" fold 0.4

# 8. Empty haystacks with a per-row pattern: nothing is scanned or written, so the work is one matcher per
#    row. The needle MUST vary, or the matcher is built once outside the loop and the case measures nothing.
run "per-row matcher setup" \
    "SELECT sum(length(replaceRegexpAll(materialize(''), toString(number)||'[0-9]{1,3}(a|b|c)+x?', 'y'))) FROM numbers(1000000) SETTINGS max_block_size = 1000000"

# 9. A one-byte needle and replacement on the per-row entry point. It has to be a fold: in the pipeline the
#    executor's own between-block check bounds the query whatever the function does. Split like case 7.
SPLIT_ONE=$(python3 -c "print('arraySum([' + ', '.join(\"length(replaceAll(repeat(repeat('%s', 1000000), 30), '%s', '%s'))\" % (h, h[1], r) for (h, r) in [('ab','c'),('cd','e'),('ef','g'),('gh','i'),('ij','k'),('kl','m'),('mn','o'),('op','q'),('qr','s'),('st','u')]) + '])')")
run "one-byte in place" "SELECT $SPLIT_ONE FORMAT Null" throw "" fold 0.4

# 10. Many capture references against an empty capture group: every match executes the whole list while
#     producing no output, so one checkpoint per match is not enough. The group must be empty and the
#     references must be substitutions rather than literal bytes.
run "instruction list" \
    "SELECT length(replaceRegexpAll(repeat('a', 200000), '()', repeat('\\\\1', 20000))) FORMAT Null" throw "" fold

# 11. A pattern matching the empty string at every position: each iteration advances one byte, runs no
#     instructions and writes nothing, which is why the budget counts iterations rather than bytes.
EMPTY_MATCHES=$(python3 -c "print('arraySum([' + ', '.join(\"length(replaceRegexpAll(repeat('%04d', 250000), '()', ''))\" % i for i in range(20)) + '])')")
run "empty matches" "SELECT $EMPTY_MATCHES FORMAT Null" throw "" fold 0.2

# 12. A replacement of 200000 capture references parsed per row against a needle that never matches: the
#     whole list is built before any processing loop runs. The haystack must not match, or the case
#     degenerates into case 10; only the needle varies per row, so nothing large has to be materialized.
run "replacement parsing" \
    "SELECT sum(length(replaceRegexpAll(materialize(''), toString(number)||'(q)', repeat('\\\\1', 200000)))) FROM numbers(1500) SETTINGS max_block_size = 1500"

# 13. A FixedString haystack, which reaches the regexp loop through its own entry point.
run "fixed string haystack" \
    "SELECT sum(length(replaceRegexpAll(toFixedString(materialize(repeat('1', 20000)), 20000), '[0-9]((a|b)(c|d)|(e|f)(g|h))?', 'x'))) FROM numbers(2000) SETTINGS max_block_size = 2000"

# 14. A different replacement per row, which rebuilds the instruction list per row.
run "per-row replacement" \
    "SELECT sum(length(replaceRegexpAll(materialize(repeat('1', 20000)), '[0-9]{1,3}', toString(number)))) FROM numbers(10000) SETTINGS max_block_size = 10000"

# 15. A SINGLE match whose instruction list is itself over budget, so charging the list only after the loop
#     would leave one match uninterruptible. Its work cannot be grown - the cost is the generated output,
#     already near the test memory profile - so it takes an earlier deadline that lands inside the match.
run "one match, long instruction list" \
    "SELECT length(replaceRegexpAll(repeat('a', 1000000), '(.*)', repeat('\\\\1', 2000))) FORMAT Null" throw "" fold 0.2

# 16. The "replace first" specialization, which leaves the per-row loop at the first match - a different
#     loop exit from "replace all". Empty haystacks with a per-row pattern make the matcher setup the whole
#     cost, which is the part the early exit does not skip.
run "replaceRegexpOne" \
    "SELECT sum(length(replaceRegexpOne(materialize(''), toString(number)||'[0-9]{1,3}(a|b|c)+x?', 'y'))) FROM numbers(1000000) SETTINGS max_block_size = 1000000"

# NOTE. Four charged sites have no case of their own - the unconditional suffix and remainder copies, the
#     two FixedString offset loops after a bulk copy, and the JIT output-byte charge - because none can be
#     made to outlast the deadline within the test memory profile. Hence the gaps in the numbering.

# 19. The "break" overflow mode, where checkTimeLimit() returns false instead of throwing, so a path that
#     never calls it ignores the deadline entirely. Wall time is asserted rather than an error: in the
#     pipeline the executor's soft check and this function's check race, and both are correct stops.
break_start=$(date +%s%N)
timeout 600 ${CLICKHOUSE_CLIENT} --max_execution_time "$DEADLINE" --timeout_overflow_mode break \
    --compile_regular_expressions 0 \
    --query "SELECT length(replaceRegexpAll(materialize(repeat(repeat('1', 1000000), 60)), materialize('[0-9]((a|b)(c|d)|(e|f)(g|h))?'), materialize('x'))) FROM numbers(1) FORMAT Null" \
    > /dev/null 2>&1
break_ms=$(( ($(date +%s%N) - break_start) / 1000000 ))
if [ "$break_ms" -lt "$((BOUND * 2))" ]; then
    echo "break pipeline: stopped within bound"
else
    echo "break pipeline: OVERSHOT ${break_ms} ms"
fi

#     A folded call cannot report a partial result, so there the timeout always surfaces as an error.
timeout 600 ${CLICKHOUSE_CLIENT} --max_execution_time "$DEADLINE" --timeout_overflow_mode break \
    --compile_regular_expressions 0 \
    --query "SELECT length(replaceRegexpAll(repeat(repeat('1', 1000000), 200), '[0-9]{1,3}', 'x')) FORMAT Null" 2>&1 \
    | grep -o -m1 "TIMEOUT_EXCEEDED" || echo "break fold: no timeout"

# 20. KILL QUERY, a different channel: it sets the killed flag and surfaces through a separate branch of the
#     same check. No time limit, so only the kill can stop the query, and the synchronous kill's wait is
#     asserted. Both halves are needed, or a query that never started would be "killed" instantly.
kill_id="${CLICKHOUSE_DATABASE}_replace_kill"
${CLICKHOUSE_CLIENT} --query_id "$kill_id" --compile_regular_expressions 0 \
    --query "SELECT length(replaceRegexpAll(repeat(repeat('1', 1000000), 400), '[0-9]{1,3}', 'x')) FORMAT Null" \
    > /dev/null 2>&1 &
kill_bg=$!
kill_seen=0
for _ in $(seq 1 100); do
    if [ "$(${CLICKHOUSE_CLIENT} --query "SELECT count() FROM system.processes WHERE query_id = '$kill_id'")" = 1 ]; then
        kill_seen=1
        break
    fi
    sleep 0.1
done
kill_start=$(date +%s%N)
kill_rows=$(${CLICKHOUSE_CLIENT} --query "KILL QUERY WHERE query_id = '$kill_id' SYNC FORMAT TSV" 2>/dev/null | grep -c "$kill_id")
kill_ms=$(( ($(date +%s%N) - kill_start) / 1000000 ))
wait $kill_bg 2>/dev/null
if [ "$kill_seen" != 1 ]; then
    echo "kill query: TARGET NEVER RAN"
elif [ "$kill_rows" != 1 ]; then
    echo "kill query: KILL DID NOT REPORT THE TARGET"
elif [ "$kill_ms" -lt "$((BOUND * 2))" ]; then
    echo "kill query: killed within bound"
else
    echo "kill query: OVERSHOT ${kill_ms} ms"
fi

# 21. A `replace*` call inside a stored expression, whose instance outlives the query that defined it, so
#     the deadline to check is the RUNNING query's. Rows must arrive in one block, or the pipeline's check
#     bounds the INSERT; and be DISTINCT, or one evaluation is copied per repeat and the rows buy no work.
${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_replace_stored SYNC"
${CLICKHOUSE_CLIENT} --query "
    CREATE TABLE t_replace_stored (k String) ENGINE = MergeTree
    PARTITION BY substring(replaceRegexpAll(k, '[0-9]((a|b)(c|d)|(e|f)(g|h))?', 'x'), 1, 1) ORDER BY tuple()"
run "stored expression" \
    "INSERT INTO t_replace_stored SELECT repeat(concat(toString(number + 1000), '1'), 200000) FROM numbers(40) SETTINGS max_insert_block_size = 40, min_insert_block_size_rows = 40" \
    throw "" "" 0.2
${CLICKHOUSE_CLIENT} --query "DROP TABLE t_replace_stored SYNC"

#     The leak side: a retained QueryStatus keeps its `QueryNonInternal` increment, so the count never
#     returns. A zero delta rather than a tolerance, which would mask a drop: the metric excludes internal
#     queries and the test is no-parallel, so every query in the window is its own and cancels out.
sample_queries() {
    local m=999999 v
    for _ in 1 2 3 4 5; do
        v=$(${CLICKHOUSE_CLIENT} --query "SELECT value FROM system.metrics WHERE metric = 'QueryNonInternal'")
        [ "$v" -lt "$m" ] && m=$v
    done
    echo "$m"
}

for i in 1 2 3 4 5 6; do
    ${CLICKHOUSE_CLIENT} --query "DROP TABLE IF EXISTS t_replace_stored_$i SYNC"
done
queries_before=$(sample_queries)
for i in 1 2 3 4 5 6; do
    ${CLICKHOUSE_CLIENT} --query "CREATE TABLE t_replace_stored_$i (k String, v String) ENGINE = MergeTree ORDER BY k"
    # ALTER, not CREATE: a CREATE analyses the expression on a context with no query state to capture, so
    # the case would be vacuous.
    ${CLICKHOUSE_CLIENT} --max_execution_time "$DEADLINE" --query "
        ALTER TABLE t_replace_stored_$i ADD INDEX ix replaceRegexpAll(v, '[0-9]', 'x') TYPE set(10) GRANULARITY 1"
done
queries_after=$(sample_queries)
if [ "$((queries_after - queries_before))" = 0 ]; then
    echo "stored expression leak: no query state retained"
else
    echo "stored expression leak: RETAINED $((queries_after - queries_before)) query states"
fi
for i in 1 2 3 4 5 6; do
    ${CLICKHOUSE_CLIENT} --query "DROP TABLE t_replace_stored_$i SYNC"
done

# 22. The JIT-compiled matcher, which has its own copy of the substitution loop. Reached only with a
#     non-constant haystack, constant non-trivial pattern and constant replacement, and only once compiled.

#     A failed compile is silent, so it is asserted via `CompileRegexpFunction`. Drop the cache first:
#     `getOrSet` returns early on a hit without compiling. `argMax` not `sum`, because the stress runner
#     reuses one database per thread and a sum would answer with an earlier run's compile.
JIT_PINS="--compile_expressions 0 --compile_aggregate_expressions 0 --compile_sort_description 0"
jit_id="${CLICKHOUSE_DATABASE}_replace_jit"
${CLICKHOUSE_CLIENT} --query "SYSTEM DROP COMPILED EXPRESSION CACHE"
run "jit matcher" \
    "SELECT sum(length(replaceRegexpAll(materialize(repeat('1', 10000)), '[0-9]{1,3}', repeat('y', 20)))) FROM numbers(40000) SETTINGS max_block_size = 40000, compile_regular_expressions = 1, min_count_to_compile_regular_expression = 0, compile_expressions = 0, compile_aggregate_expressions = 0, compile_sort_description = 0" \
    throw "$jit_id"
${CLICKHOUSE_CLIENT} --query "SYSTEM FLUSH LOGS query_log"
# shellcheck disable=SC2086
jit_regexp_compiles=$(${CLICKHOUSE_CLIENT} $JIT_PINS --query "SELECT argMax(ProfileEvents['CompileRegexpFunction'], event_time_microseconds) FROM system.query_log WHERE query_id = '$jit_id' AND current_database = currentDatabase() AND type IN ('QueryFinish', 'ExceptionWhileProcessing')")
# shellcheck disable=SC2086
jit_embedded=$(${CLICKHOUSE_CLIENT} $JIT_PINS --query "SELECT value FROM system.build_options WHERE name = 'USE_EMBEDDED_COMPILER'")
case "$jit_embedded" in
    ON|1) if [ "$jit_regexp_compiles" -ge 1 ]; then
              echo "jit matcher: compiled"
          else
              echo "jit matcher: NOT COMPILED, the case ran the interpreted loop"
          fi ;;
    *)    echo "jit matcher: NO EMBEDDED COMPILER, the case ran the interpreted loop" ;;
esac

# 25. A FixedString haystack on the literal implementation, with its own per-row offset and search loops.
#     The haystack MUST be materialized: a constant is unwrapped to its nested column before dispatch,
#     leaving the needle non-constant. A prologue is unavoidable, so size by ROWS, never by written bytes.
run "fixed string literal" \
    "SELECT sum(length(replaceAll(toFixedString(materialize(repeat('b', 1600)), 1600), 'b', 'YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY'))) FROM numbers(50000) SETTINGS max_block_size = 50000"
