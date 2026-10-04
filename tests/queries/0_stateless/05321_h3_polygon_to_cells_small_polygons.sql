-- Tags: no-fasttest

-- The cells of a polygon, and their order, do not depend on how many collinear vertices describe it, with
-- `h3PolygonToCells` and with `h3PolygonToCellsWithContainment` in mode 0:
-- `split` divides every edge into 64 equal pieces. Coordinates are multiples of 2^-20 degrees, so the
-- new vertices lie exactly on the original edges.

DROP TABLE IF EXISTS shapes;
CREATE TABLE shapes (name String, mp Array(Array(Array(Tuple(Float64, Float64)))), resolutions Array(UInt8)) ENGINE = Memory;

INSERT INTO shapes
SELECT name, arrayMap(poly -> arrayMap(ring -> arrayMap(p -> (round(p.1 * 1048576) / 1048576, round(p.2 * 1048576) / 1048576), ring), poly), mp), resolutions
FROM
(
    SELECT 'issue_ring' AS name, [[arrayMap(i -> (-0.4 + 0.0001 * cos(i), 51.4 + 0.0001 * sin(i)), range(9))]] AS mp, [12, 13, 14] AS resolutions
    UNION ALL SELECT 'sf_triangle', [[[(-122.4089866999972145, 37.813318999983238), (-122.3544736999993603, 37.7198061999978478), (-122.4798767000009008, 37.8151571999998453)]]], [6, 7]
    UNION ALL SELECT 'square_hole', [[[(2.34, 48.84), (2.36, 48.84), (2.36, 48.86), (2.34, 48.86)], [(2.345, 48.845), (2.345, 48.855), (2.355, 48.855), (2.355, 48.845)]]], [8, 9]
    UNION ALL SELECT 'square_empty_holes', [[[(2.34, 48.84), (2.36, 48.84), (2.36, 48.86), (2.34, 48.86)], [], []]], [8, 9]
    UNION ALL SELECT 'multi_overlap', [[[(13.4, 52.5), (13.402, 52.5), (13.402, 52.502), (13.4, 52.502)]], [[(13.401, 52.501), (13.403, 52.501), (13.403, 52.503), (13.401, 52.503)]]], [9, 10, 11]
    UNION ALL SELECT 'c_shape', [[arrayMap(p -> (139.69 + p.1 * 0.0005, 35.68 + p.2 * 0.0005), [(0., 0.), (4., 0.), (4., 1.), (1., 1.), (1., 3.), (4., 3.), (4., 4.), (0., 4.)])]], [10, 11]
    UNION ALL SELECT 'near_pentagon', [[arrayMap(i -> (10.536199075467682 + 0.003 * cos(2 * pi() * i / 6), 64.70000012793486 + 0.0015 * sin(2 * pi() * i / 6)), range(6))]], [9, 10]
    UNION ALL SELECT 'one_vertex', [[[(-0.4, 51.4)]]], [10]
);

SELECT name, r, h3PolygonToCells(mp, r) = h3PolygonToCells(split, r) AS same, h3PolygonToCellsWithContainment(mp, r, 0) = h3PolygonToCells(split, r) AS same_mode_0, length(h3PolygonToCells(mp, r)) AS cells
FROM
(
    SELECT
        name,
        mp,
        arrayMap(poly -> arrayMap(ring -> arrayFlatten(arrayMap(i -> arrayMap(k -> (
            ring[i].1 + (ring[i % length(ring) + 1].1 - ring[i].1) * k / 64,
            ring[i].2 + (ring[i % length(ring) + 1].2 - ring[i].2) * k / 64), range(64)), range(1, length(ring) + 1))), poly), mp) AS split,
        arrayJoin(resolutions) AS r
    FROM shapes
)
ORDER BY name, r;

-- The same ring passed as a `Ring`.
SELECT r, h3PolygonToCells(mp[1][1], r) = h3PolygonToCells(split[1][1], r) AS same, h3PolygonToCellsWithContainment(mp[1][1], r, 0) = h3PolygonToCells(split[1][1], r) AS same_mode_0, length(h3PolygonToCells(mp[1][1], r)) AS cells
FROM
(
    SELECT
        mp,
        arrayMap(poly -> arrayMap(ring -> arrayFlatten(arrayMap(i -> arrayMap(k -> (
            ring[i].1 + (ring[i % length(ring) + 1].1 - ring[i].1) * k / 64,
            ring[i].2 + (ring[i % length(ring) + 1].2 - ring[i].2) * k / 64), range(64)), range(1, length(ring) + 1))), poly), mp) AS split,
        arrayJoin(resolutions) AS r
    FROM shapes
    WHERE name = 'issue_ring'
)
ORDER BY r;

DROP TABLE shapes;
