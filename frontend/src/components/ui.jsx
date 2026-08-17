import React from "react";
import { Link } from "react-router-dom";

/* ---------------- buttons ---------------- */
export const PrimaryButton = ({
  children,
  to,
  href,
  className = "",
  ...rest
}) => {
  const cls = `group inline-flex items-center justify-center gap-2 rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition duration-300 hover:bg-blue-600 hover:shadow-xl hover:shadow-blue-300/40 ${className}`;
  if (to)
    return (
      <Link to={to} className={cls} {...rest}>
        {children}
      </Link>
    );
  return (
    <a href={href || "#"} className={cls} {...rest}>
      {children}
    </a>
  );
};

export const GhostButton = ({
  children,
  to,
  href,
  className = "",
  ...rest
}) => {
  const cls = `inline-flex items-center justify-center gap-2 rounded-lg border border-slate-200 bg-slate-50 px-6 py-3 text-sm font-semibold text-slate-900 transition duration-300 hover:border-blue-500 hover:bg-slate-100 ${className}`;
  if (to)
    return (
      <Link to={to} className={cls} {...rest}>
        {children}
      </Link>
    );
  return (
    <a href={href || "#"} className={cls} {...rest}>
      {children}
    </a>
  );
};

export const Pill = ({ children }) => (
  <span className="inline-flex items-center gap-2 rounded-full border border-slate-300 bg-slate-100 px-4 py-1.5 text-xs font-medium text-slate-900">
    {children}
  </span>
);

export const SectionHeading = ({
  eyebrow,
  title,
  subtitle,
  className = "",
}) => (
  <div className={`mx-auto max-w-3xl text-center ${className}`}>
    {eyebrow && (
      <p className="mb-3 text-xs font-semibold uppercase tracking-[0.25em] text-slate-900">
        {eyebrow}
      </p>
    )}
    <h2 className="text-4xl font-bold tracking-tight text-slate-900 sm:text-5xl">
      {title}
    </h2>
    {subtitle && (
      <p className="mt-4 text-base leading-relaxed text-slate-500 sm:text-lg">
        {subtitle}
      </p>
    )}
  </div>
);

/* ---------------- logo ----------------
   logo.png is the AutoOps wordmark (wide). `size` is treated as the render
   HEIGHT; width is auto so the aspect ratio is always preserved. */
export function LogoMark({ size = 32, className = "" }) {
  // Scale up the size significantly to counteract the PNG's large transparent padding
  const style = { height: size * 2.3, width: "auto", maxWidth: "none" };
  return (
    <div className={`flex items-center justify-center overflow-hidden -my-8 ${className}`}>
      <img
        src="/logo.png"
        alt="AutoOps"
        style={style}
        className="object-contain"
      />
    </div>
  );
}

export function Logo({ className = "" }) {
  return (
    <Link to="/" className={`flex items-center ${className}`}>
      <LogoMark />
    </Link>
  );
}
