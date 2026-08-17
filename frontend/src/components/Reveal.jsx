import React, { useEffect, useRef, useState } from "react";

/**
 * Wraps children and reveals them with a fade-up animation when scrolled
 * into view (IntersectionObserver). Use `delay` (ms) to stagger siblings.
 */
export default function Reveal({
  children,
  delay = 0,
  as: Tag = "div",
  className = "",
  threshold = 0.15,
  repeat = false,
}) {
  const ref = useRef(null);
  const [shown, setShown] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setShown(true);
          if (!repeat) io.disconnect();
        } else if (repeat) {
          setShown(false);
        }
      },
      { threshold },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [threshold]);

  return (
    <Tag
      ref={ref}
      style={{ transitionDelay: `${delay}ms` }}
      className={`reveal ${shown ? "in-view" : ""} ${className}`}
    >
      {children}
    </Tag>
  );
}
