/**
 * Workspace settings.
 *
 * Every control on this page is wired to something. That is a deliberate
 * constraint rather than a description: the tabs previously carried a dark-mode
 * switch with no theme behind it, a timezone the profile does not store, an
 * email column with no email delivery, quiet hours nothing consulted, and a
 * Slack/PagerDuty/Webhook list that was three hard-coded rows next to a real
 * Alert Channels page. All of it is gone. A switch that saves nothing teaches
 * people the settings screen is a lie, and then the real switches stop being
 * believed too.
 *
 * What is left, and what backs it:
 *   Profile        — auth-service (/auth/me). Only the display name is
 *                    writable; email comes from the sign-in identity, so it is
 *                    shown as text instead of a box that discards typing.
 *   Projects       — core-service. Real projects, each linking to its own
 *                    scoped settings, instead of a card telling you to go find
 *                    one.
 *   API Keys       — auth-service, key shown exactly once.
 *   Notifications  — core-service. The rows are generated from the kinds the
 *                    platform actually publishes, and muting one genuinely
 *                    filters the inbox and the unread badge.
 *
 * There was also a Plugins tab, over core-service's /connectors. It is gone.
 * It stored a Slack URL or a GitHub token, encrypted it, and made a real call
 * to prove the credential worked — and then nothing ever dispatched through
 * it: no step type, no workflow node, no notification path resolved a
 * connector. Alert Channels (plugin-service) does the same job for a superset
 * of the providers and actually delivers, so this page points there instead of
 * offering a second, hollow version of it. The backend endpoints remain.
 */

import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import {
  PageHeader,
  Card,
  SmallButton,
  ConfirmModal,
} from "../../components/app/appui";
import FormModal from "../../components/app/FormModal";
import ModalPortal from "../../components/app/ModalPortal";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

const TABS = ["Profile", "Projects", "API Keys", "Notifications"];

/** Icon per notification kind. The kinds themselves come from the server. */
const KIND_ICON = { ALERT: "shield", SYSTEM: "pulse", PROVIDER: "bolt" };

const Toggle = ({ on, onClick, disabled, label }) => (
  <button
    type="button"
    role="switch"
    aria-checked={on}
    aria-label={label}
    onClick={onClick}
    disabled={disabled}
    className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition disabled:opacity-50 ${on ? "bg-slate-900" : "bg-slate-200"}`}
  >
    <span
      className={`inline-block h-4 w-4 transform rounded-full bg-white transition ${on ? "translate-x-6" : "translate-x-1"}`}
    />
  </button>
);

const ReadOnly = ({ label, value, hint }) => (
  <div>
    <label className="text-xs font-medium text-slate-500">{label}</label>
    <p className="mt-1.5 rounded-lg border border-slate-200 bg-slate-100 px-3 py-2.5 text-sm text-slate-600">
      {value || "—"}
    </p>
    {hint && <p className="mt-1 text-xs text-slate-500">{hint}</p>}
  </div>
);

export default function Settings() {
  const [tab, setTab] = useState("Profile");
  const { pushToast, user, workspace, clientRole, can } = useStore();
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    api
      .getAccount()
      .then((a) => {
        if (a?.name) setName(a.name);
        if (a?.email) setEmail(a.email);
      })
      .catch(() => {});
  }, []);
  const saveProfile = async () => {
    if (!name.trim()) {
      pushToast("Enter a name", "red");
      return;
    }
    setSaving(true);
    try {
      await api.updateAccount({ name: name.trim() });
      pushToast("Profile saved", "emerald");
    } catch (e) {
      pushToast(e.message || "Could not save profile", "red");
    } finally {
      setSaving(false);
    }
  };

  // ---- projects ----
  const [projects, setProjects] = useState([]);
  const [projectsLoading, setProjectsLoading] = useState(false);
  const loadProjects = () => {
    setProjectsLoading(true);
    api
      .listProjects()
      .then((rows) => setProjects(Array.isArray(rows) ? rows : []))
      .catch((e) => pushToast(e.message || "Could not load projects", "red"))
      .finally(() => setProjectsLoading(false));
  };

  // ---- API keys ----
  const [keys, setKeys] = useState([]);
  const [keysLoading, setKeysLoading] = useState(false);
  const [keyModalOpen, setKeyModalOpen] = useState(false);
  const [keyBusy, setKeyBusy] = useState(false);
  const [createdKey, setCreatedKey] = useState(null);
  const [revokingId, setRevokingId] = useState(null);
  const loadKeys = () => {
    setKeysLoading(true);
    api
      .listApiKeys()
      .then((rows) => setKeys(Array.isArray(rows) ? rows : []))
      .catch((e) => pushToast(e.message || "Could not load API keys", "red"))
      .finally(() => setKeysLoading(false));
  };
  const createKey = async (vals) => {
    setKeyBusy(true);
    try {
      const rec = await api.createApiKey(vals.name);
      setKeyModalOpen(false);
      setCreatedKey(rec);
      pushToast("API key generated", "emerald");
      loadKeys();
    } catch (e) {
      pushToast(e.message || "Could not create key", "red");
    } finally {
      setKeyBusy(false);
    }
  };
  const revokeKey = async (id) => {
    setRevokingId(null);
    try {
      await api.revokeApiKey(id);
      pushToast("API key revoked", "red");
      loadKeys();
    } catch (e) {
      pushToast(e.message || "Could not revoke key", "red");
    }
  };

  // ---- notification preferences ----
  // The rows are whatever the server says it publishes, labels included, so a
  // new notification kind needs no change here.
  const [prefs, setPrefs] = useState([]);
  const [prefsLoading, setPrefsLoading] = useState(false);
  const [prefBusy, setPrefBusy] = useState(null);
  const loadPrefs = () => {
    setPrefsLoading(true);
    api
      .notificationPreferences()
      .then((rows) => setPrefs(Array.isArray(rows) ? rows : []))
      .catch((e) =>
        pushToast(e.message || "Could not load notification settings", "red"),
      )
      .finally(() => setPrefsLoading(false));
  };
  const togglePref = async (row) => {
    const next = !row.enabled;
    setPrefBusy(row.kind);
    // Optimistic: the switch answers immediately, and reverts if the save
    // fails, rather than sitting inert while the request is in flight.
    setPrefs((p) =>
      p.map((x) => (x.kind === row.kind ? { ...x, enabled: next } : x)),
    );
    try {
      const updated = await api.setNotificationPreference(row.kind, next);
      if (Array.isArray(updated)) setPrefs(updated);
    } catch (e) {
      setPrefs((p) =>
        p.map((x) => (x.kind === row.kind ? { ...x, enabled: !next } : x)),
      );
      pushToast(e.message || "Could not save that preference", "red");
    } finally {
      setPrefBusy(null);
    }
  };

  useEffect(() => {
    if (tab === "API Keys") loadKeys();
    if (tab === "Projects") loadProjects();
    if (tab === "Notifications") loadPrefs();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab]);

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Settings"
        subtitle="Manage your profile, projects, and integrations"
        actions={
          // Only the Profile tab has anything to save on demand; everything
          // else commits as you change it, so a global button would be a
          // promise the other tabs do not keep.
          tab === "Profile" ? (
            <SmallButton
              icon="check"
              variant="primary"
              onClick={saveProfile}
              disabled={saving}
            >
              {saving ? "Saving…" : "Save profile"}
            </SmallButton>
          ) : null
        }
      />
      <div className="mb-6 flex flex-wrap gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`relative px-4 py-2.5 text-sm font-medium transition ${tab === t ? "text-slate-900" : "text-slate-500 hover:text-slate-900"}`}
          >
            {t}
            {tab === t && (
              <span className="absolute inset-x-2 -bottom-px h-0.5 rounded-full bg-slate-900" />
            )}
          </button>
        ))}
      </div>

      {tab === "Profile" && (
        <div className="grid gap-6 lg:grid-cols-2">
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-slate-900">Your profile</h3>
            <p className="mt-0.5 mb-4 text-xs text-slate-500">
              How you appear to the rest of this workspace.
            </p>
            <div className="space-y-4">
              <div>
                <label
                  htmlFor="settings-name"
                  className="text-xs font-medium text-slate-500"
                >
                  Full name
                </label>
                <input
                  id="settings-name"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="mt-1.5 w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>
              <ReadOnly
                label="Email"
                value={email}
                hint="This is your sign-in identity and cannot be changed here."
              />
            </div>
          </Card>
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-slate-900">Access</h3>
            <p className="mt-0.5 mb-4 text-xs text-slate-500">
              Set by your workspace owner and your plan.
            </p>
            <div className="space-y-4">
              <ReadOnly label="Workspace" value={workspace?.name} />
              <ReadOnly label="Plan" value={workspace?.plan} />
              <ReadOnly
                label="Your role"
                value={
                  clientRole
                    ? clientRole.charAt(0).toUpperCase() + clientRole.slice(1)
                    : user?.role
                }
                hint="Roles are managed in Admin Console → Access control."
              />
            </div>
          </Card>
        </div>
      )}

      {tab === "Projects" && (
        <Card className="p-6">
          <div className="mb-4">
            <h3 className="text-sm font-semibold text-slate-900">
              Project settings
            </h3>
            <p className="mt-0.5 text-xs text-slate-500">
              Members, integrations and defaults are scoped to a project. Open
              one to configure it.
            </p>
          </div>
          {projectsLoading ? (
            <p className="py-6 text-center text-sm text-slate-500">Loading…</p>
          ) : projects.length === 0 ? (
            <p className="rounded-lg border border-dashed border-slate-200 py-8 text-center text-sm text-slate-500">
              No projects yet. Create one from Projects to configure it here.
            </p>
          ) : (
            <div className="space-y-2">
              {projects.map((p) => (
                <Link
                  key={p.id}
                  to={`/app/projects/${p.id}/settings`}
                  className="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 transition hover:border-blue-500"
                >
                  <div className="min-w-0">
                    <p className="flex items-center gap-2 text-sm font-medium text-slate-900">
                      <Icon name="folder" size={14} className="text-slate-500" />
                      {p.name}
                    </p>
                    <p className="mt-0.5 truncate text-xs text-slate-500">
                      {p.description || "No description"}
                    </p>
                  </div>
                  <Icon name="chevron" size={16} className="text-slate-400" />
                </Link>
              ))}
            </div>
          )}
        </Card>
      )}

      {tab === "API Keys" && (
        <Card className="p-6">
          <div className="mb-4 flex items-center justify-between">
            <div>
              <h3 className="text-sm font-semibold text-slate-900">
                Personal access tokens
              </h3>
              <p className="mt-0.5 text-xs text-slate-500">
                Tokens authenticate API and CLI requests for this workspace.
              </p>
            </div>
            <SmallButton
              icon="plus"
              variant="primary"
              onClick={() => setKeyModalOpen(true)}
            >
              Generate new key
            </SmallButton>
          </div>
          {keysLoading ? (
            <p className="py-6 text-center text-sm text-slate-500">Loading…</p>
          ) : keys.length === 0 ? (
            <p className="rounded-lg border border-dashed border-slate-200 py-8 text-center text-sm text-slate-500">
              No API keys yet. Generate one to get started.
            </p>
          ) : (
            <div className="space-y-2">
              {keys.map((k) => (
                <div
                  key={k.id}
                  className="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-4 py-3"
                >
                  <div className="min-w-0">
                    <p className="flex items-center gap-2 text-sm font-medium text-slate-900">
                      <Icon name="key" size={14} className="text-emerald-600" />
                      {k.name}
                      {k.revoked && (
                        <span className="rounded-full bg-red-400/10 px-2 py-0.5 text-[10px] font-semibold text-red-600">
                          Revoked
                        </span>
                      )}
                    </p>
                    <p className="mt-0.5 font-mono text-xs text-slate-500">
                      {k.prefix}••••••••
                    </p>
                  </div>
                  {!k.revoked && (
                    <SmallButton onClick={() => setRevokingId(k.id)}>
                      Revoke
                    </SmallButton>
                  )}
                </div>
              ))}
            </div>
          )}
        </Card>
      )}

      {tab === "Notifications" && (
        <div className="space-y-5">
          <Card className="p-6">
            <div className="mb-4">
              <h3 className="text-sm font-semibold text-slate-900">
                In-app notifications
              </h3>
              <p className="mt-0.5 text-xs text-slate-500">
                Choose what reaches your inbox and the bell. Turning one off
                hides it and stops it counting as unread — nothing is deleted,
                so turning it back on restores the history.
              </p>
            </div>
            {prefsLoading ? (
              <p className="py-6 text-center text-sm text-slate-500">Loading…</p>
            ) : prefs.length === 0 ? (
              <p className="rounded-lg border border-dashed border-slate-200 py-8 text-center text-sm text-slate-500">
                Notification settings are unavailable right now.
              </p>
            ) : (
              <div className="divide-y divide-slate-200">
                {prefs.map((row) => (
                  <div
                    key={row.kind}
                    className="flex items-center justify-between gap-4 py-3.5 first:pt-0 last:pb-0"
                  >
                    <div className="flex min-w-0 items-center gap-3">
                      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-slate-100 text-slate-900">
                        <Icon name={KIND_ICON[row.kind] || "bell"} size={16} />
                      </span>
                      <div className="min-w-0">
                        <p className="text-sm font-medium text-slate-700">
                          {row.label}
                        </p>
                        <p className="text-xs text-slate-500">
                          {row.description}
                        </p>
                      </div>
                    </div>
                    <Toggle
                      on={row.enabled}
                      label={row.label}
                      disabled={prefBusy === row.kind}
                      onClick={() => togglePref(row)}
                    />
                  </div>
                ))}
              </div>
            )}
          </Card>
          {/* Delivery outside the app is a different system with its own
              credentials and test button. Pointing at it beats duplicating a
              few of its providers here as switches that dispatch nothing. The
              link is hidden without manageKeys because that route is gated on
              it — offering a door that answers 403 helps nobody. */}
          <Card className="flex flex-wrap items-center justify-between gap-3 p-5">
            <div>
              <p className="text-sm font-medium text-slate-700">
                Delivery outside AutoOps
              </p>
              <p className="text-xs text-slate-500">
                Slack, email and ticketing destinations — plus which events go
                to each — live in Alert Channels.
              </p>
            </div>
            {can("manageKeys") && (
              <Link
                to="/app/notification-channels"
                className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition hover:border-blue-500"
              >
                <Icon name="bell" size={16} /> Open Alert Channels
              </Link>
            )}
          </Card>
        </div>
      )}

      <FormModal
        open={keyModalOpen}
        title="Generate API key"
        description="Give this key a name. The secret is shown only once."
        fields={[
          {
            name: "name",
            label: "Key name",
            placeholder: "e.g. CI pipeline",
            required: true,
            autoFocus: true,
          },
        ]}
        submitLabel="Generate"
        busy={keyBusy}
        onSubmit={createKey}
        onClose={() => setKeyModalOpen(false)}
      />
      {createdKey && (
        <ModalPortal layerClass="z-[95] items-center p-4" onClose={() => setCreatedKey(null)}>
          <div className="rw-pop relative w-full max-w-md rounded-2xl border border-slate-200 bg-[#ffffff] p-6 shadow-2xl">
            <h2 className="text-base font-semibold text-slate-900">
              API key created
            </h2>
            <p className="mt-1 text-xs text-slate-500">
              Copy this now — you won't be able to see it again.
            </p>
            <div className="mt-4 flex items-center justify-between gap-2 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5">
              <code className="truncate font-mono text-xs text-emerald-600">
                {createdKey.key}
              </code>
              <SmallButton
                onClick={() => {
                  navigator.clipboard?.writeText(createdKey.key);
                  pushToast("Copied to clipboard", "emerald");
                }}
              >
                Copy
              </SmallButton>
            </div>
            <div className="mt-5 flex justify-end">
              <SmallButton
                variant="primary"
                onClick={() => setCreatedKey(null)}
              >
                Done
              </SmallButton>
            </div>
          </div>
        </ModalPortal>
      )}
      <ConfirmModal
        open={!!revokingId}
        title="Revoke API key?"
        message="Applications using this key will immediately lose access."
        confirmLabel="Revoke"
        tone="danger"
        onConfirm={() => revokeKey(revokingId)}
        onClose={() => setRevokingId(null)}
      />
    </div>
  );
}
