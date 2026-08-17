import React from "react";
import Reveal from "../components/Reveal";
import { PrimaryButton, GhostButton } from "../components/ui";

export default function FinalCTA() {
  return (
    <section id="start" className="relative overflow-hidden px-6 py-28">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-1/2 h-[360px] w-[640px] -translate-y-1/2 rounded-full bg-emerald-500/15 blur-[150px]" />
      </div>
      <Reveal className="mx-auto max-w-3xl text-center">
        <h2 className="text-4xl font-extrabold tracking-tight text-slate-900 sm:text-5xl">
          Ship operations at the speed of{" "}
          <span className="gradient-text">code</span>
        </h2>
        <p className="mx-auto mt-5 max-w-xl text-base text-slate-500 sm:text-lg">
          Deploy AutoOps in minutes and give every team a safe, auditable way to
          automate the infrastructure they own.
        </p>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
          <PrimaryButton to="/login">Get Started Free →</PrimaryButton>
          <GhostButton to="/docs">Read the Docs</GhostButton>
        </div>
      </Reveal>
    </section>
  );
}
