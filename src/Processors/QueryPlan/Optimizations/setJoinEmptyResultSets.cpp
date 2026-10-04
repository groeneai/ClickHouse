#include <Processors/QueryPlan/Optimizations/Optimizations.h>
#include <Processors/QueryPlan/CreateSetAndFilterOnTheFlyStep.h>
#include <Processors/QueryPlan/ExpressionStep.h>
#include <Processors/QueryPlan/FilterStep.h>
#include <Processors/QueryPlan/IEJoinStep.h>
#include <Processors/QueryPlan/JoinStep.h>
#include <Processors/QueryPlan/SortingStep.h>
#include <Processors/QueryPlan/SourceStepWithFilter.h>
#include <Processors/Transforms/FilterTransform.h>
#include <Interpreters/IJoin.h>
#include <Interpreters/PreparedSets.h>
#include <Interpreters/TableJoin.h>
#include <Storages/IStorage.h>
#include <Storages/SelectQueryInfo.h>
#include <Storages/StorageSnapshot.h>
#include <Common/typeid_cast.h>

namespace DB::QueryPlanOptimizations
{

namespace
{

/// Whether an empty left / right input makes a join of this kind return no rows.
bool leftInputEmptiesJoin(JoinKind kind) { return isInnerOrLeft(kind) || isCrossOrComma(kind); }
bool rightInputEmptiesJoin(JoinKind kind) { return isInnerOrRight(kind) || isCrossOrComma(kind); }

void collectSets(const QueryPlan::Node & node, std::vector<FutureSetPtr> & sets);

/// For a join node: appends the sets of the inputs whose emptiness empties the join. Returns false if `node` is not a join.
bool collectJoinInputSets(const QueryPlan::Node & node, std::vector<FutureSetPtr> & sets)
{
    if (node.children.size() != 2)
        return false;

    const auto * join = typeid_cast<const JoinStep *>(node.step.get());
    const auto * ie_join = typeid_cast<const IEJoinStep *>(node.step.get());
    if (!join && !ie_join)
        return false;

    const JoinKind kind = join ? join->getJoin()->getTableJoin().kind() : ie_join->getQueryKind();
    const QueryPlan::Node * left = node.children[0];
    const QueryPlan::Node * right = node.children[1];
    /// With `swap_streams` the pipelines are swapped at execution and the TableJoin is already swapped.
    if (join && join->swap_streams)
        std::swap(left, right);

    if (leftInputEmptiesJoin(kind))
        collectSets(*left, sets);
    if (rightInputEmptiesJoin(kind))
        collectSets(*right, sets);
    return true;
}

/// Appends the sets of `in` conjuncts such that `node` outputs no rows when one of them is empty.
void collectSets(const QueryPlan::Node & node, std::vector<FutureSetPtr> & sets)
{
    auto append = [&sets](std::vector<FutureSetPtr> more) { std::ranges::move(more, std::back_inserter(sets)); };
    /// Each step walked emits only rows derived from its input rows, so an empty input empties its output.
    const auto * step = node.step.get();
    if (const auto * filter = typeid_cast<const FilterStep *>(step))
        append(getSetsRequiredByFilter(filter->getExpression(), filter->getFilterColumnName()));
    else if (const auto * source = dynamic_cast<const SourceStepWithFilter *>(step))
    {
        /// A remote source evaluates its PREWHERE on other servers, each with its own set.
        const auto prewhere = source->getPrewhereInfo();
        const auto & snapshot = source->getStorageSnapshot();
        if (prewhere && prewhere->need_filter && snapshot && !snapshot->storage.isRemote())
            append(getSetsRequiredByFilter(prewhere->prewhere_actions, prewhere->prewhere_column_name));
        return;
    }
    else if (collectJoinInputSets(node, sets))
        return;
    else if (const auto * filled_join = typeid_cast<const FilledJoinStep *>(step))
    {
        /// A RIGHT or FULL filled join also emits the stored rows nobody matched.
        if (!leftInputEmptiesJoin(filled_join->getJoin()->getTableJoin().kind()))
            return;
    }
    else if (!typeid_cast<const ExpressionStep *>(step) && !typeid_cast<const SortingStep *>(step)
        && !typeid_cast<const CreateSetAndFilterOnTheFlyStep *>(step))
        return;

    if (node.children.size() == 1)
        collectSets(*node.children.front(), sets);
}

}

void setJoinEmptyResultSets(QueryPlan::Node & node)
{
    std::vector<FutureSetPtr> sets;
    if (!collectJoinInputSets(node, sets))
        return;

    if (auto * join_step = typeid_cast<JoinStep *>(node.step.get()))
        join_step->setEmptyResultSets(std::move(sets));
    else if (auto * ie_join_step = typeid_cast<IEJoinStep *>(node.step.get()))
        ie_join_step->setEmptyResultSets(std::move(sets));
}

}
