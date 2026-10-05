-- `compatibility` with a version before 24.1 keeps `optimize_injective_functions_in_group_by` enabled:
-- the default query analysis of those versions removed injective functions from `GROUP BY` keys anyway.
SET optimize_injective_functions_in_group_by = DEFAULT;
SET print_pretty_type_names = DEFAULT;
SET group_by_use_nulls = 0;
SET compatibility = '23.9';
-- `print_pretty_type_names` is another 24.1 change: it is still reverted, so the walk ran.
SELECT name, value FROM system.settings
WHERE name IN ('optimize_injective_functions_in_group_by', 'print_pretty_type_names') ORDER BY name;
SELECT count() FROM (EXPLAIN actions = 1
    SELECT toString(toYYYYMM(toDate('2020-01-01') + number)) AS k FROM numbers(100) GROUP BY k)
WHERE explain ILIKE '%Keys: toString(%';
-- An explicit value still wins (also shows the predicate above can match).
SELECT count() FROM (EXPLAIN actions = 1
    SELECT toString(toYYYYMM(toDate('2020-01-01') + number)) AS k FROM numbers(100) GROUP BY k
    SETTINGS optimize_injective_functions_in_group_by = 0)
WHERE explain ILIKE '%Keys: toString(%';
SET compatibility = '23.12';
SELECT value FROM system.settings WHERE name = 'optimize_injective_functions_in_group_by';
