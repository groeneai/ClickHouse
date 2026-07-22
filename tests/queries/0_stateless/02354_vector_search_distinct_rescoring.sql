-- Tags: no-fasttest, no-ordinary-database, no-parallel-replicas
-- no-parallel-replicas: If parallel replicas are on, the optimization (no rescoring) may not work.
-- Test that SELECT DISTINCT ... ORDER BY <distance> LIMIT N gets the same second-pass vector-search
-- optimizations as the non-DISTINCT case: `_distance` substitution (vector_search_with_rescoring = 0)
-- and candidate-row filtering (vector_search_with_rescoring = 1). See issue #111343.
SET explain_query_plan_default = 'legacy';

SET enable_analyzer = 1;
SET parallel_replicas_local_plan = 1; -- this setting is randomized, set it explicitly to force local plan for parallel replicas

DROP TABLE IF EXISTS tab;

CREATE TABLE tab(id Int32, vec Array(Float32), attr1 Int32, INDEX idx vec TYPE vector_similarity('hnsw', 'L2Distance', 2)) ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 2;
INSERT INTO tab VALUES (0, [1.0, 0.0], 50), (1, [1.1, 0.0], 50), (2, [1.2, 0.0], 50), (3, [1.3, 0.0], 50), (4, [1.4, 0.0], 50), (5, [0.0, 2.0], 50), (6, [0.0, 2.1], 50), (7, [0.0, 2.2], 50), (8, [0.0, 2.3], 50), (9, [0.0, 2.4], 50);

SELECT 'Test "SELECT DISTINCT id" without and with rescoring';

WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT id
FROM tab
ORDER BY L2Distance(vec, reference_vec)
LIMIT 3
SETTINGS vector_search_with_rescoring = 0;

SELECT '-- Expect column "_distance" in EXPLAIN. Column "vec" is not expected for ReadFromMergeTree.';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT id
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 0)
WHERE (explain LIKE '%_distance%' OR explain LIKE '%vec%Array%') AND explain NOT LIKE '%L2Distance%'
LIMIT 1;

WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT id
FROM tab
ORDER BY L2Distance(vec, reference_vec)
LIMIT 3
SETTINGS vector_search_with_rescoring = 1;

SELECT '-- Dont expect column "_distance" in EXPLAIN.';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT id
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 1)
WHERE (explain LIKE '%_distance%');

SELECT '-- Test that rescoring evaluates the distance only for candidate rows.';

WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT id, throwIf(id = 4, 'Expected rescoring to skip non-candidate rows')
FROM tab
ORDER BY L2Distance(vec, reference_vec)
LIMIT 1
SETTINGS vector_search_with_rescoring = 1;

SELECT 'Test DISTINCT with the old analyzer';

SET enable_analyzer = 0;
WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT id
FROM tab
ORDER BY L2Distance(vec, reference_vec)
LIMIT 3
SETTINGS vector_search_with_rescoring = 0;

SELECT '-- Expect column "_distance" in EXPLAIN (the second pass substitution runs under the old analyzer too).';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT id
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 0)
WHERE (explain LIKE '%_distance%' OR explain LIKE '%vec%Array%') AND explain NOT LIKE '%L2Distance%'
LIMIT 1;
SET enable_analyzer = 1;

SELECT 'Test DISTINCT in the presence of a WHERE predicate';

SELECT '-- Filter selects the full part, so the optimization takes effect. Expect column "_distance" in EXPLAIN.';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT id
    FROM tab
    WHERE id >= 0
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 5
    SETTINGS vector_search_with_rescoring = 0)
WHERE (explain LIKE '%_distance%' OR explain LIKE '%vec%Array%') AND explain NOT LIKE '%L2Distance%'
LIMIT 1;

-- Output will be 5,6,7,8,9
WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT id
FROM tab
WHERE id >= 0
ORDER BY L2Distance(vec, reference_vec)
LIMIT 5
SETTINGS vector_search_with_rescoring = 0;

SELECT 'Test "SELECT DISTINCT id, vec" - SELECTing vec explicitly disables the optimization';

SELECT '-- Dont expect column "_distance" in EXPLAIN.';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT id, vec
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 0)
WHERE (explain LIKE '%_distance%');

SELECT 'Test "SELECT DISTINCT arraySum(vec)" - a computed projection over the vector column disables the substitution';

SELECT '-- Dont expect column "_distance" in EXPLAIN (the DISTINCT key still needs the vector column).';
SELECT trimLeft(explain) AS explain FROM (
    EXPLAIN header = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT arraySum(vec)
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 0)
WHERE (explain LIKE '%_distance%');

SELECT '-- The vector index is still used (only the _distance substitution is disabled, not the whole optimization).';
SELECT count() > 0 FROM (
    EXPLAIN indexes = 1
    WITH [0.0, 2.0] AS reference_vec
    SELECT DISTINCT arraySum(vec)
    FROM tab
    ORDER BY L2Distance(vec, reference_vec)
    LIMIT 3
    SETTINGS vector_search_with_rescoring = 0)
WHERE explain ILIKE '%Name: idx%';

-- arraySum([0.0,2.0]) = 2, arraySum([0.0,2.1]) = 2.1, arraySum([0.0,2.2]) = 2.2 (nearest three to [0,2])
WITH [0.0, 2.0] AS reference_vec
SELECT DISTINCT arraySum(vec)
FROM tab
ORDER BY L2Distance(vec, reference_vec)
LIMIT 3
SETTINGS vector_search_with_rescoring = 0;

DROP TABLE tab;

SELECT 'Correctness: indexed DISTINCT equals brute-force DISTINCT when duplicates collapse below LIMIT';

DROP TABLE IF EXISTS tab_idx;
DROP TABLE IF EXISTS tab_bruteforce;
CREATE TABLE tab_idx(id Int32, vec Array(Float32), INDEX idx vec TYPE vector_similarity('hnsw', 'L2Distance', 2) GRANULARITY 2) ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 3;
CREATE TABLE tab_bruteforce(id Int32, vec Array(Float32)) ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 3;
-- id = 1 occupies the three positions nearest to [1., 0.]
INSERT INTO tab_idx VALUES (1, [1.00, 0.0]), (1, [1.01, 0.0]), (1, [1.02, 0.0]), (2, [1.50, 0.0]), (3, [1.60, 0.0]), (4, [1.70, 0.0]), (5, [1.80, 0.0]), (6, [1.90, 0.0]), (7, [2.00, 0.0]), (8, [2.10, 0.0]), (9, [2.20, 0.0]), (10, [2.30, 0.0]);
INSERT INTO tab_bruteforce SELECT * FROM tab_idx;

SELECT 'Brute-force DISTINCT result';
SELECT DISTINCT id FROM tab_bruteforce ORDER BY L2Distance(vec, [1., 0.]) ASC LIMIT 3;
SELECT 'Indexed DISTINCT result without rescoring';
SELECT DISTINCT id FROM tab_idx ORDER BY L2Distance(vec, [1., 0.]) ASC LIMIT 3 SETTINGS vector_search_with_rescoring = 0, vector_search_index_fetch_multiplier = 100;
SELECT 'Indexed DISTINCT result with rescoring';
SELECT DISTINCT id FROM tab_idx ORDER BY L2Distance(vec, [1., 0.]) ASC LIMIT 3 SETTINGS vector_search_with_rescoring = 1, vector_search_index_fetch_multiplier = 100;

DROP TABLE tab_idx;
DROP TABLE tab_bruteforce;
