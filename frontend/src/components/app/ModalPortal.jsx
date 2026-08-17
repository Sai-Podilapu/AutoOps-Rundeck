import React from "react";
import { createPortal } from "react-dom";

/**
 * Portals a dialog to <body> and draws the shared scrim.
 *
 * Dialogs MUST portal. Page wrappers carry `animate-fade-up`, whose keyframes
 * settle on `transform: translateY(0)` with `animation-fill-mode: both` — so a
 * non-none transform sticks around forever once the animation ends. That makes
 * the wrapper the containing block for `position: fixed`, and a scrim rendered
 * in place gets clipped to the content column: dark over the table, untouched
 * over the sidebar and header, with a hard edge between them.
 *
 * The scrim is `fixed` rather than `absolute` on purpose. In a scrollable
 * layer (a tall form that overflows), an absolute scrim is only as tall as one
 * viewport and slides away as you scroll; a fixed one stays put.
 *
 * @param layerClass  positioning for the layer — z-index, alignment, padding.
 * @param onClose     click-through-the-scrim handler; omit to make it inert.
 */
export default function ModalPortal({
  onClose,
  children,
  layerClass = "z-[100] items-center p-4",
}) {
  return createPortal(
    <div className={`fixed inset-0 flex justify-center ${layerClass}`}>
      <div
        className="animate-fade-in fixed inset-0 bg-slate-900/25 backdrop-blur-md"
        onClick={onClose}
      />
      {children}
    </div>,
    document.body,
  );
}
