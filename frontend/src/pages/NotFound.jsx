import React from "react";
import { Link } from "react-router-dom";
import { LogoMark, PrimaryButton, GhostButton } from "../components/ui";

export default function NotFound() {
  return (
    <div className="grid-bg relative flex min-h-screen flex-col items-center justify-center overflow-hidden bg-white px-6 text-center">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-1/3 h-[420px] w-[620px] -translate-x-1/2 rounded-full bg-slate-100 blur-[150px]" />
      </div>
      <Link to="/" className="mb-10 flex items-center gap-2.5">
        <LogoMark size={34} />
      </Link>
      <p className="gradient-text text-7xl font-extrabold">404</p>
      <h1 className="mt-4 text-2xl font-bold text-slate-900">
        This page wandered off
      </h1>
      <p className="mt-2 max-w-md text-sm text-slate-500">
        The page you’re looking for doesn’t exist or may have moved.
      </p>
      <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
        <PrimaryButton to="/app/projects">Go to console</PrimaryButton>
        <GhostButton to="/">Back home</GhostButton>
      </div>
    </div>
  );
}
