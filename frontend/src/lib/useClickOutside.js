import { useEffect, useRef } from "react";

/**
 * Close a popover when a pointer press lands outside `ref`.
 *
 * Prefer this to a `fixed inset-0` catcher div. A catcher only covers the
 * viewport when no ancestor is transformed or filtered, and both app shells put
 * their menus inside a `backdrop-blur-md` header — a backdrop-filter makes that
 * header the containing block for fixed descendants, so the catcher shrinks to
 * the header strip and clicks in the page body never dismiss the menu.
 *
 * `active` keeps the listener off while the popover is closed.
 */
export default function useClickOutside(ref, onOutside, active = true) {
  const cb = useRef(onOutside);
  cb.current = onOutside;

  useEffect(() => {
    if (!active) return undefined;
    const handle = (e) => {
      if (ref.current && !ref.current.contains(e.target)) cb.current();
    };
    document.addEventListener("mousedown", handle);
    return () => document.removeEventListener("mousedown", handle);
  }, [ref, active]);
}
