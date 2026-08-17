import React from "react";
import ScriptEditor from "../../components/app/ScriptEditor";

/**
 * The provider console's script surface — authoring a catalog script and
 * editing one already published.
 *
 * The editor itself is shared with the tenant console: a customer adapting the
 * copy it imported is doing the same job, and two code editors would drift.
 * See {@link ScriptEditor}.
 */
export default function ProviderScriptEditor() {
  return <ScriptEditor audience="provider" />;
}
