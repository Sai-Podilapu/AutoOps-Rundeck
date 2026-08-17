/**
 * Models — this workspace's AI vendor credentials.
 *
 * Dify is deliberately NOT reachable from this console. It is the engine
 * behind workflows, not a product surface a tenant configures: the workspace
 * token can read and delete every app in the shared Dify workspace, so the
 * only thing that should ever hold it is the server. The "Platform (Dify)"
 * tab that used to live here — the shared workspace's providers, plugin
 * marketplace and system defaults — has been removed outright, along with the
 * screen behind it.
 *
 * What remains is the tenant's own bring-your-own-key credentials, stored
 * encrypted by core-service and never echoed back to the browser.
 */

import React from "react";
import { PageHeader } from "../../components/app/appui";
import AiProviders from "./AiProviders";

export default function Models() {
  return (
    <div className="animate-fade-up">
      <PageHeader
        title="Models"
        subtitle="Connect the AI vendors your team pays for, and choose what your agents run on."
      />
      <AiProviders embedded />
    </div>
  );
}
