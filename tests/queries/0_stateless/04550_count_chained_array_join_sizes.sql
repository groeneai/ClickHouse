-- Tags: no-parallel-replicas
-- The EXPLAIN PLAN assertions below depend on the count()-over-ARRAY-JOIN rewrite, which is an
-- analyzer pass; the plan shape differs under parallel replicas.

-- Tests that count() over a chain of ARRAY JOIN keywords (a cartesian product), whose element
-- values are never referenced, is rewritten to sum() over the product of the per-keyword array
-- lengths so only the lightweight arr.size0 subcolumns are read instead of the whole arrays.
-- Extends the single-ARRAY-JOIN rewrite of issue #110812 to the chained shape.

SET enable_analyzer = 1;
SET optimize_functions_to_subcolumns = 1;
SET enable_parallel_replicas = 0;
SET optimize_use_implicit_projections = 0;
SET optimize_use_projections = 0;
-- The rewrite declines under unaligned array join (row count is the max length, not the product).
SET enable_unaligned_array_join = 0;

DROP TABLE IF EXISTS t_count_chain_aj;
CREATE TABLE t_count_chain_aj (id UInt64, c0 Array(UInt64), c1 Array(UInt64), c2 Array(UInt64), narr Array(Nullable(String)), lcarr Array(LowCardinality(String)), m Map(String, UInt64))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 64;

-- Include empty arrays to exercise LEFT ARRAY JOIN semantics.
INSERT INTO t_count_chain_aj
SELECT number, if(number % 7 = 0, [], range(number % 10)), range(number % 5), range(number % 3),
       arrayMap(x -> if(x % 2 = 0, NULL, toString(x)), range(number % 4)),
       arrayMap(x -> toString(x % 3), range(number % 4)),
       (SELECT map('k1', number, 'k2', number + 1))
FROM numbers(1000);

SELECT 'Correctness: chained count() must equal the optimization-off result for every ARRAY JOIN kind combination.';
SELECT (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
SELECT (SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
SELECT (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 LEFT ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 LEFT ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
SELECT (SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 LEFT ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 LEFT ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
-- Three ARRAY JOIN keywords.
SELECT (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2 SETTINGS optimize_functions_to_subcolumns = 0);
-- Nullable, LowCardinality and Map array columns.
SELECT (SELECT count() FROM t_count_chain_aj ARRAY JOIN narr ARRAY JOIN lcarr) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN narr ARRAY JOIN lcarr SETTINGS optimize_functions_to_subcolumns = 0);
SELECT (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN m) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN m SETTINGS optimize_functions_to_subcolumns = 0);
-- count(*) and count(1) are also plain row counts.
SELECT (SELECT count(*) FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
SELECT (SELECT count(1) FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) = (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0);
-- The output column name must remain count() (the rewrite must not rename the projection).
DESCRIBE (SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) FORMAT TSVRaw;

SELECT 'Optimization: the plan must read every arr.size0, drop the ARRAY JOIN, aggregate with sum() and never materialize a placeholder array.';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%c0.size0%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%c1.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%sum(%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%arrayWithConstant%';
-- Every factor of the product must fold to its size0 subcolumn; none of the arrays may be read in full.
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%length(%';
-- Three keywords: all three size0 subcolumns are read and the ARRAY JOIN is gone.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2) WHERE explain ILIKE '%c0.size0%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2) WHERE explain ILIKE '%c1.size0%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2) WHERE explain ILIKE '%c2.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 ARRAY JOIN c2) WHERE explain ILIKE '%ARRAY JOIN%';
-- Nullable, LowCardinality and Map array columns must also fold to size0 and drop the ARRAY JOIN.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN narr ARRAY JOIN lcarr) WHERE explain ILIKE '%narr.size0%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN narr ARRAY JOIN lcarr) WHERE explain ILIKE '%lcarr.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN narr ARRAY JOIN lcarr) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN m) WHERE explain ILIKE '%c0.size0%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN m) WHERE explain ILIKE '%m.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN m) WHERE explain ILIKE '%ARRAY JOIN%';
-- LEFT keywords: every factor still folds to size0, the ARRAY JOIN is dropped, and only the LEFT
-- keyword's own factor is wrapped in greatest(., 1) (INNER factors keep the plain size0).
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%greatest(c0.size0, 1)%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%c1.size0%' AND explain NOT ILIKE '%greatest(c1.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 ARRAY JOIN c1) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%greatest(c1.size0, 1)%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%c0.size0%' AND explain NOT ILIKE '%greatest(c0.size0%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%greatest(c0.size0, 1)%';
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%greatest(c1.size0, 1)%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj LEFT ARRAY JOIN c0 LEFT ARRAY JOIN c1) WHERE explain ILIKE '%ARRAY JOIN%';

SELECT 'Out-of-scope shapes in a chained query must still decline (keep the ARRAY JOIN) and stay equal to the optimization-off result.';
-- An element value of the chain is referenced: the arrays must still be materialized.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT sum(v) FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 AS v) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT sum(v) FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 AS v) WHERE explain ILIKE '%c0.size0%';
-- GROUP BY: the count is per group, not a single row count.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT id, count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 GROUP BY id) WHERE explain ILIKE '%ARRAY JOIN%';
-- A regular JOIN at the join-tree root over the chain: the root is a JOIN, not an ARRAY JOIN chain over a table.
SELECT (SELECT count() FROM t_count_chain_aj AS a INNER JOIN t_count_chain_aj AS b ON a.id = b.id ARRAY JOIN a.c0 ARRAY JOIN a.c1) = (SELECT count() FROM t_count_chain_aj AS a INNER JOIN t_count_chain_aj AS b ON a.id = b.id ARRAY JOIN a.c0 ARRAY JOIN a.c1 SETTINGS optimize_functions_to_subcolumns = 0);
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj AS a INNER JOIN t_count_chain_aj AS b ON a.id = b.id ARRAY JOIN a.c0 ARRAY JOIN a.c1) WHERE explain ILIKE '%ARRAY JOIN%';
-- empty_result_for_aggregation_by_empty_set changes empty-input semantics, so the rewrite declines.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS empty_result_for_aggregation_by_empty_set = 1) WHERE explain ILIKE '%ARRAY JOIN%';
-- With the setting disabled, the optimization must not fire (backward compatible): the ARRAY JOIN stays.
SELECT count() > 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0) WHERE explain ILIKE '%ARRAY JOIN%';
SELECT count() = 0 FROM (EXPLAIN PLAN actions = 1 SELECT count() FROM t_count_chain_aj ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS optimize_functions_to_subcolumns = 0) WHERE explain ILIKE '%size0%';

SELECT 'Correctness under empty_result_for_aggregation_by_empty_set: an all-empty chained ARRAY JOIN returns an empty result, matching the optimization-off behavior.';
DROP TABLE IF EXISTS t_count_chain_empty;
CREATE TABLE t_count_chain_empty (id UInt64, c0 Array(UInt64), c1 Array(UInt64)) ENGINE = MergeTree ORDER BY id;
INSERT INTO t_count_chain_empty VALUES (1, [], []), (2, [], []);
SELECT count() FROM t_count_chain_empty ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS empty_result_for_aggregation_by_empty_set = 1, optimize_functions_to_subcolumns = 1;
SELECT count() FROM t_count_chain_empty ARRAY JOIN c0 ARRAY JOIN c1 SETTINGS empty_result_for_aggregation_by_empty_set = 1, optimize_functions_to_subcolumns = 0;
DROP TABLE t_count_chain_empty;

DROP TABLE t_count_chain_aj;
