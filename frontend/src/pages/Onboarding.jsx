import React, { useState } from "react";
import { useNavigate } from "react-router-dom";
import { LogoMark } from "../components/ui";
import Icon from "../components/Icon";
import CloudLogo from "../components/app/CloudLogo";
import {
  onboardingSteps,
  cloudPlatforms,
  libraryItems,
} from "../data/saasData";
import { useStore } from "../store/store";
import { api } from "../lib/api";
import { GoogleLogo, MicrosoftLogo } from "../components/BrandLogos";

export default function Onboarding() {
  const [step, setStep] = useState(0);
  const navigate = useNavigate();
  const {
    login,
    session,
    org: savedOrg,
    setOrg,
    saveWorkspace,
    addProject,
    refreshProjects,
    inviteMember,
    pushToast,
  } = useStore();
  const [org, setOrgState] = useState(savedOrg || { name: "", domain: "" });
  const [team, setTeam] = useState([
    { email: "", role: "Operator" },
    { email: "", role: "Viewer" },
  ]);
  const [project, setProject] = useState({ name: "", desc: "" });
  const [inviting, setInviting] = useState(false);
  const [finishing, setFinishing] = useState(false);
  const [cloudBusy, setCloudBusy] = useState(false);
  const [connectedCloudIds, setConnectedCloudIds] = useState([]);
  const [errors, setErrors] = useState({});
  const last = onboardingSteps.length - 1;
  const s = onboardingSteps[step];

  const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  const next = async () => {
    if (s.id === "org") {
      const cleaned = {
        name: org.name.trim(),
        domain: org.domain.trim().toLowerCase(),
      };
      setOrg(cleaned);
      if (session?.authed && cleaned.name) {
        try {
          await saveWorkspace(cleaned);
        } catch {
          /* non-blocking */
        }
      }
    }
    setStep((v) => v + 1);
  };

  const sendInvites = async () => {
    if (inviting) return;
    const valid = team.filter(
      (t) =>
        emailRe.test(t.email.trim()) &&
        (!org.domain ||
          t.email
            .trim()
            .toLowerCase()
            .endsWith("@" + org.domain.toLowerCase())),
    );
    if (!valid.length) {
      pushToast("Add at least one valid teammate email", "amber");
      return;
    }
    if (!session?.authed) {
      pushToast("Sign in to send invites", "amber");
      return;
    }
    setInviting(true);
    let ok = 0;
    for (const t of valid) {
      try {
        await inviteMember({ email: t.email.trim(), role: t.role });
        ok += 1;
      } catch (err) {
        pushToast(err.message || `Could not invite ${t.email.trim()}`, "red");
      }
    }
    if (ok) pushToast(`Invited ${ok} teammate${ok > 1 ? "s" : ""}`, "emerald");
    setInviting(false);
  };

  const cloudPlatformMap = {
    aws: "AWS",
    azure: "AZURE",
    gcp: "GCP",
    huawei: "HUAWEI",
    oracle: "ORACLE",
    m365: "M365",
  };
  const connectCloud = async (p) => {
    if (cloudBusy || connectedCloudIds.includes(p.id)) return;
    if (!session?.authed) {
      pushToast("Sign in to connect a cloud", "amber");
      return;
    }
    setCloudBusy(true);
    try {
      await api.createCloudConnection({
        platform: cloudPlatformMap[p.id] || "AWS",
        name: p.name,
      });
      setConnectedCloudIds((ids) => [...ids, p.id]);
      pushToast(`${p.name} connection created`, "emerald");
    } catch (err) {
      pushToast(err.message || `Could not connect ${p.name}`, "red");
    } finally {
      setCloudBusy(false);
    }
  };

  const finish = async () => {
    if (finishing) return;
    setFinishing(true);
    try {
      if (session?.authed && project.name.trim()) {
        try {
          await addProject({
            name: project.name.trim(),
            description: project.desc.trim(),
          });
        } catch {
          /* non-blocking */
        }
      }
      if (session?.authed) {
        await refreshProjects().catch(() => {});
      } else {
        login("client", "admin");
      }
      navigate("/app");
    } finally {
      setFinishing(false);
    }
  };

  return (
    <div className="grid-bg relative min-h-screen overflow-hidden bg-white px-6 py-10">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-0 h-[420px] w-[620px] rounded-full bg-slate-100 blur-[150px]" />
      </div>

      <div className="mx-auto max-w-3xl">
        <div className="mb-8 flex items-center justify-between">
          <div className="mb-8 flex items-center justify-center gap-2.5">
            <LogoMark size={30} />
          </div>
        </div>

        <div className="mb-8 flex items-center gap-2">
          {onboardingSteps.map((os, i) => (
            <React.Fragment key={os.id}>
              <div
                className={`flex h-9 w-9 items-center justify-center rounded-full border text-sm font-semibold transition ${i < step ? "border-emerald-400/40 bg-emerald-400/10 text-emerald-600" : i === step ? "border-slate-300 bg-slate-100 text-slate-900" : "border-slate-200 text-slate-600"}`}
              >
                {i < step ? <Icon name="check" size={16} /> : i + 1}
              </div>
              {i < last && (
                <div
                  className={`h-px flex-1 ${i < step ? "bg-emerald-400/40" : "bg-slate-50"}`}
                />
              )}
            </React.Fragment>
          ))}
        </div>

        <div className="animate-fade-up rounded-2xl border border-slate-200 bg-slate-50 p-8">
          <div className="flex items-center gap-3">
            <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-gradient-to-br from-slate-200 to-slate-200 text-slate-900">
              <Icon name={s.icon} size={22} />
            </span>
            <div>
              <h1 className="text-xl font-semibold text-slate-900">
                {s.title}
              </h1>
              <p className="text-sm text-slate-500">{s.desc}</p>
            </div>
          </div>

          <div className="mt-6">
            {s.id === "org" && (
              <div className="space-y-4">
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    Organization name
                  </label>
                  <input
                    value={org.name}
                    onChange={(e) => {
                      setOrgState((o) => ({ ...o, name: e.target.value }));
                      if (errors.name)
                        setErrors((x) => ({ ...x, name: undefined }));
                    }}
                    placeholder="Your Company"
                    className={`w-full rounded-lg border bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none ${errors.name ? "border-red-400/60" : "border-slate-200 focus:border-slate-300"}`}
                  />
                  {errors.name && (
                    <p className="mt-1 text-xs text-red-600">{errors.name}</p>
                  )}
                </div>
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    Organization email domain
                  </label>
                  <div
                    className={`flex items-center gap-1 rounded-lg border bg-slate-50 px-3 ${errors.domain ? "border-red-400/60" : "border-slate-200 focus-within:border-slate-300"}`}
                  >
                    <span className="text-sm text-slate-500">@</span>
                    <input
                      value={org.domain}
                      onChange={(e) => {
                        setOrgState((o) => ({
                          ...o,
                          domain: e.target.value.replace(/^@/, "").trim(),
                        }));
                        if (errors.domain)
                          setErrors((x) => ({ ...x, domain: undefined }));
                      }}
                      placeholder="yourcompany.com"
                      className="w-full bg-transparent py-2.5 text-sm text-slate-900 outline-none"
                    />
                  </div>
                  {errors.domain && (
                    <p className="mt-1 text-xs text-red-600">{errors.domain}</p>
                  )}
                  <p className="mt-2 text-xs text-slate-500">
                    Teammates can only be invited with{" "}
                    <span className="text-slate-600">
                      @{org.domain || "yourdomain.com"}
                    </span>{" "}
                    email addresses.
                  </p>
                </div>
              </div>
            )}
            {s.id === "team" &&
              (() => {
                const getValidEmails = () => {
                  return team
                    .filter(
                      (t) =>
                        emailRe.test(t.email.trim()) &&
                        (!org.domain ||
                          t.email
                            .trim()
                            .toLowerCase()
                            .endsWith("@" + org.domain.toLowerCase())),
                    )
                    .map((t) => t.email.trim())
                    .join(",");
                };
                const subject = encodeURIComponent("Join my AutoOps team");
                const body = encodeURIComponent(
                  "Hi there,\n\nI've invited you to join our AutoOps workspace to help automate and orchestrate our infrastructure.\n\nClick here to join: https://autoops.com/invite\n\nThanks!",
                );

                const sendGmail = (e) => {
                  e.preventDefault();
                  window.open(
                    `https://mail.google.com/mail/?view=cm&fs=1&to=${getValidEmails()}&su=${subject}&body=${body}`,
                    "_blank",
                  );
                };
                const sendOutlook = (e) => {
                  e.preventDefault();
                  window.open(
                    `https://outlook.live.com/mail/0/deeplink/compose?to=${getValidEmails()}&subject=${subject}&body=${body}`,
                    "_blank",
                  );
                };

                return (
                  <div className="space-y-3">
                    {team.map((val, i) => (
                      <div key={i}>
                        <div className="flex gap-2">
                          <input
                            value={val.email}
                            onChange={(e) =>
                              setTeam((t) =>
                                t.map((v, j) =>
                                  j === i ? { ...v, email: e.target.value } : v,
                                ),
                              )
                            }
                            placeholder={`teammate@${org.domain || "company.com"}`}
                            className={`flex-1 rounded-lg border bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none ${errors["team" + i] ? "border-red-400/60" : "border-slate-200 focus:border-slate-300"}`}
                          />
                          <select
                            value={val.role}
                            onChange={(e) =>
                              setTeam((t) =>
                                t.map((v, j) =>
                                  j === i ? { ...v, role: e.target.value } : v,
                                ),
                              )
                            }
                            className="rounded-lg border border-slate-200 bg-slate-50 px-3 text-sm text-slate-600 outline-none"
                          >
                            <option>Admin</option>
                            <option>Operator</option>
                            <option>Viewer</option>
                          </select>
                        </div>
                        {errors["team" + i] && (
                          <p className="mt-1 text-xs text-red-600">
                            {errors["team" + i]}
                          </p>
                        )}
                      </div>
                    ))}
                    <p className="text-xs text-slate-500">
                      Only{" "}
                      <span className="text-slate-600">
                        @{org.domain || "your domain"}
                      </span>{" "}
                      addresses are allowed.
                    </p>

                    <button
                      type="button"
                      onClick={sendInvites}
                      disabled={inviting}
                      className="mt-1 flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40 disabled:opacity-50"
                    >
                      {inviting ? "Sending invites…" : "Send AutoOps invites"}
                    </button>

                    <div className="mt-5 flex flex-wrap items-center gap-3 border-t border-slate-200 pt-5">
                      <p className="text-xs font-medium text-slate-500">
                        Or send via your own email:
                      </p>
                      <button
                        type="button"
                        onClick={sendGmail}
                        className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:border-blue-500 hover:bg-slate-100"
                      >
                        <GoogleLogo size={14} /> Gmail
                      </button>
                      <button
                        type="button"
                        onClick={sendOutlook}
                        className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:border-blue-500 hover:bg-slate-100"
                      >
                        <MicrosoftLogo size={12} /> Outlook
                      </button>
                      <a
                        href={`mailto:${getValidEmails()}?subject=${subject}&body=${body}`}
                        className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:border-blue-500 hover:bg-slate-100"
                      >
                        <Icon name="mail" size={14} /> Mail App
                      </a>
                    </div>
                  </div>
                );
              })()}
            {s.id === "cloud" && (
              <div className="grid gap-3 sm:grid-cols-3">
                {cloudPlatforms.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => connectCloud(p)}
                    disabled={cloudBusy}
                    className={`group rounded-xl border p-4 text-left transition hover:bg-slate-100 disabled:opacity-50 ${connectedCloudIds.includes(p.id) ? "border-emerald-400/60 bg-emerald-400/[0.06]" : "border-slate-200 bg-slate-50 hover:border-blue-500"}`}
                  >
                    <span className="flex h-9 w-9 items-center justify-center rounded-lg border border-slate-200 bg-white">
                      <CloudLogo platform={p} size={18} />
                    </span>
                    <p className="mt-2 text-sm font-semibold text-slate-900">
                      {p.name}
                    </p>
                  </button>
                ))}
              </div>
            )}
            {s.id === "project" && (
              <div className="space-y-3">
                <input
                  value={project.name}
                  onChange={(e) =>
                    setProject((p) => ({ ...p, name: e.target.value }))
                  }
                  placeholder="Project name (e.g. Payments)"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none focus:border-slate-300"
                />
                <textarea
                  rows={2}
                  value={project.desc}
                  onChange={(e) =>
                    setProject((p) => ({ ...p, desc: e.target.value }))
                  }
                  placeholder="What will this project automate?"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none focus:border-slate-300"
                />
              </div>
            )}
            {s.id === "templates" && (
              <div className="grid gap-3 sm:grid-cols-2">
                {libraryItems.slice(0, 4).map((it) => (
                  <label
                    key={it.id}
                    className="flex cursor-pointer items-start gap-3 rounded-xl border border-slate-200 bg-slate-50 p-4 transition hover:border-blue-500"
                  >
                    <input
                      type="checkbox"
                      defaultChecked
                      className="mt-1 accent-cyan-400"
                    />
                    <div>
                      <p className="text-sm font-semibold text-slate-900">
                        {it.name}
                      </p>
                      <p className="text-xs text-slate-500">
                        {it.type} · {it.category}
                      </p>
                    </div>
                  </label>
                ))}
              </div>
            )}
          </div>

          <div className="mt-8 flex items-center justify-between">
            <button
              onClick={() => setStep((v) => Math.max(0, v - 1))}
              disabled={step === 0}
              className="rounded-lg border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100 disabled:opacity-30"
            >
              Back
            </button>
            <div className="flex items-center gap-4">
              {step >= 2 && (
                <button
                  onClick={step < last ? () => setStep((v) => v + 1) : finish}
                  className="text-sm font-medium text-slate-500 transition hover:text-slate-900"
                >
                  Skip step
                </button>
              )}
              {step < last ? (
                <button
                  onClick={next}
                  className="rounded-lg bg-slate-900 px-5 py-2 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40"
                >
                  Continue
                </button>
              ) : (
                <button
                  onClick={finish}
                  disabled={finishing}
                  className="rounded-lg bg-slate-900 px-5 py-2 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40 disabled:opacity-50"
                >
                  {finishing ? "Launching…" : "Launch workspace →"}
                </button>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
