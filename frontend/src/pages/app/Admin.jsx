import React, { useState, useEffect } from "react";
import {
  PageHeader,
  Card,
  StatCard,
  Table,
  StatusBadge,
  SmallButton,
  Chip,
  ConfirmModal,
  Pagination,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import ModalPortal from "../../components/app/ModalPortal";
import { useStore, ROLE_CAPS } from "../../store/store";

const ROLE_OPTIONS = ["Admin", "Operator", "Viewer"];
const roleTone = {
  Owner: "text-slate-900",
  Admin: "text-emerald-600",
  Operator: "text-amber-600",
  Viewer: "text-slate-500",
};

const CAP_ROWS = [
  ["manageMembers", "Manage members & roles"],
  ["manageBilling", "Billing & plan"],
  ["editWorkflow", "Create / edit scripts"],
  ["runWorkflow", "Run & re-run executions"],
  ["approve", "Approve gated actions"],
  ["deploy", "Deploy to environments"],
  ["manageKeys", "Access key storage"],
  ["manageGovernance", "Edit governance policies"],
  ["viewAudit", "View audit log"],
];

function SecurityToggle({ label, initial, disabled, onToggle }) {
  const [on, setOn] = useState(initial);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const apply = () => {
    const v = !on;
    setOn(v);
    onToggle(v);
    setConfirmOpen(false);
  };
  return (
    <div className="flex items-center justify-between px-4 py-3">
      <span className="text-sm text-slate-600">{label}</span>
      <button
        disabled={disabled}
        onClick={() => setConfirmOpen(true)}
        className={`relative h-6 w-11 rounded-full transition ${on ? "bg-blue-500" : "bg-slate-300"} ${disabled ? "cursor-not-allowed opacity-40" : ""}`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${on ? "left-[22px]" : "left-0.5"}`}
        />
      </button>
      <ConfirmModal
        open={confirmOpen}
        title={`${on ? "Turn off" : "Turn on"} ${label}?`}
        message={`This changes \u201c${label}\u201d for the whole workspace.`}
        confirmLabel={on ? "Turn off" : "Turn on"}
        cancelLabel="Cancel"
        tone={on ? "danger" : "primary"}
        onConfirm={apply}
        onClose={() => setConfirmOpen(false)}
      />
    </div>
  );
}

export default function Admin() {
  const {
    members,
    membersError,
    setMemberRole,
    inviteMember,
    removeMember,
    refreshMembers,
    can,
    pushToast,
    projects,
    user,
  } = useStore();

  // You cannot demote or remove yourself: it would strip your own member
  // management rights with no way back (the backend refuses it too).
  const isSelf = (row) =>
    (user?.id != null && String(row.id) === String(user.id)) ||
    (!!user?.email &&
      (row.email || "").toLowerCase() === user.email.toLowerCase());

  const [pageMembers, setPageMembers] = useState(1);
  const pageMembersSize = 5;

  useEffect(() => {
    refreshMembers();
  }, [refreshMembers]);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [form, setForm] = useState({ name: "", email: "", role: "Viewer" });
  const [errors, setErrors] = useState({});
  const editable = can("manageMembers");

  const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  const validate = (f) => {
    const er = {};
    if (!f.name.trim()) er.name = "Name is required.";
    if (!f.email.trim()) er.email = "Email is required.";
    else if (!emailRe.test(f.email.trim()))
      er.email = "Enter a valid email address.";
    else if (
      members.some(
        (m) => (m.email || "").toLowerCase() === f.email.trim().toLowerCase(),
      )
    )
      er.email = "That email is already a member.";
    return er;
  };
  const submit = async (e) => {
    e.preventDefault();
    const er = validate(form);
    setErrors(er);
    if (Object.keys(er).length) return;
    try {
      await inviteMember({
        ...form,
        name: form.name.trim(),
        email: form.email.trim(),
      });
      pushToast(`Invitation sent to ${form.email.trim()}`, "emerald");
      setForm({ name: "", email: "", role: "Viewer" });
      setErrors({});
      setInviteOpen(false);
    } catch (err) {
      setErrors({ email: err.message || "Could not send invitation." });
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Admin Console"
        subtitle="Manage members, roles, security, and tenant-wide settings"
        actions={
          editable ? (
            <SmallButton
              icon="plus"
              variant="primary"
              onClick={() => setInviteOpen(true)}
            >
              Invite member
            </SmallButton>
          ) : (
            <Chip>Read-only role</Chip>
          )
        }
      />

      {!editable && (
        <Card className="mb-6 flex items-center gap-3 border-amber-400/20 bg-amber-400/[0.04] p-4 text-sm text-amber-200">
          <Icon name="lock" size={18} /> Your current role can view this console
          but cannot change members or settings. Switch to{" "}
          <b className="mx-1">Admin</b> to make changes.
        </Card>
      )}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          label="Members"
          value={String(members.length)}
          icon="users"
          tone="cyan"
        />
        <StatCard
          label="Projects"
          value={String(projects.length)}
          icon="folder"
          tone="emerald"
        />
        <StatCard
          label="Pending invites"
          value={String(members.filter((m) => m.status === "pending").length)}
          icon="bell"
          tone="amber"
        />
        <StatCard
          label="Seats"
          value={`${members.length} / 50`}
          icon="scale"
          tone="violet"
        />
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[1.4fr_1fr]">
        <div className="flex h-full flex-col">
          <h3 className="mb-3 text-sm font-semibold text-slate-900">
            Members &amp; roles
          </h3>
          {membersError && (
            <Card className="mb-3 flex items-center gap-3 border-red-300 bg-red-50 p-3 text-sm text-red-700">
              <Icon name="lock" size={16} /> {membersError}
            </Card>
          )}
          <Table
            className="flex-1"
            columns={[
              {
                key: "name",
                label: "User",
                render: (r) => (
                  <div className="flex items-center gap-3">
                    <span className="flex h-8 w-8 items-center justify-center rounded-full bg-gradient-to-br from-slate-200 to-slate-200 text-xs font-bold text-slate-900">
                      {r.name
                        .split(" ")
                        .map((s) => s[0])
                        .slice(0, 2)
                        .join("")}
                    </span>
                    <div>
                      <p className="flex items-center gap-2 font-medium text-slate-900">
                        {r.name}
                        {isSelf(r) && (
                          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                            You
                          </span>
                        )}
                      </p>
                      <p className="text-xs text-slate-500">{r.email}</p>
                    </div>
                  </div>
                ),
              },
              {
                key: "role",
                label: "Role",
                render: (r) =>
                  editable && r.role !== "Owner" && !isSelf(r) ? (
                    <select
                      value={r.role}
                      onChange={async (e) => {
                        const role = e.target.value;
                        try {
                          await setMemberRole(r.id, role);
                          pushToast(`${r.name} is now ${role}`, "cyan");
                        } catch (err) {
                          pushToast(
                            err.message || "Could not change role",
                            "red",
                          );
                        }
                      }}
                      className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1 text-sm text-slate-900 outline-none focus:border-slate-300"
                    >
                      {ROLE_OPTIONS.map((o) => (
                        <option key={o} value={o}>
                          {o}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <span className={`text-sm font-medium ${roleTone[r.role]}`}>
                      {r.role}
                    </span>
                  ),
              },
              {
                key: "status",
                label: "Status",
                render: (r) => <StatusBadge status={r.status} />,
              },
              {
                key: "act",
                label: "",
                render: (r) =>
                  editable && r.role !== "Owner" && !isSelf(r) ? (
                    <button
                      onClick={async () => {
                        try {
                          await removeMember(r.id);
                          pushToast(`${r.name} removed`, "red");
                        } catch (err) {
                          pushToast(
                            err.message || "Could not remove member",
                            "red",
                          );
                        }
                      }}
                      className="text-xs text-slate-500 transition hover:text-red-600"
                    >
                      Remove
                    </button>
                  ) : null,
              }
            ]}
            rows={members.slice((pageMembers - 1) * pageMembersSize, pageMembers * pageMembersSize)}
            empty={membersError ? "Member list unavailable." : "No records yet."}
          />
          <div className="mt-4">
            <Pagination
              page={pageMembers}
              pageSize={pageMembersSize}
              totalItems={members.length}
              onPageChange={setPageMembers}
            />
          </div>
        </div>

        <div className="space-y-6">
          <div>
            <h3 className="mb-3 text-sm font-semibold text-slate-900">
              Roles &amp; permissions
            </h3>
            <Card className="p-4">
              <div className="grid grid-cols-[1fr_auto_auto_auto] items-center gap-x-1 text-xs">
                <div />
                <div className="px-2 text-center font-semibold text-emerald-600">
                  Admin
                </div>
                <div className="px-2 text-center font-semibold text-amber-600">
                  Operator
                </div>
                <div className="px-2 text-center font-semibold text-slate-500">
                  Viewer
                </div>
                {CAP_ROWS.map(([cap, label]) => (
                  <React.Fragment key={cap}>
                    <div className="border-t border-slate-200 py-2 text-slate-600">
                      {label}
                    </div>
                    {["admin", "operator", "viewer"].map((role) => (
                      <div
                        key={role}
                        className="border-t border-slate-200 py-2 text-center"
                      >
                        {ROLE_CAPS[role][cap] ? (
                          <Icon
                            name="check"
                            size={14}
                            className="mx-auto text-emerald-600"
                          />
                        ) : (
                          <span className="text-slate-600">—</span>
                        )}
                      </div>
                    ))}
                  </React.Fragment>
                ))}
              </div>
            </Card>
          </div>
        </div>
      </div>

      {inviteOpen && (
        <ModalPortal layerClass="z-50 items-center p-4" onClose={() => setInviteOpen(false)}>
          <form
            onSubmit={submit}
            className="rw-pop relative w-full max-w-md rounded-2xl border border-slate-200 bg-[#ffffff] p-6 shadow-2xl"
          >
            <h3 className="text-lg font-bold text-slate-900">Invite member</h3>
            <p className="mt-1 text-sm text-slate-500">
              They’ll receive an email to join this workspace.
            </p>
            <div className="mt-4 space-y-3">
              <div>
                <input
                  autoFocus
                  value={form.name}
                  onChange={(e) => {
                    setForm({ ...form, name: e.target.value });
                    if (errors.name)
                      setErrors((x) => ({ ...x, name: undefined }));
                  }}
                  placeholder="Full name"
                  aria-invalid={!!errors.name}
                  className={`w-full rounded-lg border bg-slate-50 px-3 py-2.5 text-sm text-slate-900 outline-none ${errors.name ? "border-red-400/60 focus:border-red-400" : "border-slate-200 focus:border-slate-300"}`}
                />
                {errors.name && (
                  <p className="mt-1 text-xs text-red-600">{errors.name}</p>
                )}
              </div>
              <div>
                <input
                  value={form.email}
                  onChange={(e) => {
                    setForm({ ...form, email: e.target.value });
                    if (errors.email)
                      setErrors((x) => ({ ...x, email: undefined }));
                  }}
                  placeholder="name@company.com"
                  aria-invalid={!!errors.email}
                  className={`w-full rounded-lg border bg-slate-50 px-3 py-2.5 text-sm text-slate-900 outline-none ${errors.email ? "border-red-400/60 focus:border-red-400" : "border-slate-200 focus:border-slate-300"}`}
                />
                {errors.email && (
                  <p className="mt-1 text-xs text-red-600">{errors.email}</p>
                )}
              </div>
              <select
                value={form.role}
                onChange={(e) => setForm({ ...form, role: e.target.value })}
                className="w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm text-slate-900 outline-none focus:border-slate-300"
              >
                {["Admin", "Operator", "Viewer"].map((o) => (
                  <option key={o} value={o}>
                    {o}
                  </option>
                ))}
              </select>
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <SmallButton
                type="button"
                onClick={() => {
                  setInviteOpen(false);
                  setErrors({});
                }}
              >
                Cancel
              </SmallButton>
              <SmallButton type="submit" icon="check" variant="primary">
                Send invite
              </SmallButton>
            </div>
          </form>
        </ModalPortal>
      )}
    </div>
  );
}
