import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// The point of this page is that nothing on it is decorative. These tests
// guard that property in both directions: the controls that remain must reach
// the API, and the ones that were removed must not creep back as switches with
// nothing behind them.

const storeState = {
  can: () => true,
  pushToast: vi.fn(),
  user: { role: "admin" },
  workspace: { name: "Intertec Systems", plan: "Enterprise" },
  clientRole: "admin",
};

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

const apiMock = {
  getAccount: vi.fn(),
  updateAccount: vi.fn(),
  listProjects: vi.fn(),
  listApiKeys: vi.fn(),
  createApiKey: vi.fn(),
  revokeApiKey: vi.fn(),
  notificationPreferences: vi.fn(),
  setNotificationPreference: vi.fn(),
};

vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: Settings } = await import("./Settings");

const PREFS = [
  {
    kind: "ALERT",
    label: "Alerts",
    description: "Failed runs and approval requests",
    enabled: true,
  },
  {
    kind: "SYSTEM",
    label: "Activity",
    description: "Approval decisions and workspace activity",
    enabled: true,
  },
  {
    kind: "PROVIDER",
    label: "Announcements",
    description: "Broadcasts from the AutoOps team",
    enabled: false,
  },
];

const renderPage = () =>
  render(
    <MemoryRouter>
      <Settings />
    </MemoryRouter>,
  );

const openTab = async (name) => {
  fireEvent.click(screen.getByRole("button", { name }));
  await waitFor(() => {});
};

beforeEach(() => {
  vi.clearAllMocks();
  apiMock.getAccount.mockResolvedValue({
    name: "Ashish A",
    email: "ashish@intertecsys.com",
  });
  apiMock.listProjects.mockResolvedValue([]);
  apiMock.listApiKeys.mockResolvedValue([]);
  apiMock.notificationPreferences.mockResolvedValue(PREFS);
  apiMock.setNotificationPreference.mockResolvedValue(PREFS);
});

describe("Settings — profile", () => {
  it("loads the signed-in profile and saves only the name", async () => {
    apiMock.updateAccount.mockResolvedValue({});
    renderPage();

    await waitFor(() =>
      expect(screen.getByLabelText("Full name")).toHaveValue("Ashish A"),
    );

    fireEvent.change(screen.getByLabelText("Full name"), {
      target: { value: "Ashish Appalabathula" },
    });
    fireEvent.click(screen.getByRole("button", { name: /save profile/i }));

    await waitFor(() =>
      expect(apiMock.updateAccount).toHaveBeenCalledWith({
        name: "Ashish Appalabathula",
      }),
    );
  });

  it("shows the email as text, not an input that discards typing", async () => {
    renderPage();

    await waitFor(() =>
      expect(screen.getByText("ashish@intertecsys.com")).toBeInTheDocument(),
    );
    expect(screen.queryByRole("textbox", { name: /email/i })).toBeNull();
  });

  it("does not offer preferences the app cannot honour", async () => {
    renderPage();
    await waitFor(() => expect(apiMock.getAccount).toHaveBeenCalled());

    // Each of these was a switch or field wired to nothing before.
    expect(screen.queryByText(/dark mode/i)).toBeNull();
    expect(screen.queryByText(/email digests/i)).toBeNull();
    expect(screen.queryByText(/desktop notifications/i)).toBeNull();
    expect(screen.queryByText(/timezone/i)).toBeNull();
  });
});

describe("Settings — projects", () => {
  it("lists real projects with a link to each one's settings", async () => {
    apiMock.listProjects.mockResolvedValue([
      { id: 7, name: "Alpha", description: "Nightly backups" },
    ]);
    renderPage();

    await openTab("Projects");

    const link = await screen.findByRole("link", { name: /Alpha/ });
    expect(link).toHaveAttribute("href", "/app/projects/7/settings");
  });

  it("says so honestly when there are none", async () => {
    renderPage();
    await openTab("Projects");

    expect(await screen.findByText(/no projects yet/i)).toBeInTheDocument();
  });
});

describe("Settings — notifications", () => {
  it("renders the rows the server says it publishes, labels included", async () => {
    renderPage();
    await openTab("Notifications");

    expect(await screen.findByText("Alerts")).toBeInTheDocument();
    expect(
      screen.getByText("Failed runs and approval requests"),
    ).toBeInTheDocument();
    expect(screen.getByText("Announcements")).toBeInTheDocument();
  });

  it("saves a toggle to the API rather than to localStorage", async () => {
    renderPage();
    await openTab("Notifications");
    await screen.findByText("Alerts");

    fireEvent.click(screen.getByRole("switch", { name: "Alerts" }));

    await waitFor(() =>
      expect(apiMock.setNotificationPreference).toHaveBeenCalledWith(
        "ALERT",
        false,
      ),
    );
  });

  it("reverts the switch when the save fails", async () => {
    apiMock.setNotificationPreference.mockRejectedValue(new Error("nope"));
    renderPage();
    await openTab("Notifications");
    await screen.findByText("Alerts");

    const toggle = screen.getByRole("switch", { name: "Alerts" });
    fireEvent.click(toggle);

    await waitFor(() =>
      expect(screen.getByRole("switch", { name: "Alerts" })).toHaveAttribute(
        "aria-checked",
        "true",
      ),
    );
  });

  it("points at Alert Channels instead of re-listing its providers", async () => {
    renderPage();
    await openTab("Notifications");
    await screen.findByText("Alerts");

    expect(
      screen.getByRole("link", { name: /open alert channels/i }),
    ).toHaveAttribute("href", "/app/notification-channels");
    // The old hard-coded delivery list and the email column are gone: there is
    // no email delivery for in-app notifications, and these three were static.
    expect(screen.queryByText("PagerDuty")).toBeNull();
    expect(screen.queryByText(/quiet hours/i)).toBeNull();
    expect(screen.queryByText("Email")).toBeNull();
  });
});

describe("Settings — API keys", () => {
  it("has no Plugins tab: connectors dispatched nothing and Alert Channels covers every kind they offered", async () => {
    renderPage();
    await waitFor(() => expect(apiMock.getAccount).toHaveBeenCalled());

    expect(screen.queryByRole("button", { name: "Plugins" })).toBeNull();
    expect(screen.queryByText(/connected plugins/i)).toBeNull();
  });

  it("loads API keys on the API Keys tab", async () => {
    apiMock.listApiKeys.mockResolvedValue([
      { id: 3, name: "CI pipeline", prefix: "ao_live_" },
    ]);
    renderPage();

    await openTab("API Keys");

    expect(await screen.findByText("CI pipeline")).toBeInTheDocument();
  });
});
