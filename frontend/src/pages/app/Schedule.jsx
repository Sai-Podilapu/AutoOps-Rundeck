import React, { useState, useEffect } from "react";
import { useParams } from "react-router-dom";
import {
  PageHeader,
  Toolbar,
  Table,
  StatusBadge,
  SmallButton,
  ConfirmModal,
} from "../../components/app/appui";
import Icon from "../../components/Icon";
import FormModal from "../../components/app/FormModal";
import { useStore } from "../../store/store";
import { api } from "../../lib/api";
import {
  browserTimezone,
  fmtInZone,
  offsetLabel,
  timezoneOptions,
} from "../../lib/timezones";

// A schedule is a job's cron expression plus the IANA zone it is read in:
// creating one attaches a cron to a job, deleting one detaches it. The cron is
// a LOCAL-TIME rule — "0 2 * * *" in America/Chicago is 2 AM Chicago all year,
// so the absolute instant shifts by an hour across DST.
export default function Schedule() {
  const { pid } = useParams();
  const { pushToast } = useStore();
  const [schedules, setSchedules] = useState([]);
  const [jobs, setJobs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState(null);
  const [editTarget, setEditTarget] = useState(null);
  const [deleteTarget, setDeleteTarget] = useState(null);

  const load = () => {
    setLoading(true);
    setError(null);
    Promise.all([api.list("schedules", pid), api.list("jobs", pid)])
      .then(([rows, jobRows]) => {
        setSchedules(Array.isArray(rows) ? rows : []);
        setJobs(Array.isArray(jobRows) ? jobRows : []);
        setLoading(false);
      })
      .catch((e) => {
        setError(e.message || "Could not load schedules");
        setLoading(false);
      });
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pid]);

  const unscheduled = jobs.filter((j) => !j.schedule);
  const viewerTz = browserTimezone();
  const tzOptions = timezoneOptions();

  const submit = async (values) => {
    setBusy(true);
    setFormError(null);
    try {
      if (editTarget) {
        await api.update("schedules", editTarget.id, values);
        pushToast("Schedule updated", "emerald");
      } else {
        await api.create("schedules", values);
        pushToast("Schedule created", "emerald");
      }
      setOpen(false);
      setEditTarget(null);
      load();
    } catch (e) {
      setFormError(e.message || "Could not save schedule");
    } finally {
      setBusy(false);
    }
  };

  const doDelete = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await api.remove("schedules", deleteTarget.id);
      pushToast("Schedule removed — the job is kept", "emerald");
      load();
    } catch (e) {
      pushToast(e.message || "Failed to delete schedule", "red");
    } finally {
      setBusy(false);
      setDeleteTarget(null);
    }
  };

  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Schedule"
        subtitle="Cron-based triggers across your jobs"
        actions={
          <SmallButton icon="plus" variant="primary" onClick={() => {
            setEditTarget(null);
            setOpen(true);
          }}>
            New schedule
          </SmallButton>
        }
      />
      <Toolbar placeholder="Search schedules…" />
      <Table
        loading={loading}
        error={error}
        onRetry={load}
        empty="No schedules yet. Attach a cron to one of your jobs to run it automatically."
        onRowClick={(r) => {
          setEditTarget(r);
          setOpen(true);
        }}
        columns={[
          {
            key: "job",
            label: "Job",
            render: (r) => (
              <span className="font-medium text-slate-900">{r.job}</span>
            ),
          },
          {
            key: "cron",
            label: "Cron",
            render: (r) => (
              <span className="font-mono text-xs text-slate-900">{r.cron}</span>
            ),
          },
          {
            // Both readings of the same instant: when it fires for the
            // customer, and when that lands for whoever is looking at it.
            key: "next",
            label: "Next run",
            render: (r) => (
              <div className="leading-tight">
                <div className="text-slate-600">
                  {r.next ? fmtInZone(r.next, r.tz) : "—"}
                </div>
                {r.next && r.tz !== viewerTz && (
                  <div className="text-xs text-slate-400">
                    {fmtInZone(r.next, viewerTz)} your time
                  </div>
                )}
              </div>
            ),
          },
          {
            key: "tz",
            label: "Timezone",
            render: (r) => (
              <div className="leading-tight">
                <div className="text-slate-500">{r.tz}</div>
                <div className="text-xs text-slate-400">{offsetLabel(r.tz)}</div>
              </div>
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
            render: (r) => (
              <div
                className="flex items-center justify-end gap-2"
                onClick={(e) => e.stopPropagation()}
              >
                <SmallButton
                  icon="pencil"
                  onClick={() => {
                    setEditTarget(r);
                    setOpen(true);
                  }}
                >
                  Edit
                </SmallButton>
                <button
                  onClick={() => setDeleteTarget(r)}
                  aria-label="Delete Schedule"
                  className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3.5 py-2 text-sm font-semibold text-slate-900 transition duration-300 hover:border-red-500 hover:bg-red-500 hover:text-white"
                >
                  <Icon name="trash" size={16} />
                  Delete
                </button>
              </div>
            ),
          },
        ]}
        rows={schedules}
      />
      <FormModal
        open={open}
        title={editTarget ? `Edit schedule — ${editTarget.job}` : "New schedule"}
        description={
          editTarget
            ? "The cron is read in the timezone below, and holds that local time across DST."
            : unscheduled.length === 0
              ? "All your jobs are already scheduled. Create a job first, or edit an existing schedule."
              : "Attach a cron to one of your jobs. The cron is read in the timezone below, and holds that local time across DST."
        }
        busy={busy}
        error={formError}
        onClose={() => {
          setOpen(false);
          setEditTarget(null);
        }}
        onSubmit={submit}
        submitLabel={editTarget ? "Save Changes" : "Create schedule"}
        fields={[
          ...(editTarget
            ? []
            : [
                {
                  name: "jobId",
                  label: "Job",
                  type: "select",
                  required: true,
                  options: unscheduled.map((j) => ({
                    value: String(j.id),
                    label: j.name,
                  })),
                },
              ]),
          {
            name: "cron",
            label: "Cron Expression",
            placeholder: "0 0 * * *",
            required: true,
            defaultValue: editTarget?.cron,
          },
          {
            // Defaults to the viewer's own zone on create, which is right far
            // more often than UTC — but stays editable, because an admin in
            // one zone routinely schedules for a customer in another.
            name: "tz",
            label: "Timezone",
            type: "select",
            required: true,
            options: tzOptions,
            defaultValue: editTarget?.tz || viewerTz,
          },
        ]}
      />
      <ConfirmModal
        open={!!deleteTarget}
        title="Remove Schedule"
        message={`Remove the schedule from "${deleteTarget?.job}"? The job itself is kept and can still be run manually.`}
        confirmLabel="Remove"
        tone="danger"
        busy={busy}
        onClose={() => setDeleteTarget(null)}
        onConfirm={doDelete}
      />
    </div>
  );
}
