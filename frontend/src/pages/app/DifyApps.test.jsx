import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// This page is the only way into the Dify designer. It shipped once with no
// route linking to it at all, so the reachability assertions here are the point
// of the file, not incidental detail.

const storeState = { can: () => true, pushToast: vi.fn() };

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

const difyApiMock = { listApps: vi.fn(), createApp: vi.fn(), MOCK: true };
vi.mock("../../lib/dify/difyApi", () => ({ difyApi: difyApiMock }));

const { default: DifyApps } = await import("./DifyApps");

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={["/app/projects/7/dify"]}>
      <Routes>
        <Route path="/app/projects/:pid/dify" element={<DifyApps />} />
        <Route path="/app/projects/:pid/dify/:appId" element={<div>designer</div>} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  difyApiMock.listApps.mockResolvedValue([
    {
      id: "app-onboarding",
      name: "User-Onboarding (TEST CASE)",
      mode: "workflow",
      published: false,
      updated_at: "2026-08-04T09:00:00Z",
    },
    { id: "app-bot", name: "Support Bot", mode: "chat", published: true, updated_at: null },
  ]);
  difyApiMock.createApp.mockResolvedValue({ id: "app-new" });
});

describe("Dify apps list", () => {
  it("links each row into the designer", async () => {
    renderPage();
    const link = await screen.findByRole("link", { name: "User-Onboarding (TEST CASE)" });
    expect(link).toHaveAttribute("href", "/app/projects/7/dify/app-onboarding");
  });

  it("navigates into the designer on open", async () => {
    renderPage();
    await screen.findByText("User-Onboarding (TEST CASE)");
    fireEvent.click(screen.getAllByText("Open")[0]);
    expect(await screen.findByText("designer")).toBeInTheDocument();
  });

  it("distinguishes a published app from a draft", async () => {
    renderPage();
    await screen.findByText("Support Bot");
    expect(screen.getByText("Published")).toBeInTheDocument();
    expect(screen.getByText("Draft")).toBeInTheDocument();
  });

  it("labels a chatflow separately from a workflow", async () => {
    renderPage();
    await screen.findByText("Support Bot");
    expect(screen.getByText("Chatflow")).toBeInTheDocument();
    expect(screen.getByText("Workflow")).toBeInTheDocument();
  });

  /**
   * AI workflows follow the same rule as native workflows and agents: the
   * provider designs them and rolls them out. The customer gets no authoring
   * entry point at all, so there is nothing to click and nothing to refuse.
   */
  it("offers customers no way to author an AI workflow", async () => {
    renderPage();
    await screen.findByText("User-Onboarding (TEST CASE)");

    expect(screen.queryByText("New AI workflow")).not.toBeInTheDocument();
    expect(difyApiMock.createApp).not.toHaveBeenCalled();
  });

  it("filters by name", async () => {
    renderPage();
    await screen.findByText("Support Bot");
    fireEvent.change(screen.getByPlaceholderText("Search AI workflows…"), {
      target: { value: "support" },
    });
    expect(screen.queryByText("User-Onboarding (TEST CASE)")).not.toBeInTheDocument();
    expect(screen.getByText("Support Bot")).toBeInTheDocument();
  });
});
