import React, { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { PageHeader, Card, Chip, StatusBadge } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";
import { planAllows, requiredPlan } from "../../lib/entitlements";
import UpgradeNotice from "../../components/app/UpgradeNotice";

export default function AccessControl() {
  const { pid } = useParams();
  const { workspace, can, pushToast } = useStore();
  const plan = workspace?.plan;
  const allowed = planAllows(plan, "rbac");
  const canManage = can("manageMembers");
  const b = `/app/projects/${pid}`;
  const [catalog, setCatalog] = useState(null);
  const [members, setMembers] = useState([]);

  const loadMembers = () =>
    api
      .list("members")
      .then(setMembers)
      .catch(() => {});

  useEffect(() => {
    if (!allowed) return;
    let live = true;
    api
      .listRbacRoles()
      .then((d) => live && setCatalog(d))
      .catch(() => live && pushToast("Could not load roles", "red"));
    if (canManage) loadMembers();
    return () => {
      live = false;
    };
  }, [allowed, canManage]); // eslint-disable-line react-hooks/exhaustive-deps

  const changeRole = async (member, role) => {
    try {
      await api.update("members", member.id, { role });
      pushToast(`${member.user.name} is now ${role.toLowerCase()}`, "emerald");
      await Promise.all([loadMembers(), api.listRbacRoles().then(setCatalog)]);
    } catch (e) {
      pushToast(e.message || "Could not change the role", "red");
    }
  };

  if (!allowed)
    return (
      <div className="animate-fade-up">
        <Link to={b} className="text-sm text-slate-500 hover:text-slate-900">
          ← Project
        </Link>
        <PageHeader
          title="Access Control"
          subtitle="Roles and permissions (RBAC)"
        />
        <UpgradeNotice
          feature="Role-based access control"
          plan={requiredPlan("rbac")}
        />
      </div>
    );

  const roles = catalog?.roles || [];
  const permissions = catalog?.permissions || [];

  return (
    <div className="animate-fade-up">
      <Link
        to={b}
        className="text-sm text-slate-500 transition hover:text-slate-900"
      >
        ← Project
      </Link>
      <PageHeader
        title="Access Control"
        subtitle="Platform roles, live member counts and the permission matrix as enforced by the backend"
      />

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        {roles.map((r) => (
          <Card key={r.code} className="p-5">
            <div className="flex items-center justify-between">
              <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-slate-100 text-slate-900">
                <Icon name="users" size={18} />
              </span>
              <Chip>
                {r.members} member{r.members === 1 ? "" : "s"}
              </Chip>
            </div>
            <h3 className="mt-3 text-sm font-semibold text-slate-900">
              {r.name}
            </h3>
            <p className="mt-1 text-xs text-slate-500">{r.description}</p>
          </Card>
        ))}
      </div>

      <Card className="overflow-hidden">
        <div className="border-b border-slate-200 px-5 py-3 text-sm font-semibold text-slate-900">
          Permission matrix
          <span className="ml-2 text-xs font-normal text-slate-400">
            mirrors the checks enforced by the services
          </span>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs text-slate-500">
                <th className="px-5 py-3 font-medium">Permission</th>
                {roles.map((r) => (
                  <th key={r.code} className="px-5 py-3 text-center font-medium">
                    {r.name}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-200">
              {permissions.map((perm) => (
                <tr key={perm.key} className="transition hover:bg-slate-50">
                  <td className="px-5 py-3 text-slate-700">{perm.label}</td>
                  {roles.map((r) => (
                    <td key={r.code} className="px-5 py-3 text-center">
                      {r.grants && r.grants[perm.key] ? (
                        <span className="inline-flex text-emerald-600">
                          <Icon name="check" size={16} />
                        </span>
                      ) : (
                        <span className="text-slate-300">—</span>
                      )}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      {canManage && (
        <Card className="mt-6 overflow-hidden">
          <div className="border-b border-slate-200 px-5 py-3 text-sm font-semibold text-slate-900">
            Member roles
            <span className="ml-2 text-xs font-normal text-slate-400">
              admins can reassign roles; changes apply on next sign-in token refresh
            </span>
          </div>
          <div className="divide-y divide-slate-200">
            {members.map((m) => (
              <div
                key={m.id}
                className="flex items-center justify-between gap-4 px-5 py-3.5 transition hover:bg-slate-100"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-slate-700">
                    {m.user.name}
                  </p>
                  <p className="truncate text-xs text-slate-500">{m.user.email}</p>
                </div>
                <div className="flex shrink-0 items-center gap-3">
                  <StatusBadge status={String(m.status || "").toLowerCase()} />
                  <select
                    value={m.role}
                    onChange={(e) => changeRole(m, e.target.value)}
                    className="rounded-lg border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 outline-none transition focus:border-slate-300"
                  >
                    <option value="ADMIN">Admin</option>
                    <option value="OPERATOR">Operator</option>
                  </select>
                </div>
              </div>
            ))}
            {members.length === 0 && (
              <div className="px-5 py-6 text-center text-sm text-slate-500">
                No members yet.
              </div>
            )}
          </div>
        </Card>
      )}
    </div>
  );
}