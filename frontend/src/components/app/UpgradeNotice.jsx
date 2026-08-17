import React from "react";
import { Link } from "react-router-dom";
import { Card, SmallButton } from "./appui";
import Icon from "../Icon";

// Shown when the current tenant plan does not include a gated feature.
export default function UpgradeNotice({ feature, plan }) {
  return (
    <Card className="flex flex-col items-center gap-3 p-12 text-center">
      <span className="flex h-12 w-12 items-center justify-center rounded-xl bg-slate-100 text-slate-900">
        <Icon name="lock" size={24} />
      </span>
      <div>
        <p className="text-sm font-semibold text-slate-900">
          {feature} is a {plan} feature
        </p>
        <p className="mt-1 text-sm text-slate-500">
          Upgrade your subscription to unlock {feature.toLowerCase()} for this
          workspace.
        </p>
      </div>
      <Link to="/app/billing">
        <SmallButton icon="scale" variant="primary">
          Upgrade to {plan}
        </SmallButton>
      </Link>
    </Card>
  );
}
