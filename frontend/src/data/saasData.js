// SaaS layer: plans/entitlements, cloud platform catalog, and onboarding config.
// Plan/catalog config is kept; tenant business records start empty for release.

export const tierRank = { Starter: 1, Team: 2, Business: 3, Enterprise: 4 };

export const tiers = {
  Starter: {
    price: 59,
    projects: 3,
    nodes: 10,
    automations: 5,
    jobs: 5,
    integrations: 2,
    history: "30 days",
    library: "Core templates",
    premium: false,
    privateTemplates: false,
    sso: false,
    rbac: "Basic",
  },
  Team: {
    price: 149,
    projects: 10,
    nodes: 25,
    automations: 15,
    jobs: 10,
    integrations: 5,
    history: "90 days",
    library: "Core + Team templates",
    premium: false,
    privateTemplates: false,
    sso: false,
    rbac: "Standard",
  },
  Business: {
    price: 299,
    projects: 25,
    nodes: 35,
    automations: 25,
    jobs: 25,
    integrations: 5,
    history: "180 days",
    library: "All + Premium",
    premium: true,
    privateTemplates: false,
    sso: false,
    rbac: "Advanced",
  },
  Enterprise: {
    price: 399,
    projects: 30,
    nodes: 50,
    automations: 30,
    jobs: 30,
    integrations: 10,
    history: "2 years",
    library: "All + Premium + Private",
    premium: true,
    privateTemplates: true,
    sso: true,
    rbac: "Enterprise",
  },
};

// The signed-in workspace. `plan` must stay a valid key of `tiers`.
export const currentTenant = {
  name: "Your workspace",
  plan: "Team",
  projectsUsed: 0,
};

// Account registry is wired to your backend in production.
export const registeredAccounts = [];

export const accountExists = (email) =>
  registeredAccounts.some(
    (a) =>
      a.email.toLowerCase() ===
      String(email || "")
        .trim()
        .toLowerCase(),
  );

export const cloudPlatforms = [
  {
    id: "aws",
    name: "AWS",
    desc: "Connect to Amazon Web Services",
    icon: "AWS.png",
    color: "#FF9900",
  },
  {
    id: "azure",
    name: "Azure",
    desc: "Connect to Microsoft Azure",
    icon: "Azure.png",
    color: "#3399FF",
  },
  {
    id: "gcp",
    name: "Google Cloud",
    desc: "Connect to Google Cloud Platform",
    icon: "GCP.png",
    color: "#4285F4",
  },
  {
    id: "huawei",
    name: "Huawei Cloud",
    desc: "Connect to Huawei Cloud",
    icon: "Huawei-Logo.png",
    color: "#FF4D4F",
  },
  {
    id: "oracle",
    name: "Oracle Cloud",
    desc: "Connect to Oracle Cloud Infrastructure",
    icon: "OCI.png",
    color: "#F80000",
  },
  {
    id: "m365",
    name: "Microsoft 365",
    desc: "Office & Enterprise Services",
    icon: "M365.png",
    color: "#00A4EF",
  },
  {
    id: "kubernetes",
    name: "Kubernetes",
    desc: "Connect a cluster via kubeconfig — powers kubectl job steps",
    icon: "Kubernetes.png",
    color: "#326CE5",
  },
];

/**
 * Case-insensitive: the API speaks in codes ("AWS"), the catalog in ids
 * ("aws"). An unrecognized platform describes itself rather than silently
 * masquerading as the first entry in the list.
 */
export const platformById = (id) => {
  const key = String(id || "").toLowerCase();
  return (
    cloudPlatforms.find((p) => p.id === key) || {
      id: key,
      name: id ? String(id) : "Unknown",
      desc: "",
      icon: "",
      color: "#64748b",
    }
  );
};

// connectedClouds is now fetched from the API: api.listCloudConnections()
export const connectedClouds = [];

export const libraryStats = [];

export const libraryCategories = [
  "All",
  "Ops",
  "Deploy",
  "Infra",
  "Security",
  "SRE",
  "Compliance",
  "FinOps",
];

export const libraryItems = [];

export const onboardingSteps = [
  {
    id: "org",
    title: "Confirm your organization",
    icon: "shield",
    desc: "Set your organization name and email domain.",
  },
  {
    id: "team",
    title: "Invite your team",
    icon: "users",
    desc: "Add teammates and assign roles.",
  },
  {
    id: "cloud",
    title: "Connect a cloud",
    icon: "cloud",
    desc: "Link AWS, Azure, GCP and more.",
  },
  {
    id: "project",
    title: "Create a project",
    icon: "folder",
    desc: "An isolated workspace for your automations.",
  },
  {
    id: "templates",
    title: "Add starter templates",
    icon: "blocks",
    desc: "Pick from the AutoOps library.",
  },
];

// notifications are fetched from the API: api.listNotifications()
export const notifications = [];

export const notificationFilters = ["All", "Provider", "Internal", "Unread"];

// ---- Provider broadcast center ----
export const broadcastAudiences = [
  "All tenants",
  "Enterprise plan",
  "Business plan",
  "Team plan",
  "Starter plan",
  "EU region tenants",
];

// broadcasts are fetched from the API: api.providerBroadcasts()
export const broadcasts = [];

// providerInbox is fetched from the API: api.listNotifications()
export const providerInbox = [];
