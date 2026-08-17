// Tenant subscription entitlements. Features unlock based on the workspace plan.
// Lower plans see a locked "Upgrade to unlock" state instead of the feature.

export const PLAN_RANK = { Starter: 1, Team: 2, Business: 3, Enterprise: 4 };

// Minimum plan required for each gated feature.
export const FEATURE_MIN = {
  compliance: "Business",
  governance: "Business",
  rbac: "Business",
  scm: "Business",
  advancedSteps: "Business",
  plugins: "Team",
  privateTemplates: "Enterprise",
  sso: "Enterprise",
  unlimitedNodes: "Enterprise",
};

export function planAllows(plan, feature) {
  const need = FEATURE_MIN[feature] || "Starter";
  return (PLAN_RANK[plan] || 0) >= (PLAN_RANK[need] || 0);
}

export function requiredPlan(feature) {
  return FEATURE_MIN[feature] || "Starter";
}
