import React from "react";
import { Card } from "../appui";
import Icon from "../../Icon";

const inputCls =
  "w-full rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300";
const label = "mb-1.5 block text-xs font-medium text-slate-500";

/**
 * Where a job's steps run.
 *
 * <p>This is the capability AutoOps did not have before the engine swap. Left
 * off — which is the default — every step runs on the platform runner exactly
 * as it always did, so an existing job is untouched. Turned on, each step is
 * dispatched across the nodes matching the filter, and the run log reports a
 * result per node.
 */
export default function JobNodesTab({ nodes, onChange }) {
  const set = (field, value) => onChange({ ...nodes, [field]: value });

  return (
    <div className="space-y-5">
      <Card className="p-6">
        <label className="flex cursor-pointer items-start gap-3">
          <input
            type="checkbox"
            checked={!!nodes.dispatch}
            onChange={(e) => set("dispatch", e.target.checked)}
            className="mt-0.5 h-4 w-4 rounded accent-blue-600"
          />
          <span>
            <span className="text-sm font-semibold text-slate-900">
              Dispatch to nodes
            </span>
            <span className="mt-1 block text-xs leading-relaxed text-slate-500">
              Run each step across a set of machines instead of on the platform
              runner. Leave this off and the job behaves exactly as it does today.
            </span>
          </span>
        </label>
      </Card>

      {!nodes.dispatch ? (
        <Card className="p-6">
          <div className="flex items-start gap-3 text-sm text-slate-500">
            <span className="mt-0.5 text-slate-400">
              <Icon name="server" size={18} />
            </span>
            <p className="leading-relaxed">
              Steps run on the platform runner. Turn on dispatch above to target a
              fleet — for example every production web server, in parallel, with
              the run continuing past a node that fails.
            </p>
          </div>
        </Card>
      ) : (
        <>
          <Card className="p-6">
            <h3 className="mb-4 text-sm font-semibold text-slate-900">
              Which nodes
            </h3>
            <label className={label}>Node filter</label>
            <input
              value={nodes.filter || ""}
              onChange={(e) => set("filter", e.target.value)}
              placeholder="tags: web+prod"
              className={`${inputCls} font-mono`}
            />
            <div className="mt-2 space-y-1 text-[11px] leading-relaxed text-slate-500">
              <p>
                <code className="font-mono">tags: web+prod</code> — nodes carrying
                BOTH tags. <code className="font-mono">tags: web,db</code> — either.
              </p>
              <p>
                <code className="font-mono">name: web-0.*</code> matches by name;
                any node attribute works the same way.
              </p>
              <p className="text-amber-700">
                An empty filter targets every node in the project. Be deliberate.
              </p>
            </div>
          </Card>

          <Card className="p-6">
            <h3 className="mb-4 text-sm font-semibold text-slate-900">
              How they run
            </h3>
            <div className="grid gap-5 md:grid-cols-2">
              <div>
                <label className={label}>Parallel nodes</label>
                <input
                  type="number"
                  min="1"
                  max="100"
                  value={nodes.threadcount ?? 1}
                  onChange={(e) =>
                    set("threadcount", Math.max(1, Number(e.target.value) || 1))
                  }
                  className={inputCls}
                />
                <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
                  How many nodes are worked on at once. 1 is one after another —
                  slower, and far easier to stop when something is going wrong.
                </p>
              </div>
              <div>
                <label className={label}>If a node fails</label>
                <select
                  value={nodes.keepgoing ? "continue" : "stop"}
                  onChange={(e) => set("keepgoing", e.target.value === "continue")}
                  className={inputCls}
                >
                  <option value="stop">Stop the run</option>
                  <option value="continue">Continue on the remaining nodes</option>
                </select>
                <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
                  Continuing finishes the fleet and reports which nodes failed —
                  useful for a patch sweep, dangerous for a rolling deploy.
                </p>
              </div>
            </div>

            <div className="mt-5 grid gap-5 md:grid-cols-2">
              <div>
                <label className={label}>Order by attribute</label>
                <input
                  value={nodes.rankAttribute || ""}
                  onChange={(e) => set("rankAttribute", e.target.value)}
                  placeholder="hostname"
                  className={inputCls}
                />
                <p className="mt-1 text-[11px] text-slate-500">
                  Optional. Gives the fleet a predictable order instead of an
                  arbitrary one.
                </p>
              </div>
              <div>
                <label className={label}>Direction</label>
                <select
                  value={nodes.rankOrder || "ascending"}
                  onChange={(e) => set("rankOrder", e.target.value)}
                  className={inputCls}
                  disabled={!nodes.rankAttribute}
                >
                  <option value="ascending">Ascending</option>
                  <option value="descending">Descending</option>
                </select>
              </div>
            </div>
          </Card>
        </>
      )}
    </div>
  );
}
