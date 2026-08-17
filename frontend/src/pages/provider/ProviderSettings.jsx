import React, { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { PageHeader, Card, SmallButton } from "../../components/app/appui";
import Icon from "../../components/Icon";
import { api } from "../../lib/api";
import { useStore } from "../../store/store";

/**
 * Operator settings. Deliberately small: platform configuration (tokens,
 * providers, execution mode) lives in the deployment environment, not in a
 * web form — this page shows the signed-in operator's real account and where
 * the real controls are.
 */
export default function ProviderSettings() {
  const { session } = useStore();
  const [account, setAccount] = useState(null);

  useEffect(() => {
    api
      .getAccount()
      .then(setAccount)
      .catch(() => setAccount(null));
  }, []);

  const rows = [
    ["Name", account?.name || session?.user?.name || "—"],
    ["Email", account?.email || session?.user?.email || "—"],
    ["Role", "Platform operator (PROVIDER)"],
  ];

  return (
    <div className="mx-auto max-w-3xl animate-fade-up">
      <PageHeader
        title="Settings"
        subtitle="Your operator account and where platform configuration lives"
      />

      <Card className="p-6">
        <h3 className="mb-4 text-sm font-semibold text-slate-900">
          Operator account
        </h3>
        <div className="divide-y divide-slate-200">
          {rows.map(([label, value]) => (
            <div key={label} className="flex items-center justify-between py-3">
              <span className="text-sm text-slate-500">{label}</span>
              <span className="text-sm font-medium text-slate-900">{value}</span>
            </div>
          ))}
        </div>
      </Card>

      <Card className="mt-6 p-6">
        <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold text-slate-900">
          <Icon name="gear" size={16} /> Platform configuration
        </h3>
        <p className="text-sm text-slate-500">
          Service secrets (internal tokens, credential encryption keys), the
          payment provider, execution mode, and email delivery are configured
          through the deployment environment (<code className="font-mono text-xs">
          docker-compose / .env</code>) and validated at boot by each
          service's production safety guard — they are deliberately not
          editable from the browser.
        </p>
        <p className="mt-3 text-sm text-slate-500">
          Plan pricing and limits are edited live under{" "}
          <Link
            to="/provider/plans"
            className="font-medium text-slate-900 hover:underline"
          >
            Plans &amp; Quotas
          </Link>
          ; tenant-facing announcements go out via{" "}
          <Link
            to="/provider/broadcasts"
            className="font-medium text-slate-900 hover:underline"
          >
            Broadcasts
          </Link>
          .
        </p>
        <div className="mt-4">
          <Link to="/provider/health">
            <SmallButton icon="pulse">Check platform health</SmallButton>
          </Link>
        </div>
      </Card>
    </div>
  );
}
