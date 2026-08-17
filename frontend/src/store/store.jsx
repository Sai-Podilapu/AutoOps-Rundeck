import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
} from "react";
import { api, tokenStore } from "../lib/api";

const KEY = "autoops_prefs_v1";
// Email of the account the persisted prefs belong to — account-scoped state
// (org, workflow drafts) is reset when a different user signs in.
const OWNER_KEY = "autoops_prefs_owner";
const DEFAULT_ORG = { name: "Your workspace", domain: "" };
const StoreContext = createContext(null);

const load = () => {
  try {
    return JSON.parse(localStorage.getItem(KEY)) || {};
  } catch {
    return {};
  }
};

// Client-side RBAC capability matrix (provider/owner is handled separately).
//
// `authorAutomation` — designing workflows and building agents — is FALSE for
// every client role, including admin. That is not an oversight and not a tier
// to be unlocked: workflows and agents are designed by the provider and rolled
// out to customers. A customer builds jobs and scripts (`runWorkflow`,
// `deploy`) and runs what it has been given. The backend enforces the same
// rule, so flipping this to true here would only produce 403s.
export const ROLE_CAPS = {
  admin: {
    manageMembers: true,
    manageBilling: true,
    manageGovernance: true,
    manageKeys: true,
    authorAutomation: false,
    authorScript: true,
    runWorkflow: true,
    approve: true,
    deploy: true,
    viewAudit: true,
    manageProject: true,
  },
  operator: {
    manageMembers: false,
    manageBilling: false,
    manageGovernance: false,
    manageKeys: false,
    authorAutomation: false,
    // Scripts are the exception to authorAutomation: an operator writing a
    // maintenance script is doing their job, not designing the automation
    // the provider ships.
    authorScript: true,
    runWorkflow: true,
    // Operators request; only admins sign off (backend enforces this too).
    approve: false,
    deploy: true,
    viewAudit: false,
    manageProject: false,
  },
  viewer: {
    manageMembers: false,
    manageBilling: false,
    manageGovernance: false,
    manageKeys: false,
    authorAutomation: false,
    authorScript: false,
    runWorkflow: false,
    approve: false,
    deploy: false,
    viewAudit: false,
    manageProject: false,
  },
};

export const ROLE_LABELS = {
  admin: "Admin",
  operator: "Operator",
  viewer: "Viewer",
};

const roleToClient = (role) => {
  const r = String(role || "").toLowerCase();
  if (r === "operator") return "operator";
  if (r === "viewer") return "viewer";
  return "admin";
};

// Map UI role labels <-> backend Role enum and normalize membership rows.
const roleToEnum = (label) => {
  const r = String(label || "").toLowerCase();
  if (r === "operator") return "OPERATOR";
  if (r === "viewer") return "VIEWER";
  return "ADMIN";
};

const enumToRoleLabel = (role) => {
  const r = String(role || "").toUpperCase();
  if (r === "OPERATOR") return "Operator";
  if (r === "VIEWER") return "Viewer";
  return "Admin";
};

const statusToLabel = (s) => {
  const r = String(s || "").toUpperCase();
  if (r === "ACTIVE") return "active";
  if (r === "DISABLED") return "disabled";
  return "pending";
};

const mapMember = (m) => ({
  id: m.id,
  userId: m.user?.id || null,
  name:
    m.user?.name ||
    (m.invitedEmail || m.user?.email || "").split("@")[0] ||
    "Member",
  email: m.user?.email || m.invitedEmail || "",
  role: enumToRoleLabel(m.role),
  status: statusToLabel(m.status),
});

function Toaster({ toasts }) {
  return (
    <div className="pointer-events-none fixed bottom-5 right-5 z-[100] flex flex-col gap-2">
      {toasts.map((t) => (
        <div
          key={t.id}
          className="animate-fade-up pointer-events-auto flex items-center gap-2.5 rounded-lg border border-slate-200 bg-[#ffffff] px-4 py-2.5 text-sm text-slate-900 shadow-2xl shadow-slate-300/40"
        >
          <span
            className={`h-2 w-2 rounded-full ${t.tone === "violet" ? "bg-violet-400" : t.tone === "emerald" ? "bg-emerald-400" : t.tone === "red" ? "bg-red-400" : "bg-slate-100"}`}
          />
          {t.message}
        </div>
      ))}
    </div>
  );
}

export function StoreProvider({ children }) {
  const persisted = load();
  const [booting, setBooting] = useState(true);
  const [session, setSession] = useState({
    authed: false,
    role: "client",
    impersonating: null,
  });
  const [clientRole, setClientRoleState] = useState("admin");
  const [user, setUser] = useState(null);
  const [workspace, setWorkspace] = useState(null);
  const [projects, setProjects] = useState([]);

  const [members, setMembers] = useState([]);
  const [membersError, setMembersError] = useState(null);

  // Local-only state, persisted to localStorage: unsaved canvas drafts and the
  // onboarding org name. Notification preferences used to live here too, where
  // they were per-browser and read by nothing; they are per-member rows in
  // core-service now and genuinely filter the inbox, so the local copy is gone
  // rather than kept as a second, disagreeing source of truth.
  const [designs, setDesigns] = useState(persisted.designs || {});
  const [org, setOrgState] = useState(persisted.org || DEFAULT_ORG);
  const [toasts, setToasts] = useState([]);

  useEffect(() => {
    localStorage.setItem(KEY, JSON.stringify({ designs, org }));
  }, [designs, org]);

  // Account-scoped persisted state must not leak between accounts: when a
  // DIFFERENT user signs in (fresh sign-up, other account on this machine),
  // drop the previous account's org name/domain and workflow drafts.
  useEffect(() => {
    if (!user?.email) return;
    if (localStorage.getItem(OWNER_KEY) !== user.email) {
      setOrgState(DEFAULT_ORG);
      setDesigns({});
      localStorage.setItem(OWNER_KEY, user.email);
    }
  }, [user?.email]);

  const refreshProjects = useCallback(async () => {
    try {
      const rows = await api.listProjects();
      setProjects(Array.isArray(rows) ? rows : []);
    } catch {
      /* keep existing */
    }
  }, []);

  // Apply a session payload returned by the backend auth endpoints.
  const applySession = useCallback(
    async (data) => {
      tokenStore.set(data.accessToken, data.refreshToken);
      if (data.context === "provider") {
        setSession({ authed: true, role: "provider", impersonating: null });
        setUser(data.user || null);
        return { context: "provider" };
      }
      if (data.context === "select-workspace") {
        const memberships = data.memberships || [];
        if (memberships.length) {
          const sel = await api.selectTenant(memberships[0].tenantId);
          return applySession(sel);
        }
        setSession({ authed: true, role: "client", impersonating: null });
        setUser(data.user || null);
        return { context: "no-workspace" };
      }
      // client context
      setSession({ authed: true, role: "client", impersonating: null });
      setUser(data.user || null);
      if (data.activeRole) setClientRoleState(roleToClient(data.activeRole));
      if (data.workspace) setWorkspace(data.workspace);
      await refreshProjects();
      // Non-blocking: pull the live plan + display name into the sidebar.
      api
        .getWorkspace()
        .then((ws) => {
          if (ws?.workspace) setWorkspace((w) => ({ ...(w || {}), ...ws.workspace }));
        })
        .catch(() => {});
      return { context: "client" };
    },
    [refreshProjects],
  );

  // Restore the session on first load if a token is present.
  useEffect(() => {
    let active = true;
    (async () => {
      if (!tokenStore.access) {
        setBooting(false);
        return;
      }
      try {
        const data = await api.me();
        if (!active) return;
        const u = data.user;
        if (u && u.isProvider) {
          setSession({ authed: true, role: "provider", impersonating: null });
          setUser(u);
        } else {
          setSession({ authed: true, role: "client", impersonating: null });
          setUser(u || null);
          const mem =
            (data.memberships || []).find(
              (m) => m.tenantId === data.activeTenantId,
            ) || (data.memberships || [])[0];
          if (mem) {
            setClientRoleState(roleToClient(mem.role));
            setWorkspace(mem.tenant);
          }
          await refreshProjects();
          // Non-blocking: live plan + display name for the restored session.
          api
            .getWorkspace()
            .then((ws) => {
              if (!active || !ws?.workspace) return;
              setWorkspace((w) => ({ ...(w || {}), ...ws.workspace }));
            })
            .catch(() => {});
        }
      } catch {
        tokenStore.clear();
      } finally {
        if (active) setBooting(false);
      }
    })();
    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---- Auth actions ----
  const signIn = useCallback(
    async (email, password) => {
      const data = await api.login(email, password);
      return applySession(data);
    },
    [applySession],
  );

  const signUp = useCallback(async (payload) => {
    // Registration is two-step: the backend emails a verification code and
    // issues no tokens until verifySignup confirms it.
    return api.register(payload);
  }, []);

  const verifySignup = useCallback(
    async (email, code) => {
      const data = await api.verifyRegistration(email.trim(), code.trim());
      return applySession(data);
    },
    [applySession],
  );

  const resendSignupCode = useCallback(async (email) => {
    return api.resendRegistrationCode(email.trim());
  }, []);

  const forgotPassword = useCallback(async (email) => {
    return api.forgotPassword(email.trim());
  }, []);

  const resetPassword = useCallback(
    async (email, code, newPassword) => {
      const data = await api.resetPassword(email.trim(), code.trim(), newPassword);
      return applySession(data);
    },
    [applySession],
  );

  const completeOAuth = useCallback(
    async ({ accessToken, refreshToken, context }) => {
      tokenStore.set(accessToken, refreshToken);
      const data = await api.me();
      const u = data.user;
      if ((u && u.isProvider) || context === "provider") {
        setSession({ authed: true, role: "provider", impersonating: null });
        setUser(u || null);
        return { context: "provider" };
      }
      setSession({ authed: true, role: "client", impersonating: null });
      setUser(u || null);
      const mem =
        (data.memberships || []).find(
          (m) => m.tenantId === data.activeTenantId,
        ) || (data.memberships || [])[0];
      if (mem) {
        setClientRoleState(roleToClient(mem.role));
        setWorkspace(mem.tenant);
      }
      await refreshProjects();
      // Non-blocking: live plan + display name (social logins have no other
      // path to the subscription — without this the badge shows "Free").
      api
        .getWorkspace()
        .then((ws) => {
          if (ws?.workspace) setWorkspace((w) => ({ ...(w || {}), ...ws.workspace }));
        })
        .catch(() => {});
      return { context: "client" };
    },
    [refreshProjects],
  );

  // Passwordless email one-time-code sign-in.
  const requestOtp = useCallback(async (email) => {
    return api.requestOtp(email.trim());
  }, []);

  const signInWithOtp = useCallback(
    async (email, code) => {
      const data = await api.verifyOtp(email.trim(), code.trim());
      return applySession(data);
    },
    [applySession],
  );

  // Legacy local-only sign-in used by marketing/demo flows (Checkout/Onboarding).
  const login = useCallback((role = "client", asClientRole) => {
    setSession((s) => ({ ...s, authed: true, role, impersonating: null }));
    if (role === "client" && asClientRole)
      setClientRoleState(roleToClient(asClientRole));
  }, []);

  const logout = useCallback(() => {
    api.logout().catch(() => {});
    tokenStore.clear();
    setSession({ authed: false, role: "client", impersonating: null });
    setClientRoleState("admin");
    setProjects([]);
    setUser(null);
    setWorkspace(null);
    setMembers([]);
    setMembersError(null);
    // Don't show this account's org identity to whoever signs in next.
    setOrgState(DEFAULT_ORG);
  }, []);

  const startImpersonation = useCallback(
    (t) =>
      setSession((s) => ({
        ...s,
        authed: true,
        role: "client",
        impersonating: { id: t.id, name: t.name },
      })),
    [],
  );
  const stopImpersonation = useCallback(
    () => setSession((s) => ({ ...s, impersonating: null, role: "provider" })),
    [],
  );

  const setClientRole = useCallback((r) => setClientRoleState(r), []);
  const can = useCallback(
    (cap) => !!(ROLE_CAPS[clientRole] && ROLE_CAPS[clientRole][cap]),
    [clientRole],
  );
  // ---- Members (backed by the /members API) ----
  // The roster is admin-only. Surface the failure instead of swallowing it —
  // an empty table silently reading "No records yet" looks like the members
  // were deleted.
  const refreshMembers = useCallback(async () => {
    try {
      const rows = await api.list("members");
      setMembers(Array.isArray(rows) ? rows.map(mapMember) : []);
      setMembersError(null);
    } catch (err) {
      setMembersError(
        err?.message || "Could not load the member list. Try again.",
      );
    }
  }, []);

  const setMemberRole = useCallback(async (id, role) => {
    await api.update("members", id, { role: roleToEnum(role) });
    setMembers((m) => m.map((x) => (x.id === id ? { ...x, role } : x)));
  }, []);

  const inviteMember = useCallback(async (p) => {
    const created = await api.create("members", {
      email: (p.email || "").trim(),
      role: roleToEnum(p.role),
    });
    const mapped = mapMember(created);
    if (p.name) mapped.name = p.name;
    setMembers((m) => [...m, mapped]);
    return mapped;
  }, []);

  const removeMember = useCallback(async (id) => {
    await api.remove("members", id);
    setMembers((m) => m.filter((x) => x.id !== id));
  }, []);

  const refreshWorkspace = useCallback(async () => {
    try {
      const ws = await api.getWorkspace();
      // Merge — the live name/plan must not clobber other workspace fields.
      if (ws?.workspace) setWorkspace((w) => ({ ...(w || {}), ...ws.workspace }));
      return ws;
    } catch {
      return null;
    }
  }, []);

  const saveWorkspace = useCallback(async (patch) => {
    const ws = await api.updateWorkspace(patch);
    if (ws) setWorkspace((w) => ({ ...(w || {}), ...(ws.workspace || ws) }));
    return ws;
  }, []);

  // ---- Projects (backed by the API) ----
  const addProject = useCallback(async (p) => {
    const body = { name: (p && p.name) || "New Project" };
    if (p && p.key) body.key = p.key;
    if (p && p.description) body.description = p.description;
    const created = await api.createProject(body);
    setProjects((a) => [created, ...a]);
    return created;
  }, []);
  // Route params are strings while backend ids are numbers — compare loosely
  // or renames/deletes silently miss the store row and the UI goes stale.
  const removeProject = useCallback(async (id) => {
    await api.deleteProject(id);
    setProjects((a) => a.filter((p) => String(p.id) !== String(id)));
  }, []);
  const updateProject = useCallback(async (id, patch) => {
    const updated = await api.updateProject(id, patch);
    setProjects((a) =>
      a.map((p) => (String(p.id) === String(id) ? { ...p, ...updated } : p)),
    );
    return updated;
  }, []);

  const setOrg = useCallback(
    (o) => setOrgState((prev) => ({ ...prev, ...o })),
    [],
  );
  const saveWorkflowDesign = useCallback(
    (id, data) =>
      setDesigns((d) => ({ ...d, [id]: { ...data, savedAt: Date.now() } })),
    [],
  );
  const getWorkflowDesign = useCallback((id) => designs[id] || null, [designs]);

  const pushToast = useCallback((message, tone = "cyan") => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t, { id, message, tone }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 3200);
  }, []);

  const value = {
    booting,
    session,
    user,
    workspace,
    signIn,
    signUp,
    verifySignup,
    resendSignupCode,
    forgotPassword,
    resetPassword,
    completeOAuth,
    requestOtp,
    signInWithOtp,
    login,
    logout,
    startImpersonation,
    stopImpersonation,
    clientRole,
    setClientRole,
    can,
    members,
    membersError,
    refreshMembers,
    setMemberRole,
    inviteMember,
    removeMember,
    refreshWorkspace,
    saveWorkspace,
    projects,
    refreshProjects,
    addProject,
    updateProject,
    removeProject,
    pushToast,
    designs,
    saveWorkflowDesign,
    getWorkflowDesign,
    org,
    setOrg,
  };
  return (
    <StoreContext.Provider value={value}>
      {children}
      <Toaster toasts={toasts} />
    </StoreContext.Provider>
  );
}

export const useStore = () => {
  const ctx = useContext(StoreContext);
  if (!ctx) throw new Error("useStore must be used within StoreProvider");
  return ctx;
};
