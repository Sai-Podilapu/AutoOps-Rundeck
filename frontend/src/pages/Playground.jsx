import React, {
    useCallback,
    useEffect,
    useMemo,
    useRef,
    useState,
} from "react";
import { Link } from "react-router-dom";
import Navbar from "../components/Navbar";
import Footer from "../components/Footer";
import Icon from "../components/Icon";
import { Pill, PrimaryButton, GhostButton } from "../components/ui";

/* Public, no-login playground. A self-contained clone of the in-app Workflow
   Designer that keeps all state locally (no store, no auth, no RBAC) so any
   visitor can drag, connect, and "run" a pipeline without signing in. */

const sx = (o) => o;
const NODE_W = 210;
const NODE_H = 76;

const CATALOG = [
    {
        type: "trigger",
        label: "Schedule Trigger",
        sub: "cron · 0 0 * * *",
        icon: "clock",
        color: "#0891b2",
        kind: "trigger",
    },
    {
        type: "webhook",
        label: "Webhook",
        sub: "POST /deploy",
        icon: "webhook",
        color: "#0891b2",
        kind: "trigger",
    },
    {
        type: "build",
        label: "Build Image",
        sub: "docker build",
        icon: "cube",
        color: "#7c3aed",
        kind: "action",
    },
    {
        type: "terraform",
        label: "Terraform",
        sub: "plan & apply",
        icon: "cloud",
        color: "#7c3aed",
        kind: "action",
    },
    {
        type: "script",
        label: "Run Script",
        sub: "bash",
        icon: "terminal",
        color: "#2563eb",
        kind: "action",
    },
    {
        type: "approval",
        label: "Approval Gate",
        sub: "manual sign-off",
        icon: "check",
        color: "#d97706",
        kind: "action",
    },
    {
        type: "k8s",
        label: "Deploy K8s",
        sub: "rollout restart",
        icon: "k8s",
        color: "#059669",
        kind: "action",
    },
    {
        type: "notify",
        label: "Notify Slack",
        sub: "#ops-deploys",
        icon: "bell",
        color: "#059669",
        kind: "action",
    },
];
const catalogByType = Object.fromEntries(CATALOG.map((c) => [c.type, c]));

const initialNodes = [
    { id: "n1", type: "trigger", x: 80, y: 250 },
    { id: "n2", type: "build", x: 400, y: 130 },
    { id: "n3", type: "terraform", x: 400, y: 360 },
    { id: "n4", type: "approval", x: 720, y: 250 },
    { id: "n5", type: "k8s", x: 1040, y: 170 },
    { id: "n6", type: "notify", x: 1040, y: 340 },
];
const initialEdges = [
    { id: "e1", from: "n1", to: "n2" },
    { id: "e2", from: "n1", to: "n3" },
    { id: "e3", from: "n2", to: "n4" },
    { id: "e4", from: "n3", to: "n4" },
    { id: "e5", from: "n4", to: "n5" },
    { id: "e6", from: "n4", to: "n6" },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function edgePath(a, b) {
    const x1 = a.x + NODE_W,
        y1 = a.y + NODE_H / 2;
    const x2 = b.x,
        y2 = b.y + NODE_H / 2;
    const dx = Math.max(60, Math.abs(x2 - x1) / 2);
    return `M ${x1} ${y1} C ${x1 + dx} ${y1}, ${x2 - dx} ${y2}, ${x2} ${y2}`;
}

const toastTone = {
    emerald: "border-emerald-400/40 bg-emerald-50 text-emerald-700",
    cyan: "border-slate-300 bg-slate-50 text-slate-700",
    red: "border-red-400/40 bg-red-50 text-red-700",
};

export default function Playground() {
    const [name, setName] = useState("Production Deploy Pipeline");
    const [active, setActive] = useState(true);
    const [nodes, setNodes] = useState(initialNodes);
    const [edges, setEdges] = useState(initialEdges);
    const [selectedId, setSelectedId] = useState(null);
    const [status, setStatus] = useState({});
    const [running, setRunning] = useState(false);
    const [scale, setScale] = useState(0.85);
    const [tx, setTx] = useState(40);
    const [ty, setTy] = useState(10);
    const [linkFrom, setLinkFrom] = useState(null);
    const [linkPos, setLinkPos] = useState(null);
    const [locked, setLocked] = useState(false);
    const [toast, setToast] = useState(null);

    const canvasRef = useRef(null);
    const dragRef = useRef(null);
    const hoverRef = useRef(null);
    const scaleRef = useRef(scale);
    const txRef = useRef(tx);
    const tyRef = useRef(ty);
    const toastTimer = useRef(null);
    useEffect(() => {
        window.scrollTo(0, 0);
    }, []);
    useEffect(() => {
        scaleRef.current = scale;
    }, [scale]);
    useEffect(() => {
        txRef.current = tx;
    }, [tx]);
    useEffect(() => {
        tyRef.current = ty;
    }, [ty]);
    useEffect(() => () => clearTimeout(toastTimer.current), []);

    const pushToast = useCallback((msg, tone = "cyan") => {
        setToast({ msg, tone });
        clearTimeout(toastTimer.current);
        toastTimer.current = setTimeout(() => setToast(null), 2400);
    }, []);

    const nodeById = useMemo(
        () => Object.fromEntries(nodes.map((n) => [n.id, n])),
        [nodes],
    );
    const selected = selectedId ? nodeById[selectedId] : null;

    const worldFromClient = useCallback((cx, cy) => {
        const r = canvasRef.current.getBoundingClientRect();
        return {
            x: (cx - r.left - txRef.current) / scaleRef.current,
            y: (cy - r.top - tyRef.current) / scaleRef.current,
        };
    }, []);

    useEffect(() => {
        const onMove = (e) => {
            const d = dragRef.current;
            if (!d) return;
            if (d.mode === "pan") {
                setTx(d.otx + (e.clientX - d.sx));
                setTy(d.oty + (e.clientY - d.sy));
            } else if (d.mode === "node") {
                const ndx = (e.clientX - d.sx) / scaleRef.current;
                const ndy = (e.clientY - d.sy) / scaleRef.current;
                setNodes((ns) =>
                    ns.map((n) =>
                        n.id === d.id ? { ...n, x: d.ox + ndx, y: d.oy + ndy } : n,
                    ),
                );
            } else if (d.mode === "link") {
                setLinkPos(worldFromClient(e.clientX, e.clientY));
            }
        };
        const onUp = () => {
            const d = dragRef.current;
            if (d && d.mode === "link") {
                const to = hoverRef.current;
                const from = d.id;
                if (to && to !== from) {
                    setEdges((es) =>
                        es.some((e) => e.from === from && e.to === to)
                            ? es
                            : [...es, { id: "e" + Date.now(), from, to }],
                    );
                }
                setLinkFrom(null);
                setLinkPos(null);
            }
            dragRef.current = null;
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", onUp);
        return () => {
            window.removeEventListener("pointermove", onMove);
            window.removeEventListener("pointerup", onUp);
        };
    }, [worldFromClient]);

    const startPan = (e) => {
        if (e.button !== 0) return;
        setSelectedId(null);
        if (locked) return;
        dragRef.current = {
            mode: "pan",
            sx: e.clientX,
            sy: e.clientY,
            otx: tx,
            oty: ty,
        };
    };
    const startNode = (e, n) => {
        e.stopPropagation();
        setSelectedId(n.id);
        if (canvasRef.current) canvasRef.current.focus();
        if (locked) return;
        dragRef.current = {
            mode: "node",
            id: n.id,
            sx: e.clientX,
            sy: e.clientY,
            ox: n.x,
            oy: n.y,
        };
    };
    const startLink = (e, n) => {
        e.stopPropagation();
        if (locked) return;
        dragRef.current = { mode: "link", id: n.id };
        setLinkFrom(n.id);
        setLinkPos({ x: n.x + NODE_W, y: n.y + NODE_H / 2 });
    };

    const zoom = (dir) =>
        setScale((s) => Math.min(1.6, Math.max(0.4, +(s + dir * 0.15).toFixed(2))));
    const resetView = () => {
        setScale(0.85);
        setTx(40);
        setTy(10);
    };
    const onWheel = (e) => {
        if (locked) return;
        setScale((s) =>
            Math.min(
                1.6,
                Math.max(0.4, +(s - Math.sign(e.deltaY) * 0.08).toFixed(2)),
            ),
        );
    };

    const addNode = (type) => {
        const id = "n" + Date.now();
        const p = worldFromClient(
            canvasRef.current.getBoundingClientRect().width / 2,
            220,
        );
        setNodes((ns) => [...ns, { id, type, x: p.x - NODE_W / 2, y: p.y }]);
        setSelectedId(id);
        pushToast(`Added ${catalogByType[type].label}`, "cyan");
    };
    const removeNode = (id) => {
        setNodes((ns) => ns.filter((n) => n.id !== id));
        setEdges((es) => es.filter((e) => e.from !== id && e.to !== id));
        setSelectedId(null);
    };
    const removeEdge = (id) => setEdges((es) => es.filter((e) => e.id !== id));

    const onDragOver = (e) => {
        if (!locked) e.preventDefault();
    };
    const onDrop = (e) => {
        e.preventDefault();
        if (locked) return;
        const type = e.dataTransfer.getData("application/rw-node");
        if (!type || !catalogByType[type]) return;
        const p = worldFromClient(e.clientX, e.clientY);
        const id = "n" + Date.now();
        setNodes((ns) => [
            ...ns,
            { id, type, x: p.x - NODE_W / 2, y: p.y - NODE_H / 2 },
        ]);
        setSelectedId(id);
        pushToast(`Added ${catalogByType[type].label}`, "cyan");
    };

    const resetCanvas = () => {
        setNodes(initialNodes);
        setEdges(initialEdges);
        setStatus({});
        setSelectedId(null);
        resetView();
        pushToast("Canvas reset", "cyan");
    };

    const save = () =>
        pushToast("This is a demo — sign up free to save your work", "emerald");

    const onKeyDown = (e) => {
        if (e.key === "Escape") {
            setSelectedId(null);
            return;
        }
        if (!selectedId) {
            if (e.key === "+" || e.key === "=") zoom(1);
            else if (e.key === "-" || e.key === "_") zoom(-1);
            return;
        }
        if ((e.key === "Delete" || e.key === "Backspace") && !locked) {
            e.preventDefault();
            removeNode(selectedId);
        } else if (e.key.startsWith("Arrow") && !locked) {
            e.preventDefault();
            const step = e.shiftKey ? 40 : 10;
            const dx =
                e.key === "ArrowLeft" ? -step : e.key === "ArrowRight" ? step : 0;
            const dy = e.key === "ArrowUp" ? -step : e.key === "ArrowDown" ? step : 0;
            setNodes((ns) =>
                ns.map((n) =>
                    n.id === selectedId ? { ...n, x: n.x + dx, y: n.y + dy } : n,
                ),
            );
        }
    };

    const order = useMemo(() => {
        const incoming = {};
        nodes.forEach((n) => {
            incoming[n.id] = 0;
        });
        edges.forEach((e) => {
            if (incoming[e.to] != null) incoming[e.to] += 1;
        });
        const queue = nodes.filter((n) => incoming[n.id] === 0).map((n) => n.id);
        const seen = new Set(queue);
        const out = [];
        while (queue.length) {
            const id = queue.shift();
            out.push(id);
            edges
                .filter((e) => e.from === id)
                .forEach((e) => {
                    if (!seen.has(e.to)) {
                        seen.add(e.to);
                        queue.push(e.to);
                    }
                });
        }
        nodes.forEach((n) => {
            if (!out.includes(n.id)) out.push(n.id);
        });
        return out;
    }, [nodes, edges]);

    const run = async () => {
        if (running) return;
        setRunning(true);
        setStatus({});
        await sleep(150);
        for (const id of order) {
            setStatus((s) => ({ ...s, [id]: "running" }));
            setSelectedId(id);
            await sleep(720);
            setStatus((s) => ({ ...s, [id]: "success" }));
            await sleep(130);
        }
        setRunning(false);
        pushToast("Workflow executed successfully", "emerald");
    };

    return (
        <div className="min-h-screen bg-white text-slate-700">
            <Navbar />
            <main>
                <section className="grid-bg relative overflow-hidden">
                    <div className="pointer-events-none absolute inset-0 -z-10">
                        <div className="animate-float-glow absolute left-1/2 top-[-30%] h-[380px] w-[620px] rounded-full bg-slate-100 blur-[150px]" />
                    </div>
                    <div className="mx-auto max-w-7xl px-6 pb-8 pt-16">
                        <Link
                            to="/"
                            className="text-sm text-slate-500 transition hover:text-slate-900"
                        >
                            ← Back to home
                        </Link>
                        <div className="mt-5 flex flex-wrap items-end justify-between gap-6">
                            <div>
                                <span className="inline-flex">
                                    <Pill>
                                        <span className="animate-pulse-dot h-2 w-2 rounded-full bg-emerald-400" />
                                        Live demo · no login needed
                                    </Pill>
                                </span>
                                <h1 className="mt-5 max-w-2xl font-serif text-4xl font-bold leading-[1.1] tracking-tight text-slate-900 sm:text-5xl">
                                    Try the Workflow Designer
                                </h1>
                                <p className="mt-4 max-w-xl text-base leading-relaxed text-slate-500">
                                    Drag nodes onto the canvas, connect them into a DAG, and hit
                                    Execute to watch a simulated run flow through your pipeline.
                                    Nothing here is saved — it's a real sandbox to play in.
                                </p>
                            </div>
                            <div className="flex flex-wrap gap-3">
                                <PrimaryButton to="/signup">Sign up free →</PrimaryButton>
                                <GhostButton to="/demo">Book a demo</GhostButton>
                            </div>
                        </div>
                    </div>
                </section>

                <section className="mx-auto max-w-7xl px-6 pb-24 pt-4">
                    <div className="mb-4 flex flex-wrap items-center gap-3">
                        <input
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            aria-label="Workflow name"
                            className="min-w-[220px] rounded-lg border border-transparent bg-transparent px-2 py-1 text-lg font-bold text-slate-900 outline-none transition hover:border-blue-500 focus:border-slate-300"
                        />
                        <button
                            onClick={() => setActive((v) => !v)}
                            className={`flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium transition ${active ? "border-emerald-400/30 bg-emerald-400/10 text-emerald-600" : "border-slate-200 bg-slate-50 text-slate-500"}`}
                        >
                            <span
                                className={`h-1.5 w-1.5 rounded-full ${active ? "animate-pulse-dot bg-emerald-400" : "bg-slate-500"}`}
                            />{" "}
                            {active ? "Active" : "Inactive"}
                        </button>
                        <div className="ml-auto flex items-center gap-2">
                            <button
                                onClick={resetCanvas}
                                className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 transition hover:border-blue-500"
                            >
                                <Icon name="radar" size={16} /> Reset
                            </button>
                            <button
                                onClick={() => addNode("script")}
                                className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 transition hover:border-blue-500"
                            >
                                <Icon name="plus" size={16} /> Add node
                            </button>
                            <button
                                onClick={save}
                                className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700 transition hover:border-blue-500"
                            >
                                <Icon name="check" size={16} /> Save
                            </button>
                            <button
                                onClick={run}
                                disabled={running}
                                className="flex items-center gap-1.5 rounded-lg bg-gradient-to-r from-slate-900 to-slate-900 px-4 py-2 text-sm font-semibold text-white transition hover:opacity-90 disabled:opacity-50"
                            >
                                <Icon name="play" size={16} />{" "}
                                {running ? "Executing…" : "Execute workflow"}
                            </button>
                        </div>
                    </div>

                    <div className="flex flex-col gap-4 lg:flex-row">
                        <div
                            ref={canvasRef}
                            tabIndex={0}
                            role="application"
                            aria-label="Workflow canvas. Click a node to select; Delete removes it, arrow keys move it, Escape deselects."
                            onKeyDown={onKeyDown}
                            onPointerDown={startPan}
                            onWheel={onWheel}
                            onDragOver={onDragOver}
                            onDrop={onDrop}
                            className={`rw-dots relative h-[460px] flex-1 overflow-hidden rounded-2xl border border-slate-200 outline-none focus-visible:ring-2 focus-visible:ring-slate-300 sm:h-[560px] lg:h-[640px] ${locked ? "" : "rw-canvas"}`}
                        >
                            <div
                                className="absolute left-0 top-0 origin-top-left"
                                style={sx({
                                    transform: `translate(${tx}px, ${ty}px) scale(${scale})`,
                                })}
                            >
                                <svg
                                    width="4200"
                                    height="2400"
                                    className="absolute left-0 top-0 overflow-visible"
                                >
                                    <defs>
                                        <marker
                                            id="rw-arrow"
                                            markerWidth="10"
                                            markerHeight="10"
                                            refX="8"
                                            refY="3"
                                            orient="auto"
                                            markerUnits="userSpaceOnUse"
                                        >
                                            <path d="M0,0 L8,3 L0,6 Z" fill="#475569" />
                                        </marker>
                                    </defs>
                                    {edges.map((e) => {
                                        const a = nodeById[e.from];
                                        const b = nodeById[e.to];
                                        if (!a || !b) return null;
                                        const d = edgePath(a, b);
                                        const activeEdge = status[e.from] === "success";
                                        return (
                                            <g key={e.id}>
                                                <path
                                                    d={d}
                                                    fill="none"
                                                    stroke="#f1f5f9"
                                                    strokeWidth="4"
                                                />
                                                <path
                                                    d={d}
                                                    fill="none"
                                                    stroke={activeEdge ? "#059669" : "#94a3b8"}
                                                    strokeWidth="2.5"
                                                    className={activeEdge ? "rw-flow" : ""}
                                                    markerEnd="url(#rw-arrow)"
                                                />
                                                {activeEdge && (
                                                    <circle r="4" fill="#10b981">
                                                        <animateMotion
                                                            dur="0.9s"
                                                            repeatCount="indefinite"
                                                            path={d}
                                                        />
                                                    </circle>
                                                )}
                                                <path
                                                    d={d}
                                                    fill="none"
                                                    stroke="transparent"
                                                    strokeWidth="16"
                                                    className="pointer-events-auto cursor-pointer"
                                                    onPointerDown={(ev) => ev.stopPropagation()}
                                                    onClick={() => removeEdge(e.id)}
                                                />
                                            </g>
                                        );
                                    })}
                                    {linkFrom &&
                                        linkPos &&
                                        nodeById[linkFrom] &&
                                        (() => {
                                            const a = nodeById[linkFrom];
                                            const d = `M ${a.x + NODE_W} ${a.y + NODE_H / 2} C ${a.x + NODE_W + 80} ${a.y + NODE_H / 2}, ${linkPos.x - 80} ${linkPos.y}, ${linkPos.x} ${linkPos.y}`;
                                            return (
                                                <path
                                                    d={d}
                                                    fill="none"
                                                    stroke="#22d3ee"
                                                    strokeWidth="2.5"
                                                    strokeDasharray="5 5"
                                                />
                                            );
                                        })()}
                                </svg>

                                {nodes.map((n) => {
                                    const cat = catalogByType[n.type] || catalogByType.script;
                                    const st = status[n.id];
                                    const ring =
                                        st === "running"
                                            ? "border-blue-500 ring-4 ring-blue-100"
                                            : st === "success"
                                                ? "border-emerald-500 ring-4 ring-emerald-100"
                                                : selectedId === n.id
                                                    ? "border-slate-400 ring-4 ring-slate-100"
                                                    : "border-slate-200 hover:border-blue-500";
                                    return (
                                        <div
                                            key={n.id}
                                            onPointerDown={(e) => startNode(e, n)}
                                            style={sx({
                                                left: n.x + "px",
                                                top: n.y + "px",
                                                width: NODE_W + "px",
                                            })}
                                            className={`group absolute select-none rounded-2xl bg-white shadow-sm border ${cat.kind === "trigger" ? "rounded-l-[40px]" : ""} ${ring} cursor-move transition-all`}
                                        >
                                            <div
                                                className="flex items-center gap-3 px-3"
                                                style={sx({ minHeight: NODE_H + "px" })}
                                            >
                                                <span
                                                    className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl"
                                                    style={sx({
                                                        backgroundColor: cat.color + "22",
                                                        color: cat.color,
                                                    })}
                                                >
                                                    <Icon name={cat.icon} size={20} />
                                                </span>
                                                <div className="min-w-0">
                                                    <p className="truncate text-sm font-semibold text-slate-900">
                                                        {cat.label}
                                                    </p>
                                                    <p className="truncate font-mono text-[11px] text-slate-500">
                                                        {cat.sub}
                                                    </p>
                                                </div>
                                            </div>
                                            {st === "running" && (
                                                <span className="rw-spin absolute -right-2 -top-2 block h-5 w-5 rounded-full border-2 border-slate-300 border-t-transparent bg-[#e2e8f0]" />
                                            )}
                                            {st === "success" && (
                                                <span className="absolute -right-2 -top-2 flex h-5 w-5 items-center justify-center rounded-full bg-emerald-400 text-white">
                                                    <Icon name="check" size={12} />
                                                </span>
                                            )}
                                            {cat.kind !== "trigger" && (
                                                <span
                                                    aria-label="Input connector"
                                                    onPointerEnter={() => {
                                                        hoverRef.current = n.id;
                                                    }}
                                                    onPointerLeave={() => {
                                                        if (hoverRef.current === n.id)
                                                            hoverRef.current = null;
                                                    }}
                                                    className="absolute -left-1.5 top-1/2 h-3 w-3 -translate-y-1/2 rounded-full border-2 border-[#e2e8f0] bg-slate-500"
                                                />
                                            )}
                                            <span
                                                role="button"
                                                aria-label="Output: drag to connect"
                                                onPointerDown={(e) => startLink(e, n)}
                                                className="absolute -right-1.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 cursor-crosshair rounded-full border-2 border-[#e2e8f0] bg-slate-100 transition hover:scale-125"
                                            />
                                        </div>
                                    );
                                })}
                            </div>

                            <div className="absolute bottom-4 left-4 flex items-center gap-1 rounded-lg border border-slate-200 bg-slate-900/40 p-1 backdrop-blur">
                                <button
                                    onClick={() => zoom(-1)}
                                    aria-label="Zoom out"
                                    className="flex h-7 w-7 items-center justify-center rounded text-slate-600 transition hover:bg-slate-100"
                                >
                                    −
                                </button>
                                <span className="w-12 text-center text-xs text-slate-500">
                                    {Math.round(scale * 100)}%
                                </span>
                                <button
                                    onClick={() => zoom(1)}
                                    aria-label="Zoom in"
                                    className="flex h-7 w-7 items-center justify-center rounded text-slate-600 transition hover:bg-slate-100"
                                >
                                    +
                                </button>
                                <button
                                    onClick={resetView}
                                    title="Reset view"
                                    className="flex h-7 w-7 items-center justify-center rounded text-slate-600 transition hover:bg-slate-100"
                                >
                                    <Icon name="radar" size={14} />
                                </button>
                                <span className="mx-0.5 h-5 w-px bg-slate-50" />
                                <button
                                    onClick={() => setLocked((v) => !v)}
                                    title={locked ? "Unlock canvas" : "Lock canvas"}
                                    aria-label={locked ? "Unlock canvas" : "Lock canvas"}
                                    className={`flex h-7 w-7 items-center justify-center rounded transition ${locked ? "bg-amber-400/20 text-amber-600" : "text-slate-600 hover:bg-slate-100"}`}
                                >
                                    <Icon name="lock" size={14} />
                                </button>
                            </div>
                            <div className="pointer-events-none absolute right-4 top-4 rounded-lg border border-slate-200 bg-slate-900/30 px-3 py-1.5 text-[11px] text-slate-500 backdrop-blur">
                                {locked
                                    ? "🔒 Canvas locked"
                                    : "Drag canvas to pan · drag a node's blue dot to connect · drop nodes from the panel"}
                            </div>
                        </div>

                        <aside className="w-full shrink-0 lg:w-[300px]">
                            {selected ? (
                                <div className="rw-pop rounded-2xl border border-slate-200 bg-[#ffffff] p-4">
                                    <div className="mb-4 flex items-start justify-between">
                                        <div className="flex items-center gap-3">
                                            <span
                                                className="flex h-10 w-10 items-center justify-center rounded-xl"
                                                style={sx({
                                                    backgroundColor:
                                                        (
                                                            catalogByType[selected.type] ||
                                                            catalogByType.script
                                                        ).color + "22",
                                                    color: (
                                                        catalogByType[selected.type] || catalogByType.script
                                                    ).color,
                                                })}
                                            >
                                                <Icon
                                                    name={
                                                        (
                                                            catalogByType[selected.type] ||
                                                            catalogByType.script
                                                        ).icon
                                                    }
                                                    size={20}
                                                />
                                            </span>
                                            <div>
                                                <p className="text-sm font-semibold text-slate-900">
                                                    {
                                                        (
                                                            catalogByType[selected.type] ||
                                                            catalogByType.script
                                                        ).label
                                                    }
                                                </p>
                                                <p className="font-mono text-[11px] text-slate-500">
                                                    {selected.id}
                                                </p>
                                            </div>
                                        </div>
                                        <button
                                            onClick={() => setSelectedId(null)}
                                            className="text-slate-500 transition hover:text-slate-900"
                                        >
                                            <Icon name="chevron" size={16} className="rotate-90" />
                                        </button>
                                    </div>
                                    <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-600">
                                        Parameters
                                    </p>
                                    <div className="space-y-3">
                                        <label className="block">
                                            <span className="mb-1 block text-xs text-slate-500">
                                                Display name
                                            </span>
                                            <input
                                                defaultValue={
                                                    (catalogByType[selected.type] || catalogByType.script)
                                                        .label
                                                }
                                                className="w-full rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-2 text-sm text-slate-900 outline-none focus:border-slate-300"
                                            />
                                        </label>
                                        <label className="block">
                                            <span className="mb-1 block text-xs text-slate-500">
                                                Command / config
                                            </span>
                                            <input
                                                defaultValue={
                                                    (catalogByType[selected.type] || catalogByType.script)
                                                        .sub
                                                }
                                                className="w-full rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-2 font-mono text-xs text-slate-900 outline-none focus:border-slate-300"
                                            />
                                        </label>
                                        <label className="block">
                                            <span className="mb-1 block text-xs text-slate-500">
                                                On failure
                                            </span>
                                            <select className="w-full rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-2 text-sm text-slate-900 outline-none focus:border-slate-300">
                                                <option>Stop workflow</option>
                                                <option>Continue</option>
                                                <option>Retry 3x</option>
                                            </select>
                                        </label>
                                    </div>
                                    <div className="mt-4 flex gap-2">
                                        <button
                                            onClick={run}
                                            className="flex flex-1 items-center justify-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-700 transition hover:border-blue-500"
                                        >
                                            <Icon name="play" size={14} /> Test step
                                        </button>
                                        <button
                                            onClick={() => removeNode(selected.id)}
                                            className="rounded-lg border border-slate-200 px-3 py-2 text-xs text-slate-500 transition hover:border-red-400/40 hover:text-red-600"
                                        >
                                            Delete
                                        </button>
                                    </div>
                                </div>
                            ) : (
                                <div className="rounded-2xl border border-slate-200 bg-[#ffffff] p-4">
                                    <p className="mb-1 text-sm font-semibold text-slate-900">
                                        Add a node
                                    </p>
                                    <p className="mb-3 text-xs text-slate-500">
                                        Click or drag a node onto the canvas, then drag from a
                                        node's blue handle to connect.
                                    </p>
                                    <div className="space-y-1.5">
                                        {CATALOG.map((c) => (
                                            <button
                                                key={c.type}
                                                draggable
                                                onDragStart={(e) =>
                                                    e.dataTransfer.setData("application/rw-node", c.type)
                                                }
                                                onClick={() => addNode(c.type)}
                                                className="flex w-full cursor-grab items-center gap-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-left transition hover:border-blue-500 hover:bg-slate-100 active:cursor-grabbing"
                                            >
                                                <span
                                                    className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg"
                                                    style={sx({
                                                        backgroundColor: c.color + "22",
                                                        color: c.color,
                                                    })}
                                                >
                                                    <Icon name={c.icon} size={16} />
                                                </span>
                                                <span className="min-w-0">
                                                    <span className="block truncate text-sm text-slate-900">
                                                        {c.label}
                                                    </span>
                                                    <span className="block truncate text-[11px] text-slate-500">
                                                        {c.kind === "trigger" ? "Trigger" : "Action"}
                                                    </span>
                                                </span>
                                            </button>
                                        ))}
                                    </div>
                                </div>
                            )}
                        </aside>
                    </div>
                </section>
            </main>
            <Footer />

            {toast && (
                <div
                    className={`fixed bottom-6 left-1/2 z-50 -translate-x-1/2 rounded-lg border px-4 py-2.5 text-sm font-medium shadow-lg ${toastTone[toast.tone] || toastTone.cyan}`}
                    role="status"
                >
                    {toast.msg}
                </div>
            )}
        </div>
    );
}