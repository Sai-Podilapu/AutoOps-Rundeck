/**
 * A third party's own logo — model vendors, notification channels.
 *
 * Falls back to a generic glyph when there is no file for a brand, or when the
 * file fails to load. That matters more than it sounds: the vendor list comes
 * from the backend catalog, so a vendor can be added there before anyone
 * supplies artwork for it, and a bare broken-image icon in a card reads as a
 * bug rather than as a missing asset.
 */

import React, { useState } from "react";
import Icon from "../Icon";

export default function BrandLogo({
  src,
  alt,
  fallbackIcon = "sparkles",
  className = "",
}) {
  const [failed, setFailed] = useState(false);
  const showFallback = !src || failed;

  // Sized so the mark is the first thing read on a card — a logo small enough
  // to need squinting at defeats the point of having one. Both surfaces take
  // their size from here, so they cannot drift apart.
  return (
    <span
      className={`flex h-11 w-11 shrink-0 items-center justify-center overflow-hidden rounded-lg ${
        showFallback ? "bg-slate-100 text-slate-600" : "bg-white ring-1 ring-slate-200"
      } ${className}`}
    >
      {showFallback ? (
        <Icon name={fallbackIcon} size={22} />
      ) : (
        <img
          src={src}
          alt={alt}
          loading="lazy"
          onError={() => setFailed(true)}
          className="h-8 w-8 object-contain"
        />
      )}
    </span>
  );
}
