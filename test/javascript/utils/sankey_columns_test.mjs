import assert from "node:assert/strict";
import test from "node:test";

import {
  sankeyColumnsById,
  sankeyNodeRole,
} from "../../../app/javascript/utils/sankey_columns.mjs";

test("orders the five roles left to right", () => {
  const columns = sankeyColumnsById([
    { id: "income_sub_bonus" },
    { id: "income_salary" },
    { id: "cash_flow_node" },
    { id: "expense_shopping" },
    { id: "expense_sub_groceries" },
  ]);

  assert.deepEqual(
    [
      columns.get("income_sub_bonus"),
      columns.get("income_salary"),
      columns.get("cash_flow_node"),
      columns.get("expense_shopping"),
      columns.get("expense_sub_groceries"),
    ],
    [0, 1, 2, 3, 4],
  );
});

test("keeps a childless expense parent in the parent column", () => {
  // d3-sankey's default `justify` sends every node without an outgoing link to
  // the last column, so expense_general would sit next to expense_sub_groceries.
  const columns = sankeyColumnsById([
    { id: "income_salary" },
    { id: "cash_flow_node" },
    { id: "expense_shopping" },
    { id: "expense_sub_groceries" },
    { id: "expense_general" },
    { id: "surplus_node" },
  ]);

  assert.equal(columns.get("expense_general"), columns.get("expense_shopping"));
  assert.equal(columns.get("surplus_node"), columns.get("expense_shopping"));
  assert.notEqual(
    columns.get("expense_general"),
    columns.get("expense_sub_groceries"),
  );
  assert.deepEqual(
    [
      columns.get("income_salary"),
      columns.get("cash_flow_node"),
      columns.get("expense_shopping"),
      columns.get("expense_sub_groceries"),
    ],
    [0, 1, 2, 3],
  );
});

test("compacts columns for a zoomed subgraph", () => {
  // Zooming into a parent leaves only that parent and its children. Returning
  // the absolute role index (3 and 4) would exceed the two columns d3 computes
  // for this graph and both would clamp into the same one.
  const columns = sankeyColumnsById([
    { id: "expense_shopping" },
    { id: "expense_sub_groceries" },
    { id: "expense_sub_clothes" },
  ]);

  assert.equal(columns.get("expense_shopping"), 0);
  assert.equal(columns.get("expense_sub_groceries"), 1);
  assert.equal(columns.get("expense_sub_clothes"), 1);
});

test("leaves unrecognised ids to d3's own depth", () => {
  const columns = sankeyColumnsById([{ id: "mystery_node" }, { id: 7 }]);

  assert.equal(columns.has("mystery_node"), false);
  assert.equal(columns.size, 0);
});

test("classifies subcategory ids before their parent prefix", () => {
  assert.equal(sankeyNodeRole("expense_sub_groceries"), "expense_sub");
  assert.equal(sankeyNodeRole("expense_shopping"), "expense");
  assert.equal(sankeyNodeRole("income_sub_bonus"), "income_sub");
  assert.equal(sankeyNodeRole("income_salary"), "income");
});
