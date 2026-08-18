// Column assignment for the cashflow Sankey, derived from the server's node
// ids rather than from graph topology.
//
// d3-sankey's default `justify` alignment puts every node with no outgoing
// link in the LAST column. With a parents-only chart that happens to be right.
// The moment one expense parent gains a subcategory, though, the graph grows a
// fourth column and every CHILDLESS expense parent is dragged into it, landing
// beside other parents' subcategories — the chart stops reading as "parents,
// then children" exactly when the extra depth was the point.
//
// Ids already carry the role (income_sub_ / income_ / cash_flow_node /
// expense_ / expense_sub_ / surplus_node), so pin the column from the id.
// Roles are compacted to a dense 0..n-1 range over the roles actually present:
// d3 clamps whatever we return into [0, maxDepth], and a zoomed view (one
// parent plus its children) has fewer columns than the full graph.

const ROLE_ORDER = [
  "income_sub",
  "income",
  "cash_flow",
  "expense",
  "expense_sub",
];

export function sankeyNodeRole(id) {
  if (typeof id !== "string") return null;
  // Longest prefix first: "expense_sub_x" also starts with "expense_".
  if (id.startsWith("income_sub_")) return "income_sub";
  if (id.startsWith("expense_sub_")) return "expense_sub";
  if (id.startsWith("income_")) return "income";
  if (id.startsWith("expense_")) return "expense";
  if (id === "cash_flow_node") return "cash_flow";
  // Surplus is drawn from Cash Flow like an expense parent, so it belongs in
  // the parent column, not pushed to the far right as a leaf.
  if (id === "surplus_node") return "expense";
  return null;
}

// Map of node id -> column index. Ids with no recognised role are absent; the
// caller falls back to d3's own depth for those.
export function sankeyColumnsById(nodes = []) {
  const present = new Set();
  for (const node of nodes) {
    const role = sankeyNodeRole(node?.id);
    if (role) present.add(role);
  }

  const columnByRole = new Map(
    ROLE_ORDER.filter((role) => present.has(role)).map((role, index) => [
      role,
      index,
    ]),
  );

  const columns = new Map();
  for (const node of nodes) {
    const role = sankeyNodeRole(node?.id);
    if (role) columns.set(node.id, columnByRole.get(role));
  }
  return columns;
}
