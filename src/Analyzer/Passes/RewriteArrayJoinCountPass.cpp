#include <Analyzer/Passes/RewriteArrayJoinCountPass.h>

#include <Analyzer/ArrayJoinNode.h>
#include <Analyzer/ColumnNode.h>
#include <Analyzer/ConstantNode.h>
#include <Analyzer/FunctionNode.h>
#include <Analyzer/InDepthQueryTreeVisitor.h>
#include <Analyzer/QueryNode.h>
#include <Analyzer/TableNode.h>
#include <Analyzer/Utils.h>

#include <Core/Settings.h>

#include <DataTypes/DataTypesNumber.h>

#include <Interpreters/ArrayJoinAction.h>
#include <Interpreters/Context.h>

#include <Poco/String.h>

namespace DB
{

namespace Setting
{
    extern const SettingsBool empty_result_for_aggregation_by_empty_set;
    extern const SettingsBool enable_unaligned_array_join;
    extern const SettingsBool optimize_functions_to_subcolumns;
}

namespace
{

/// Returns true when the aggregate is one of the following forms: `count()`, `count(*)`, `count(1)`, `count('x')`.
/// count(column) and count(NULL) are excluded and return false
bool isPlainRowCount(const FunctionNode & function_node)
{
    if (!function_node.isAggregateFunction() || function_node.isWindowFunction())
        return false;
    if (Poco::toLower(function_node.getFunctionName()) != "count")
        return false;

    for (const auto & argument : function_node.getArguments().getNodes())
    {
        const auto * constant_node = argument->as<ConstantNode>();
        if (!constant_node || constant_node->getValue().isNull())
            return false;
    }
    return true;
}

class RewriteArrayJoinCountVisitor : public InDepthQueryTreeVisitorWithContext<RewriteArrayJoinCountVisitor>
{
public:
    using Base = InDepthQueryTreeVisitorWithContext<RewriteArrayJoinCountVisitor>;
    using Base::Base;

    void enterImpl(QueryTreeNodePtr & node)
    {
        const auto & settings = getSettings();
        if (!settings[Setting::optimize_functions_to_subcolumns])
            return;
        /// With unaligned array join, the row count is the maximum length across joined arrays,
        if (settings[Setting::enable_unaligned_array_join])
            return;
        /// ARRAY JOIN over only-empty arrays produces no rows, so with this setting the query
        /// returns an empty result; the rewritten sum() over the base rows would instead return a
        /// single 0. Decline to keep the empty-set semantics.
        if (settings[Setting::empty_result_for_aggregation_by_empty_set])
            return;

        auto * query_node = node->as<QueryNode>();
        if (!query_node)
            return;

        /// Only a bare `SELECT count() FROM ... ARRAY JOIN ...`
        if (query_node->hasWith() || query_node->hasPrewhere() || query_node->hasWhere()
            || query_node->hasGroupBy() || query_node->hasHaving() || query_node->hasWindow()
            || query_node->hasQualify() || query_node->hasOrderBy() || query_node->hasInterpolate()
            || query_node->hasLimitByLimit() || query_node->hasLimitByOffset() || query_node->hasLimitBy()
            || query_node->hasLimit() || query_node->hasOffset() || query_node->isDistinct())
            return;

        /// Exactly one projection column, which is a plain count().
        auto & projection_nodes = query_node->getProjection().getNodes();
        if (projection_nodes.size() != 1)
            return;

        auto * count_function = projection_nodes[0]->as<FunctionNode>();
        if (!count_function || !isPlainRowCount(*count_function))
            return;

        /// The join tree must be a run of one or more ARRAY JOIN keywords bottoming at a table.
        /// A chain `ARRAY JOIN c0 ARRAY JOIN c1` nests as ArrayJoinNode(c1) over ArrayJoinNode(c0) over
        /// the table, so the outer-most node is the join-tree root and each getTableExpression() step
        /// descends one keyword. Collect the chain and the bottom table.
        std::vector<const ArrayJoinNode *> array_join_chain;
        QueryTreeNodePtr * join_tree_leaf = &query_node->getJoinTree();
        while (auto * array_join_node = (*join_tree_leaf)->as<ArrayJoinNode>())
        {
            array_join_chain.push_back(array_join_node);
            join_tree_leaf = &array_join_node->getTableExpression();
        }

        if (array_join_chain.empty())
            return;

        auto * bottom_table = (*join_tree_leaf)->as<TableNode>();
        if (!bottom_table)
            return;

        /// The number of rows produced by a chain of ARRAY JOINs is the product of the per-keyword
        /// array lengths (a cartesian product). Build that product across the chain; each keyword
        /// contributes length(<its array column>), and a LEFT keyword wraps it in greatest(., 1).
        QueryTreeNodePtr product_expression;

        for (const auto * array_join_node : array_join_chain)
        {
            /// Exactly one surviving joined expression
            const auto & join_expressions = array_join_node->getJoinExpressions().getNodes();
            if (join_expressions.size() != 1)
                return;

            /// The joined expression is an outer alias ColumnNode whose child expression holds the actual
            /// joined-over expression. Only rewrite when that inner expression is a plain physical Array/Map
            /// column of the bottom table (a computed expression is left untouched).
            auto * join_alias_column = join_expressions[0]->as<ColumnNode>();
            if (!join_alias_column || !join_alias_column->hasExpression())
                return;

            auto * physical_column = join_alias_column->getExpression()->as<ColumnNode>();
            if (!physical_column || physical_column->hasExpression())
                return;

            if (physical_column->getColumnSourceOrNull().get() != bottom_table)
                return;

            if (!getArrayJoinDataType(physical_column->getColumnType()))
                return;

            /// Build length(<physical array/map column>). The subsequent FunctionToSubcolumnsPass folds this
            /// into the lightweight <column>.size0 subcolumn so only offsets are read from storage.
            auto length_function = std::make_shared<FunctionNode>("length");
            length_function->getArguments().getNodes().push_back(join_alias_column->getExpression());
            resolveOrdinaryFunctionNodeByName(*length_function, "length", getContext());

            QueryTreeNodePtr factor_expression = std::move(length_function);

            /// LEFT ARRAY JOIN emits one row for an empty array, so an empty array contributes 1, not 0.
            /// Only the LEFT keyword's own factor is wrapped; INNER keywords keep the plain length.
            if (array_join_node->isLeft())
            {
                auto greatest_function = std::make_shared<FunctionNode>("greatest");
                greatest_function->getArguments().getNodes().push_back(std::move(factor_expression));
                greatest_function->getArguments().getNodes().push_back(std::make_shared<ConstantNode>(static_cast<UInt64>(1)));
                resolveOrdinaryFunctionNodeByName(*greatest_function, "greatest", getContext());
                factor_expression = std::move(greatest_function);
            }

            if (!product_expression)
            {
                product_expression = std::move(factor_expression);
            }
            else
            {
                auto multiply_function = std::make_shared<FunctionNode>("multiply");
                multiply_function->getArguments().getNodes().push_back(std::move(product_expression));
                multiply_function->getArguments().getNodes().push_back(std::move(factor_expression));
                resolveOrdinaryFunctionNodeByName(*multiply_function, "multiply", getContext());
                product_expression = std::move(multiply_function);
            }
        }

        /// count() over the ARRAY JOIN(s) becomes sum() over the per-row product of lengths.
        auto sum_function = std::make_shared<FunctionNode>("sum");
        sum_function->getArguments().getNodes().push_back(std::move(product_expression));
        resolveAggregateFunctionNodeByName(*sum_function, "sum");

        QueryTreeNodePtr new_projection_node = std::move(sum_function);

        /// Keep the projection column type identical to the original count() (UInt64) so the projection
        /// column metadata (name and type) stays valid without touching projection_columns.
        const auto & count_result_type = count_function->getResultType();
        if (!new_projection_node->getResultType()->equals(*count_result_type))
            new_projection_node = createCastFunction(new_projection_node, count_result_type, getContext());

        projection_nodes[0] = std::move(new_projection_node);

        /// Drop the ARRAY JOIN chain: the row multiplication is now expressed by sum(<product of lengths>).
        query_node->getJoinTree() = *join_tree_leaf;
    }
};

}

void RewriteArrayJoinCountPass::run(QueryTreeNodePtr & query_tree_node, ContextPtr context)
{
    RewriteArrayJoinCountVisitor visitor(std::move(context));
    visitor.visit(query_tree_node);
}

}
