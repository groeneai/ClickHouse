#include <Functions/h3GeometryToCells.h>

#if USE_H3

#include <Columns/ColumnsNumber.h>
#include <Common/VectorWithMemoryTracking.h>
#include <IO/WriteHelpers.h>

#include <algorithm>
#include <array>

#include <constants.h>
#include <h3api.h>
/// H3's polygon internals: private to the library, and not declared for C++. The candidate walk below
/// is H3's own, so it needs the same primitives.
extern "C"
{
#include <bbox.h>
#include <coordijk.h>
#include <h3Index.h>
#include <iterators.h>
#include <polyfill.h>
#include <polygon.h>
}

static constexpr size_t MAX_ARRAY_SIZE = 1 << 30;

namespace DB
{
namespace ErrorCodes
{
    extern const int ARGUMENT_OUT_OF_BOUND;
    extern const int TOO_LARGE_ARRAY_SIZE;
    extern const int INCORRECT_DATA;
}

namespace
{

/// Number of cells the size estimate aims to fit in the polygon's bounding box, `MAX_SIZE_CELL_THRESHOLD`
/// in H3's `polyfill.c`.
constexpr double MAX_SIZE_CELL_THRESHOLD = 10;
/// The coordinate range `latLngToCell` accepts, `VALID_RANGE_BBOX` in H3's `polyfill.c`.
constexpr BBox VALID_RANGE_BBOX = {M_PI_2, -M_PI_2, M_PI, -M_PI};
constexpr double MAX_FAST_PATH_LATITUDE = 85 * M_PI / 180;

SphericalPointInRadians toRadianPoint(const SphericalPoint & degree_point)
{
    Float64 lon = get<0>(degree_point) * M_PI / 180.0;
    Float64 lat = get<1>(degree_point) * M_PI / 180.0;
    return SphericalPointInRadians(lon, lat);
}

/// A vertex off the sphere makes H3's bounding box, and the area it derives from it, meaningless: the size
/// estimate then counts every cell of a polygon covering much of the globe, at the requested resolution.
/// NaN and infinity are already rejected when the geometry is converted; this is the range they leave open.
void validateCoordinates(const SphericalPoint & degree_point, std::string_view function_name)
{
    const Float64 lon = get<0>(degree_point);
    const Float64 lat = get<1>(degree_point);

    if (!std::isfinite(lon) || !std::isfinite(lat) || std::abs(lon) > 180.0 || std::abs(lat) > 90.0)
        throw Exception(
            ErrorCodes::ARGUMENT_OUT_OF_BOUND,
            "The vertex ({}, {}) of the geometry passed to function {} is out of bounds "
            "(longitude must be -180..180 and latitude -90..90 degrees)",
            toString(lon),
            toString(lat),
            function_name);
}

void checkH3Error(H3Error error, std::string_view function_name)
{
    if (error != E_SUCCESS)
        throw Exception(ErrorCodes::INCORRECT_DATA,
            "Failed to compute H3 polygon to cells in function {}: {}",
            function_name, describeH3Error(error));
}

/// The next cell in the sequence of all cells to check, `nextCell` in H3's `polyfill.c`.
H3Index nextCellInSequence(H3Index cell)
{
    int res = H3_GET_RESOLUTION(cell);
    while (true)
    {
        /// A base cell has no parent, so continue with the next one.
        if (res == 0)
            return baseCellNumToCell(H3_GET_BASE_CELL(cell) + 1);

        H3Index parent = cell;
        H3_SET_RESOLUTION(parent, res - 1);
        H3_SET_INDEX_DIGIT(parent, res, H3_DIGIT_MASK);

        /// Not the last sibling: continue with the next one, skipping the missing child of a pentagon.
        const int digit = static_cast<int>(H3_GET_INDEX_DIGIT(cell, res));
        if (digit < INVALID_DIGIT - 1)
        {
            H3_SET_INDEX_DIGIT(cell, res, digit + ((isPentagon(parent) && digit == CENTER_DIGIT) ? 2 : 1));
            return cell;
        }

        --res;
        cell = parent;
    }
}

/// The candidate walk of `iterStepPolygonCompact` in H3's `polyfill.c`, over the same H3 primitives, with a
/// cancellation checkpoint per candidate. H3 wraps the walk in one call, which can reject millions of
/// candidates before it returns a cell, leaving no place to observe `max_execution_time` or `KILL QUERY`.
/// Keep in sync with H3 when the submodule is bumped.
class CompactCellScan
{
public:
    CompactCellScan(
        const GeoPolygon * polygon_,
        const BBox * bboxes_,
        int res_,
        UInt32 flags_,
        std::string_view function_name_,
        CancellationBudget & budget_,
        size_t units_per_candidate_)
        : polygon(polygon_)
        , bboxes(bboxes_)
        , res(res_)
        , mode(static_cast<ContainmentMode>(FLAG_GET_CONTAINMENT_MODE(flags_)))
        , function_name(function_name_)
        , budget(budget_)
        , units_per_candidate(units_per_candidate_)
    {
    }

    /// The next cell covering the polygon, coarser than the target resolution when all of its children are
    /// covered, or `H3_NULL` once the polygon is exhausted.
    H3Index next()
    {
        if (cell == H3_NULL)
            return H3_NULL;

        /// The first candidate is the cell the walk starts at; after that, the one after the last output.
        if (started)
            cell = nextCellInSequence(cell);
        else
            started = true;

        /// Nothing covers a polygon without vertices.
        if (polygon->geoloop.numVerts == 0)
            cell = H3_NULL;

        while (cell)
        {
            budget.chargeUnits(units_per_candidate);

            const int cell_res = H3_GET_RESOLUTION(cell);

            /// Target resolution: a fine-grained check.
            if (cell_res == res && matchesContainmentMode(cell, cell_res))
                return cell;

            /// Coarser cell: check the bounding box of all of its children.
            if (cell_res < res)
            {
                BBox bbox;
                checkH3Error(cellToBBox(cell, &bbox, true), function_name);

                if (bboxOverlapsBBox(&bboxes[0], &bbox))
                {
                    /// Quick check for possible containment, then the expensive one on the polygon.
                    if (bboxContainsBBox(&bboxes[0], &bbox))
                    {
                        CellBoundary bbox_boundary = bboxToCellBoundary(&bbox);
                        if (cellBoundaryInsidePolygon(polygon, bboxes, &bbox_boundary, &bbox))
                            return cell;
                    }

                    /// An intersecting bounding box means every child has to be tested.
                    H3Index child = H3_NULL;
                    checkH3Error(cellToCenterChild(cell, cell_res + 1, &child), function_name);
                    cell = child;
                    continue;
                }
            }

            cell = nextCellInSequence(cell);
        }

        return H3_NULL;
    }

private:
    bool matchesContainmentMode(H3Index candidate, int candidate_res)
    {
        if (mode == CONTAINMENT_CENTER || mode == CONTAINMENT_OVERLAPPING || mode == CONTAINMENT_OVERLAPPING_BBOX)
        {
            LatLng center;
            checkH3Error(cellToLatLng(candidate, &center), function_name);
            if (pointInsidePolygon(polygon, bboxes, &center))
                return true;
        }

        if (mode == CONTAINMENT_OVERLAPPING || mode == CONTAINMENT_OVERLAPPING_BBOX)
        {
            /// The polygon may be wholly contained by the cell, which its first vertex tells us. That
            /// vertex exists because the caller rejects a polygon without vertices.
            const LatLng first_vertex = polygon->geoloop.verts[0];
            /// Out-of-range coordinates yield false positives with `latLngToCell`.
            if (bboxContains(&VALID_RANGE_BBOX, &first_vertex))
            {
                H3Index polygon_cell = H3_NULL;
                checkH3Error(latLngToCell(&first_vertex, candidate_res, &polygon_cell), function_name);
                if (polygon_cell == candidate)
                    return true;
            }
        }

        if (mode == CONTAINMENT_FULL || mode == CONTAINMENT_OVERLAPPING || mode == CONTAINMENT_OVERLAPPING_BBOX)
        {
            CellBoundary boundary;
            checkH3Error(cellToBoundary(candidate, &boundary), function_name);
            BBox bbox;
            checkH3Error(cellToBBox(candidate, &bbox, false), function_name);

            if ((mode == CONTAINMENT_FULL || mode == CONTAINMENT_OVERLAPPING_BBOX)
                && cellBoundaryInsidePolygon(polygon, bboxes, &boundary, &bbox))
                return true;

            /// Center point inclusion was checked above, so overlap only needs line intersection.
            if ((mode == CONTAINMENT_OVERLAPPING || mode == CONTAINMENT_OVERLAPPING_BBOX)
                && cellBoundaryCrossesPolygon(polygon, bboxes, &boundary, &bbox))
                return true;
        }

        if (mode == CONTAINMENT_OVERLAPPING_BBOX)
        {
            /// A bounding box containing all the cell's children, so that this works for the size estimate.
            BBox bbox;
            checkH3Error(cellToBBox(candidate, &bbox, true), function_name);

            if (bboxOverlapsBBox(&bboxes[0], &bbox))
            {
                CellBoundary bbox_boundary = bboxToCellBoundary(&bbox);
                if (bboxContainsBBox(&bbox, &bboxes[0])
                    || pointInsidePolygon(polygon, bboxes, &bbox_boundary.verts[0])
                    || cellBoundaryCrossesPolygon(polygon, bboxes, &bbox_boundary, &bbox))
                    return true;
            }
        }

        return false;
    }

    const GeoPolygon * polygon;
    const BBox * bboxes;
    const int res;
    const ContainmentMode mode;
    const std::string_view function_name;
    CancellationBudget & budget;
    const size_t units_per_candidate;

    H3Index cell = baseCellNumToCell(0);
    bool started = false;
};

/// `maxPolygonToCellsSizeExperimental` in H3's `polyfill.c`, over the walk above so that it is checkpointed
/// too: a rough upper bound from the polygon's bounding box, counted at a resolution coarse enough for the
/// box to hold about `MAX_SIZE_CELL_THRESHOLD` cells.
Int64 estimateCellCount(
    const GeoPolygon * polygon,
    const BBox * bboxes,
    int res,
    std::string_view function_name,
    CancellationBudget & budget,
    size_t units_per_candidate)
{
    if (polygon->geoloop.numVerts == 0)
        return 0;

    /// A (very) rough area of the polygon's bounding box.
    const BBox & polygon_bbox = bboxes[0];
    const double polygon_bbox_area_km2 = bboxHeightRads(&polygon_bbox) * bboxWidthRads(&polygon_bbox)
        / cos(fmin(fabs(polygon_bbox.north), fabs(polygon_bbox.south))) * EARTH_RADIUS_KM * EARTH_RADIUS_KM;

    /// All this needs is a general order of magnitude of the number of cells that would fit.
    int estimate_res = res;
    while (estimate_res > 0)
    {
        double average_cell_area_km2 = 0;
        checkH3Error(getHexagonAreaAvgKm2(estimate_res - 1, &average_cell_area_km2), function_name);
        if (polygon_bbox_area_km2 / average_cell_area_km2 <= MAX_SIZE_CELL_THRESHOLD)
            break;
        --estimate_res;
    }

    /// Ignore the requested containment mode and use the faster overlapping-bbox one.
    CompactCellScan scan(
        polygon, bboxes, estimate_res, CONTAINMENT_OVERLAPPING_BBOX, function_name, budget, units_per_candidate);

    Int64 estimate = 0;
    while (H3Index cell = scan.next())
    {
        Int64 children_size = 0;
        checkH3Error(cellToChildrenSize(cell, res, &children_size), function_name);
        estimate += children_size;
    }

    return estimate;
}

/// `_hexRadiusKm` of the first pentagon in H3's `bbox.c`: `lineHexEstimate` samples an edge every twice this
/// distance. Keep in sync with H3 when the submodule is bumped.
double pentagonRadiusKm(int res, std::string_view function_name)
{
    static const std::array<double, MAX_H3_RES + 1> radii = [&]
    {
        std::array<double, MAX_H3_RES + 1> result{};
        for (int r = 0; r <= MAX_H3_RES; ++r)
        {
            std::array<H3Index, 12> pentagons{};
            checkH3Error(getPentagons(r, pentagons.data()), function_name);
            LatLng center;
            checkH3Error(cellToLatLng(pentagons[0], &center), function_name);
            CellBoundary boundary;
            checkH3Error(cellToBoundary(pentagons[0], &boundary), function_name);
            result[r] = greatCircleDistanceKm(&center, &boundary.verts[0]);
        }
        return result;
    }();
    return radii[res];
}

/// Appends the cells of a small hole-free polygon using H3's `polygonToCells` instead of the walk. Returns false,
/// having appended nothing, when the work bound below does not hold or `polygonToCells` cannot handle the polygon.
bool tryAppendSmallPolygonCells(
    const GeoPolygon * polygon,
    const VectorWithMemoryTracking<BBox> & bboxes,
    int res,
    size_t vertex_count,
    size_t row_start_offset,
    std::string_view function_name,
    CancellationBudget & budget,
    ColumnUInt64 & dst_data)
{
    const BBox & bbox = bboxes[0];
    if (polygon->geoloop.numVerts == 0 || polygon->numHoles != 0 || bboxIsTransmeridian(&bbox)
        || bbox.east - bbox.west > M_PI || std::max(std::abs(bbox.north), std::abs(bbox.south)) > MAX_FAST_PATH_LATITUDE
        || vertex_count > 4 * (static_cast<size_t>(res) + 2))
        return false;

    constexpr size_t max_units = CancellationBudget::units_per_check;
    int64_t size = 0;
    const H3Error size_error = maxPolygonToCellsSize(polygon, res, CONTAINMENT_CENTER, &size);
    if (size_error == E_FAILED)
        return false;
    checkH3Error(size_error, function_name);
    if (size <= 0 || static_cast<size_t>(size) > max_units)
        return false;
    const size_t cells_bound = static_cast<size_t>(size);

    const double sample_spacing_km = 2 * pentagonRadiusKm(res, function_name);
    const GeoLoop & loop = polygon->geoloop;
    size_t edge_samples = 0;
    for (int i = 0; i < loop.numVerts; ++i)
    {
        const LatLng & to = loop.verts[i + 1 == loop.numVerts ? 0 : i + 1];
        const double samples = std::ceil(greatCircleDistanceKm(&loop.verts[i], &to) / sample_spacing_km);
        if (!(samples <= static_cast<double>(max_units))) /// Also NaN.
            return false;
        edge_samples += std::max<size_t>(1, static_cast<size_t>(samples));
    }
    if (edge_samples > max_units)
        return false;

    /// An upper bound on the hash probes and point-in-polygon edge steps of `polygonToCells`, so that it never
    /// runs for more than one checkpoint interval.
    const size_t units = edge_samples * (cells_bound + 1) + 16 * cells_bound * (cells_bound + 2 + vertex_count);
    if (units > max_units)
        return false;
    budget.chargeUnits(units);

    VectorWithMemoryTracking<H3Index> cells(cells_bound, H3_NULL);
    const H3Error fill_error = polygonToCells(polygon, res, CONTAINMENT_CENTER, cells.data());
    if (fill_error == E_FAILED)
        return false;
    checkH3Error(fill_error, function_name);

    /// The walk returns cells in ascending order.
    std::erase(cells, H3_NULL);
    std::sort(cells.begin(), cells.end());

    const size_t row_size = dst_data.size() - row_start_offset + cells.size();
    if (row_size > MAX_ARRAY_SIZE)
        throw Exception(ErrorCodes::TOO_LARGE_ARRAY_SIZE,
            "The result of function {} (array of {} elements) will be too large with resolution = {}",
            function_name, row_size, toString(res));

    dst_data.getData().insert(cells.begin(), cells.end());
    return true;
}

LatLng toH3LatLng(const SphericalPointInRadians & point)
{
    LatLng result;
    result.lat = point.get<1>();
    result.lng = point.get<0>();
    return result;
}

class GeoPolygonContainer
{
private:
    VectorWithMemoryTracking<LatLng> mainLoopVerts;
    VectorWithMemoryTracking<VectorWithMemoryTracking<LatLng>> holeVerts;

    mutable GeoLoop mutableMainLoop{};
    mutable GeoPolygon mutablePolygon{};
    mutable VectorWithMemoryTracking<GeoLoop> mutableHoles;

public:
    explicit GeoPolygonContainer(VectorWithMemoryTracking<LatLng> && mainLoop,
                                 VectorWithMemoryTracking<VectorWithMemoryTracking<LatLng>> && holes = {})
        : mainLoopVerts(std::move(mainLoop)), holeVerts(std::move(holes)) {}

    const GeoPolygon * unwrap() const
    {
        mutableMainLoop = {static_cast<int>(mainLoopVerts.size()),
                           const_cast<LatLng*>(mainLoopVerts.data())};

        mutableHoles.clear();
        mutableHoles.reserve(holeVerts.size());
        for (const auto & hole : holeVerts)
            mutableHoles.push_back({static_cast<int>(hole.size()),
                                    const_cast<LatLng*>(hole.data())});

        mutablePolygon = {mutableMainLoop,
                          static_cast<int>(mutableHoles.size()),
                          mutableHoles.data()};
        return &mutablePolygon;
    }
};

}

void appendH3Cells(
    const SphericalMultiPolygon & multi_polygon,
    UInt8 resolution,
    UInt32 flags,
    std::string_view function_name,
    CancellationBudget & budget,
    ColumnUInt64 & dst_data)
{
    const size_t row_start_offset = dst_data.size();
    for (const auto & polygon : multi_polygon)
    {
        VectorWithMemoryTracking<LatLng> exterior;
        exterior.reserve(polygon.outer().size());
        for (const auto & point : polygon.outer())
        {
            validateCoordinates(point, function_name);
            exterior.push_back(toH3LatLng(toRadianPoint(point)));
        }

        size_t vertex_count = exterior.size();

        VectorWithMemoryTracking<VectorWithMemoryTracking<LatLng>> holes;
        holes.reserve(polygon.inners().size());
        for (const auto & inner : polygon.inners())
        {
            VectorWithMemoryTracking<LatLng> hole;
            hole.reserve(inner.size());
            for (const auto & point : inner)
            {
                validateCoordinates(point, function_name);
                hole.push_back(toH3LatLng(toRadianPoint(point)));
            }
            vertex_count += hole.size();
            holes.emplace_back(std::move(hole));
        }

        GeoPolygonContainer polygon_wrapper(std::move(exterior), std::move(holes));
        const GeoPolygon * geo_polygon = polygon_wrapper.unwrap();

        checkH3Error(validatePolygonFlags(flags), function_name);

        /// Bounding boxes of the polygon and of each of its holes, which every candidate check needs.
        VectorWithMemoryTracking<BBox> bboxes(geo_polygon->numHoles + 1);
        bboxesFromGeoPolygon(geo_polygon, bboxes.data());

        if (flags == CONTAINMENT_CENTER
            && tryAppendSmallPolygonCells(geo_polygon, bboxes, resolution, vertex_count, row_start_offset, function_name, budget, dst_data))
            continue;

        /// A candidate at the target resolution is tested against every vertex of the polygon.
        const size_t units_per_candidate = 1 + vertex_count;

        /// Cheap bbox-based estimate: rejects a polygon that cannot fit before enumerating it. Rough in
        /// both directions, hence the exact check per cell below.
        const size_t row_size_so_far = dst_data.size() - row_start_offset;
        const size_t estimate = static_cast<size_t>(
            estimateCellCount(geo_polygon, bboxes.data(), resolution, function_name, budget, units_per_candidate));
        if (estimate > MAX_ARRAY_SIZE || row_size_so_far + estimate > MAX_ARRAY_SIZE)
            throw Exception(ErrorCodes::TOO_LARGE_ARRAY_SIZE,
                "The result of function {} (array of {} elements) will be too large with resolution = {}",
                function_name, row_size_so_far + estimate, toString(resolution));

        CompactCellScan scan(
            geo_polygon, bboxes.data(), resolution, flags, function_name, budget, units_per_candidate);

        while (H3Index compact_cell = scan.next())
        {
            /// A cell coarser than the requested resolution stands for all of its children.
            IterCellsChildren children = iterInitParent(compact_cell, resolution);
            for (; children.h; iterStepChild(&children))
            {
                /// The candidates rejected on the way here are charged by the walk; a child of a covered
                /// cell only costs the index arithmetic that produced it.
                budget.charge(sizeof(H3Index));

                if (dst_data.size() - row_start_offset >= MAX_ARRAY_SIZE)
                    throw Exception(ErrorCodes::TOO_LARGE_ARRAY_SIZE,
                        "The result of function {} (array of {} elements) will be too large with resolution = {}",
                        function_name, dst_data.size() - row_start_offset + 1, toString(resolution));

                /// `PODArray::push_back` grows geometrically; `IColumn::reserve` would size it exactly.
                dst_data.getData().push_back(children.h);
            }
        }
    }
}

}

#endif
