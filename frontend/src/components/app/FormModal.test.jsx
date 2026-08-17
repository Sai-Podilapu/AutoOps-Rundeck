import { render, screen, fireEvent } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

// FormModal drives most of the app's create dialogs, so its failure modes are
// shared by all of them: a required select that submits nothing because the
// browser shows one thing and React holds another, a field that stays visible
// for a type it does not belong to, and inputs open enough for Chrome to pour
// saved credentials into.

import FormModal from "./FormModal";

const FIELDS = [
  {
    name: "kind",
    label: "Type",
    type: "select",
    required: true,
    options: [
      { value: "slack_webhook", label: "Slack" },
      { value: "github", label: "GitHub" },
    ],
  },
  { name: "name", label: "Name", required: true },
  {
    key: "url-slack",
    name: "url",
    label: "Webhook URL",
    when: (v) => v.kind === "slack_webhook",
  },
  { name: "repo", label: "Repository", when: (v) => v.kind === "github" },
  {
    name: "token",
    label: "Access token",
    type: "password",
    when: (v) => v.kind === "github",
  },
];

const renderModal = (props = {}) => {
  const onSubmit = vi.fn();
  render(
    <FormModal
      open
      title="Add plugin"
      fields={FIELDS}
      onSubmit={onSubmit}
      onClose={vi.fn()}
      {...props}
    />,
  );
  return onSubmit;
};

describe("FormModal", () => {
  it("shows only the selected type's fields", () => {
    renderModal();

    expect(screen.getByLabelText(/Webhook URL/)).toBeInTheDocument();
    expect(screen.queryByLabelText(/Repository/)).toBeNull();
    expect(screen.queryByLabelText(/Access token/)).toBeNull();

    fireEvent.change(screen.getByLabelText(/Type/), {
      target: { value: "github" },
    });

    expect(screen.getByLabelText(/Repository/)).toBeInTheDocument();
    expect(screen.queryByLabelText(/Webhook URL/)).toBeNull();
  });

  it("submits the required select even when it is never touched", () => {
    const onSubmit = renderModal();

    fireEvent.change(screen.getByLabelText(/Name/), {
      target: { value: "Ops Slack" },
    });
    fireEvent.submit(screen.getByLabelText(/Name/).closest("form"));

    // The dropdown displays its first option, so that is what must be sent —
    // not the empty string the state used to hold.
    expect(onSubmit).toHaveBeenCalledWith({
      kind: "slack_webhook",
      name: "Ops Slack",
    });
  });

  it("drops a value whose field was hidden by a later type change", () => {
    const onSubmit = renderModal();

    fireEvent.change(screen.getByLabelText(/Webhook URL/), {
      target: { value: "https://hooks.slack.com/services/x" },
    });
    fireEvent.change(screen.getByLabelText(/Type/), {
      target: { value: "github" },
    });
    fireEvent.change(screen.getByLabelText(/Name/), {
      target: { value: "Repo" },
    });
    fireEvent.change(screen.getByLabelText(/Repository/), {
      target: { value: "acme/infra" },
    });
    fireEvent.submit(screen.getByLabelText(/Name/).closest("form"));

    expect(onSubmit).toHaveBeenCalledWith({
      kind: "github",
      name: "Repo",
      repo: "acme/infra",
    });
  });

  it("does not let the browser treat it as a sign-in form", () => {
    renderModal();
    fireEvent.change(screen.getByLabelText(/Type/), {
      target: { value: "github" },
    });

    const repo = screen.getByLabelText(/Repository/);
    const token = screen.getByLabelText(/Access token/);

    // A field named "repo" beside a password field is what made Chrome fill
    // the account email in. The synthetic name is the fix.
    expect(repo).toHaveAttribute("name", "autoops-repo");
    expect(repo).toHaveAttribute("autocomplete", "off");
    expect(token).toHaveAttribute("autocomplete", "new-password");
    expect(token).toHaveAttribute("data-lpignore", "true");
  });
});
