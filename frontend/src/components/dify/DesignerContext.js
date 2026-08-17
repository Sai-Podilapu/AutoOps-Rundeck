import { createContext, useContext } from "react";

/**
 * Everything a config field needs that isn't its own value: the graph (so the
 * variable picker can compute what's upstream), the catalogs loaded from the
 * backend (models, tools, datasets), and the app mode (chatflow vs workflow,
 * which gates chat-only fields).
 *
 * Passing this by context rather than prop-drilling keeps the generic field
 * renderer's signature to (field, value, onChange) — fields stay dumb.
 */
export const DesignerContext = createContext({
  nodeId: null,
  nodes: [],
  edges: [],
  appMode: "workflow",
  envVariables: [],
  conversationVariables: [],
  models: [],
  toolProviders: [],
  datasets: [],
  readOnly: false,
});

export const useDesigner = () => useContext(DesignerContext);
