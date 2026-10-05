-- Text search functions over a Nullable value return NULL for a NULL row when the text index has a postprocessor,
-- exactly as without one: every `tp*` table has a `tn*` twin with the same index minus the postprocessor.

DROP TABLE IF EXISTS tp;
DROP TABLE IF EXISTS tn;
DROP TABLE IF EXISTS tp_lower;
DROP TABLE IF EXISTS tn_lower;
DROP TABLE IF EXISTS tp_ifnull;
DROP TABLE IF EXISTS tn_ifnull;
DROP TABLE IF EXISTS tp_nullif;
DROP TABLE IF EXISTS tn_nullif;
DROP TABLE IF EXISTS tp_nullif_str;
DROP TABLE IF EXISTS tp_lc;
DROP TABLE IF EXISTS tn_lc;
DROP TABLE IF EXISTS tp_fs;
DROP TABLE IF EXISTS tn_fs;
DROP TABLE IF EXISTS tp_map;
DROP TABLE IF EXISTS tn_map;
DROP TABLE IF EXISTS tp_partial;

SELECT '1. Nullable(String), no preprocessor.';

CREATE TABLE tp (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tn VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');

-- hasToken(s, 'HELLO') = 1 on `tp` only: the postprocessor rewrite ran.
SELECT 'tp', id, hasToken(s, 'HELLO'), hasAnyTokens(s, 'hello'), hasAllTokens(s, 'hello world'), hasPhrase(s, 'hello world') FROM tp ORDER BY id;
SELECT 'tn', id, hasToken(s, 'HELLO'), hasAnyTokens(s, 'hello'), hasAllTokens(s, 'hello world'), hasPhrase(s, 'hello world') FROM tn ORDER BY id;

SELECT 'tp NOT hasToken', arraySort(groupArray(id)) FROM tp WHERE NOT hasToken(s, 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tn NOT hasToken', arraySort(groupArray(id)) FROM tn WHERE NOT hasToken(s, 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tp NOT hasAnyTokens', arraySort(groupArray(id)) FROM tp WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tn NOT hasAnyTokens', arraySort(groupArray(id)) FROM tn WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tp NOT hasAllTokens', arraySort(groupArray(id)) FROM tp WHERE NOT hasAllTokens(s, 'hello world') SETTINGS use_skip_indexes = 0;
SELECT 'tn NOT hasAllTokens', arraySort(groupArray(id)) FROM tn WHERE NOT hasAllTokens(s, 'hello world') SETTINGS use_skip_indexes = 0;
SELECT 'tp NOT hasPhrase', arraySort(groupArray(id)) FROM tp WHERE NOT hasPhrase(s, 'hello world') SETTINGS use_skip_indexes = 0;
SELECT 'tn NOT hasPhrase', arraySort(groupArray(id)) FROM tn WHERE NOT hasPhrase(s, 'hello world') SETTINGS use_skip_indexes = 0;

SELECT 'tp NOT, direct read off', arraySort(groupArray(id)) FROM tp WHERE NOT hasAnyTokens(s, 'hello') SETTINGS query_plan_direct_read_from_text_index = 0;
SELECT 'tn NOT, direct read off', arraySort(groupArray(id)) FROM tn WHERE NOT hasAnyTokens(s, 'hello') SETTINGS query_plan_direct_read_from_text_index = 0;
SELECT 'tp IS NULL, direct read off', arraySort(groupArray(id)) FROM tp WHERE hasAnyTokens(s, 'hello') IS NULL SETTINGS query_plan_direct_read_from_text_index = 0;
SELECT 'tn IS NULL, direct read off', arraySort(groupArray(id)) FROM tn WHERE hasAnyTokens(s, 'hello') IS NULL SETTINGS query_plan_direct_read_from_text_index = 0;
-- The uppercase needle matches row 2 only through the postprocessor, so `tp merge()` also shows the rewrite ran.
SELECT 'tp merge()', arraySort(groupArray(id)) FROM merge(currentDatabase(), '^tp$') WHERE NOT hasAnyTokens(s, 'HELLO') SETTINGS query_plan_direct_read_from_text_index = 0;
SELECT 'tn merge()', arraySort(groupArray(id)) FROM merge(currentDatabase(), '^tn$') WHERE NOT hasAnyTokens(s, 'HELLO') SETTINGS query_plan_direct_read_from_text_index = 0;

SELECT '2. Nullable(String) with a preprocessor, applied to the haystack of an analyzed index.';

CREATE TABLE tp_lower (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(s), postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_lower (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tp_ifnull (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = ifNull(s, ''), postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_ifnull (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = ifNull(s, '')))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tp_nullif (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = nullIf(s, ''), postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_nullif (id UInt32, s Nullable(String), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = nullIf(s, '')))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp_lower VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tn_lower VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tp_ifnull VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tn_ifnull VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tp_nullif VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tn_nullif VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');

SELECT 'tp_lower', arraySort(groupArray(id)) FROM tp_lower WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;
SELECT 'tn_lower', arraySort(groupArray(id)) FROM tn_lower WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;
-- The preprocessor removes the NULL, so the NULL row is an ordinary non-match.
SELECT 'tp_ifnull', arraySort(groupArray(id)) FROM tp_ifnull WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;
SELECT 'tn_ifnull', arraySort(groupArray(id)) FROM tn_ifnull WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;
-- The preprocessor makes the empty row NULL too.
SELECT 'tp_nullif', arraySort(groupArray(id)) FROM tp_nullif WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;
SELECT 'tn_nullif', arraySort(groupArray(id)) FROM tn_nullif WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;

SELECT '3. String with a NULL-producing preprocessor: the predicate is not Nullable.';

CREATE TABLE tp_nullif_str (id UInt32, s String, INDEX tix s TYPE text(tokenizer = splitByNonAlpha, preprocessor = nullIf(s, ''), postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp_nullif_str VALUES (2, 'hello world'), (3, 'foo'), (4, '');
SELECT 'tp_nullif_str', arraySort(groupArray(id)) FROM tp_nullif_str WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 0;

SELECT '4. LowCardinality(Nullable(String)).';

CREATE TABLE tp_lc (id UInt32, s LowCardinality(Nullable(String)), INDEX tix s TYPE text(tokenizer = splitByNonAlpha, postprocessor = lower(s)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_lc (id UInt32, s LowCardinality(Nullable(String)), INDEX tix s TYPE text(tokenizer = splitByNonAlpha))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp_lc VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
INSERT INTO tn_lc VALUES (1, NULL), (2, 'hello world'), (3, 'foo'), (4, '');
SELECT 'tp_lc', id, hasAnyTokens(s, 'hello'), toTypeName(hasAnyTokens(s, 'hello')) FROM tp_lc ORDER BY id;
SELECT 'tn_lc', id, hasAnyTokens(s, 'hello'), toTypeName(hasAnyTokens(s, 'hello')) FROM tn_lc ORDER BY id;
SELECT 'tp_lc NOT', arraySort(groupArray(id)) FROM tp_lc WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tn_lc NOT', arraySort(groupArray(id)) FROM tn_lc WHERE NOT hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 0;

SELECT '5. Nullable(FixedString): the nested default of a NULL must not produce tokens.';

CREATE TABLE tp_fs (id UInt32, s Nullable(FixedString(6)), INDEX tix s TYPE text(tokenizer = ngrams(3), postprocessor = if(match(s, '[a-z]'), s, '#')))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_fs (id UInt32, s Nullable(FixedString(6)), INDEX tix s TYPE text(tokenizer = ngrams(3)))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp_fs VALUES (1, NULL), (2, 'hello');
INSERT INTO tn_fs VALUES (1, NULL), (2, 'hello');
SELECT 'tp_fs', id, hasAnyTokens(s, '123') FROM tp_fs ORDER BY id;
SELECT 'tn_fs', id, hasAnyTokens(s, '123') FROM tn_fs ORDER BY id;
SELECT 'tp_fs WHERE', arraySort(groupArray(id)) FROM tp_fs WHERE hasAnyTokens(s, '123') SETTINGS use_skip_indexes = 0;
SELECT 'tn_fs WHERE', arraySort(groupArray(id)) FROM tn_fs WHERE hasAnyTokens(s, '123') SETTINGS use_skip_indexes = 0;

SELECT '6. Map(String, Nullable(String)) element, index on mapValues.';

CREATE TABLE tp_map (id UInt32, m Map(String, Nullable(String)), INDEX tix mapValues(m) TYPE text(tokenizer = splitByNonAlpha, postprocessor = lower(mapValues(m))))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
CREATE TABLE tn_map (id UInt32, m Map(String, Nullable(String)), INDEX tix mapValues(m) TYPE text(tokenizer = splitByNonAlpha))
ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
INSERT INTO tp_map VALUES (1, map()), (2, map('k', 'Hello')), (3, map('k', NULL)), (4, map('j', 'x'));
INSERT INTO tn_map VALUES (1, map()), (2, map('k', 'Hello')), (3, map('k', NULL)), (4, map('j', 'x'));
SELECT 'tp_map', id, hasAnyTokens(m['k'], 'hello') FROM tp_map ORDER BY id;
SELECT 'tn_map', id, hasAnyTokens(m['k'], 'hello') FROM tn_map ORDER BY id;
SELECT 'tp_map NOT', arraySort(groupArray(id)) FROM tp_map WHERE NOT hasAnyTokens(m['k'], 'hello') SETTINGS use_skip_indexes = 0;
SELECT 'tn_map NOT', arraySort(groupArray(id)) FROM tn_map WHERE NOT hasAnyTokens(m['k'], 'hello') SETTINGS use_skip_indexes = 0;

SELECT '7. Direct read with a part where the index is not materialized.';

CREATE TABLE tp_partial (id UInt32, s Nullable(String)) ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 1;
SYSTEM STOP MERGES tp_partial;
INSERT INTO tp_partial VALUES (1, NULL), (2, 'Hello world'), (3, 'foo');
ALTER TABLE tp_partial ADD INDEX tix s TYPE text(tokenizer = splitByNonAlpha, postprocessor = lower(s));
INSERT INTO tp_partial SETTINGS materialize_skip_indexes_on_insert = 1 VALUES (11, NULL), (12, 'Hello'), (13, 'bar');
SELECT 'tp_partial', arraySort(groupArray(id)) FROM tp_partial WHERE hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 1;
SELECT 'tp_partial direct read', countIf(position(explain, '__text_index_') > 0) > 0
FROM (EXPLAIN actions = 1 SELECT id FROM tp_partial WHERE hasAnyTokens(s, 'hello') SETTINGS use_skip_indexes = 1, query_plan_direct_read_from_text_index = 1);

DROP TABLE tp;
DROP TABLE tn;
DROP TABLE tp_lower;
DROP TABLE tn_lower;
DROP TABLE tp_ifnull;
DROP TABLE tn_ifnull;
DROP TABLE tp_nullif;
DROP TABLE tn_nullif;
DROP TABLE tp_nullif_str;
DROP TABLE tp_lc;
DROP TABLE tn_lc;
DROP TABLE tp_fs;
DROP TABLE tn_fs;
DROP TABLE tp_map;
DROP TABLE tn_map;
DROP TABLE tp_partial;
