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

const PARENT_ROLE = { income_sub: "income", expense_sub: "expense" };

const CASH_FLOW_ID = "cash_flow_node";

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
//
// `links` is optional but should be passed for the full chart: without them a
// subcategory wired straight to cash flow is counted as its own column and d3
// clamps two roles into one (see rolesById).
export function sankeyColumnsById(nodes = [], links = []) {
  const roleById = rolesById(nodes, links);
  const present = new Set(roleById.values());

  const columnByRole = new Map(
    ROLE_ORDER.filter((role) => present.has(role)).map((role, index) => [
      role,
      index,
    ]),
  );

  const columns = new Map();
  for (const [id, role] of roleById) {
    columns.set(id, columnByRole.get(role));
  }
  return columns;
}

function rolesById(nodes, links) {
  const cashFlowNeighbors = cashFlowNeighborIds(nodes, links);
  const roles = new Map();

  for (const node of nodes) {
    const role = sankeyNodeRole(node?.id);
    if (!role) continue;

    // A subcategory that nets AGAINST its parent is emitted with a _sub_ id but
    // linked straight to cash flow (PagesController#process_net_category_nodes),
    // so it sits at the parent's depth and adds no column of its own. Counting
    // its role would claim a column d3 never creates, and d3 clamps whatever we
    // return into [0, maxDepth] — the two rightmost roles then collapse into
    // one, stacking Cash Flow inside the expense column with every outgoing
    // ribbon drawn backwards over it.
    const parentRole = PARENT_ROLE[role];
    roles.set(
      node.id,
      parentRole && cashFlowNeighbors.has(node.id) ? parentRole : role,
    );
  }

  return roles;
}

function cashFlowNeighborIds(nodes, links) {
  const neighbors = new Set();

  for (const link of links) {
    const source = endpointId(link?.source, nodes);
    const target = endpointId(link?.target, nodes);
    if (source === CASH_FLOW_ID) neighbors.add(target);
    if (target === CASH_FLOW_ID) neighbors.add(source);
  }

  return neighbors;
}

// The server emits link endpoints as indexes into `nodes`; d3 swaps them for
// the node objects once the generator has run.
function endpointId(endpoint, nodes) {
  if (typeof endpoint === "number") return nodes[endpoint]?.id;
  if (endpoint && typeof endpoint === "object") return endpoint.id;
  return endpoint;
}
