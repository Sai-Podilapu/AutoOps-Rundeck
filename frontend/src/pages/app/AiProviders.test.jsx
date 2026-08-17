import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// Tenant bring-your-own-key providers. The states that matter to an operator
// are the honest ones: which vendors have no key, which have a key that has
// never been proven, and what a REAL failed test actually said.

const storeState = { can: () => true, pushToast: vi.fn() };

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

const apiMock = {
  modelProviderCatalog: vi.fn(),
  listModelProviders: vi.fn(),
  listWorkspaceModels: vi.fn(),
  saveModelProvider: vi.fn(),
  removeModelProvider: vi.fn(),
  verifyModelCredentials: vi.fn(),
  testModelProvider: vi.fn(),
  setModelProviderDefaults: vi.fn(),
  listModelDeployments: vi.fn(),
  saveModelDeployment: vi.fn(),
  removeModelDeployment: vi.fn(),
  refreshModelProvider: vi.fn(),
  refreshAllModelProviders: vi.fn(),
};

vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: AiProviders } = await import("./AiProviders");

const renderPage = () =>
  render(
    <MemoryRouter>
      <AiProviders />
    </MemoryRouter>,
  );

/**
 * Per-connection actions live behind Manage now that a vendor can hold more
 * than one key — the card is a summary, so "Test" on it would be ambiguous
 * about which connection it meant.
 */
const openManage = async () => {
  fireEvent.click(await screen.findByText("Manage"));
  await screen.findByText(/connections$/);
};

beforeEach(() => {
  storeState.pushToast.mockClear();

  apiMock.modelProviderCatalog.mockResolvedValue([
    {
      kind: "OPENAI",
      displayName: "OpenAI",
      docsUrl: "https://platform.openai.com/api-keys",
      fields: [
        {
          key: "apiKey",
          label: "API key",
          secret: true,
          required: true,
          placeholder: "sk-...",
        },
      ],
      defaultModel: "gpt-4o",
      fallbackModels: ["gpt-5", "gpt-4o", "gpt-4o-mini", "text-embedding-3-large"],
      // Split by core-service's classifier, so the console never has to guess
      // which of a vendor's models can hold a conversation.
      fallbackModelsByPurpose: {
        CHAT: ["gpt-5", "gpt-4o", "gpt-4o-mini"],
        EMBEDDING: ["text-embedding-3-large"],
      },
    },
    {
      kind: "HUAWEI",
      displayName: "Huawei Cloud (Pangu / ModelArts)",
      docsUrl: "https://console.huaweicloud.com/modelarts",
      fields: [
        {
          key: "region",
          label: "Region",
          secret: false,
          required: true,
          placeholder: "cn-north-4",
          options: [
            { value: "cn-north-4", label: "cn-north-4 — CN North (Beijing 4)" },
            { value: "ap-southeast-3", label: "ap-southeast-3 — AP (Singapore)" },
          ],
        },
        { key: "projectId", label: "Project ID", secret: false, required: true, placeholder: "" },
        { key: "accessKey", label: "Access key (AK)", secret: true, required: true, placeholder: "" },
        { key: "secretKey", label: "Secret key (SK)", secret: true, required: true, placeholder: "" },
      ],
      defaultModel: null,
      fallbackModels: ["DeepSeek-V3", "DeepSeek-R1"],
      // Huawei publishes no embedding model — the picker must say so rather
      // than offer a chat model for the job.
      fallbackModelsByPurpose: { CHAT: ["DeepSeek-V3", "DeepSeek-R1"] },
      modelHint: "Pangu models are addressed by the ModelArts deployment id you created.",
    },
  ]);

  apiMock.listModelProviders.mockResolvedValue([
    {
      id: 1,
      kind: "OPENAI",
      displayName: "OpenAI",
      name: "OpenAI",
      defaultModel: null,
      enabled: true,
      lastTestOk: true,
      lastTestAt: "2026-08-06T05:00:00Z",
      lastTestNote: "OpenAI accepted the credential — 2 model(s) available",
    },
  ]);

  apiMock.listWorkspaceModels.mockResolvedValue([
    {
      kind: "OPENAI",
      providerName: "OpenAI",
      providerId: 1,
      verified: true,
      defaultModel: null,
      defaultEmbeddingModel: null,
      models: ["gpt-5", "gpt-5-mini"],
      modelsByPurpose: { CHAT: ["gpt-5", "gpt-5-mini"] },
    },
  ]);

  apiMock.saveModelProvider.mockResolvedValue({ id: 2, kind: "HUAWEI" });
  apiMock.verifyModelCredentials.mockResolvedValue({
    ok: true,
    message: "Accepted",
    models: ["pangu-38b"],
  });
  apiMock.testModelProvider.mockResolvedValue({ ok: true, message: "OpenAI accepted the credential", models: [] });
  apiMock.setModelProviderDefaults.mockResolvedValue({});
  apiMock.listModelDeployments.mockResolvedValue([]);
  apiMock.saveModelDeployment.mockResolvedValue({ id: 9 });
  apiMock.removeModelDeployment.mockResolvedValue(undefined);
  apiMock.refreshModelProvider.mockResolvedValue({ ok: true, message: "Refreshed", models: [] });
  apiMock.refreshAllModelProviders.mockResolvedValue({ refreshed: 1, total: 1 });
});

describe("AI providers", () => {
  it("separates a connected vendor from one with no key", async () => {
    renderPage();
    expect(await screen.findByText("OpenAI")).toBeInTheDocument();
    expect(screen.getByText("Verified")).toBeInTheDocument();
    expect(screen.getByText("Not configured")).toBeInTheDocument();
  });

  it("builds the credential form from the vendor's own field spec", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    // The unconfigured vendor is the one offering "Add key".
    fireEvent.click(screen.getByText("Add key"));

    expect(
      await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials"),
    ).toBeInTheDocument();
    // Four fields, not the single API key the bearer-token vendors take.
    // Scoped to <label>: the card also lists the required field names as
    // chips, so an unscoped query matches twice.
    for (const label of ["Region", "Project ID", "Access key (AK)", "Secret key (SK)"]) {
      expect(screen.getByText(label, { selector: "label" })).toBeInTheDocument();
    }
  });

  it("offers the vendor's regions rather than asking anyone to recall a code", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    const region = screen.getByLabelText(/Region/);
    expect(region.tagName).toBe("SELECT");
    expect(
      screen.getByRole("option", { name: "ap-southeast-3 — AP (Singapore)" }),
    ).toBeInTheDocument();

    // The picked code is what gets stored — the label is for humans only.
    fireEvent.change(region, { target: { value: "ap-southeast-3" } });
    fireEvent.change(screen.getByLabelText(/Project ID/), {
      target: { value: "p1" },
    });
    fireEvent.change(screen.getByLabelText(/Access key \(AK\)/), {
      target: { value: "ak" },
    });
    fireEvent.change(screen.getByLabelText(/Secret key \(SK\)/), {
      target: { value: "sk" },
    });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() => expect(apiMock.saveModelProvider).toHaveBeenCalled());
    const sent = JSON.parse(apiMock.saveModelProvider.mock.calls[0][0].config);
    expect(sent.region).toBe("ap-southeast-3");
  });

  it("still accepts a region the catalog has not caught up with", async () => {
    // Vendors add regions between our releases; a closed list that cannot be
    // escaped would lock a tenant out of one they are entitled to.
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.change(screen.getByLabelText(/Region/), {
      target: { value: "__other__" },
    });
    expect(screen.getByLabelText(/Region/).tagName).toBe("INPUT");
  });

  it("keeps the dialog open and shows why a save was rejected", async () => {
    apiMock.verifyModelCredentials.mockRejectedValueOnce(
      new Error('Huawei Cloud (Pangu / ModelArts) needs "region" (Region)'),
    );
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.click(screen.getByText("Verify"));

    expect(
      await screen.findByText('Huawei Cloud (Pangu / ModelArts) needs "region" (Region)'),
    ).toBeInTheDocument();
    expect(
      screen.getByText("Huawei Cloud (Pangu / ModelArts) credentials"),
    ).toBeInTheDocument();
  });

  // ---- preflight verify, mirroring Cloud Integrations ----

  it("never stores a credential the vendor rejected", async () => {
    apiMock.verifyModelCredentials.mockResolvedValueOnce({
      ok: false,
      message: "Invalid API key provided",
      models: [],
    });
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.click(screen.getByText("Verify"));

    expect(await screen.findByText("Invalid API key provided")).toBeInTheDocument();
    // The whole point: a rejected key leaves no row behind to clean up.
    expect(apiMock.saveModelProvider).not.toHaveBeenCalled();
    // And the button stays on Verify — there is nothing to save yet.
    expect(screen.queryByText("Save")).toBeNull();
  });

  it("reports what the vendor could see before anything is saved", async () => {
    apiMock.verifyModelCredentials.mockResolvedValueOnce({
      ok: true,
      message: "Accepted",
      models: ["pangu-38b", "pangu-13b"],
    });
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.click(screen.getByText("Verify"));

    expect(await screen.findByText(/2 models visible/)).toBeInTheDocument();
    expect(apiMock.saveModelProvider).not.toHaveBeenCalled();
  });

  it("makes an edited credential prove itself again", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.click(screen.getByText("Verify"));
    await screen.findByText("Save");

    // The earlier answer was about a different key, so it no longer applies.
    fireEvent.change(screen.getByLabelText(/Access key \(AK\)/), {
      target: { value: "different" },
    });

    expect(screen.queryByText("Save")).toBeNull();
    expect(screen.getByText("Verify")).toBeInTheDocument();
  });

  it("gives only a verified provider's card a green edge", async () => {
    renderPage();

    const verified = (await screen.findByText("OpenAI")).closest(".rounded-2xl");
    expect(verified.className).toContain("!border-emerald-300");

    const unconfigured = screen
      .getByText("Huawei Cloud (Pangu / ModelArts)")
      .closest(".rounded-2xl");
    expect(unconfigured.className).not.toContain("!border-emerald-300");
  });

  it("lets an unconfigured vendor preview the models it commonly serves", async () => {
    // Every card carries this row — it is what keeps them all one height —
    // and for a vendor with no key the only honest list is the catalog's.
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");

    fireEvent.click(screen.getByText("2 common models"));

    expect(await screen.findByText("Huawei Cloud (Pangu / ModelArts) models")).toBeInTheDocument();
    expect(screen.getByText("DeepSeek-V3")).toBeInTheDocument();
    // ...labelled as unproven, not as something this workspace can reach.
    expect(
      screen.getByText(/Not verified — these are common models for this vendor/),
    ).toBeInTheDocument();
  });

  it("puts a failed key's reason on the card instead of a model count", async () => {
    apiMock.listModelProviders.mockResolvedValueOnce([
      {
        id: 1,
        kind: "OPENAI",
        displayName: "OpenAI",
        name: "OpenAI",
        defaultModel: null,
        enabled: true,
        lastTestOk: false,
        lastTestAt: "2026-08-06T05:00:00Z",
        lastTestNote: "OpenAI rejected the credential (HTTP 401) — check the key",
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    expect(
      await screen.findByText("OpenAI rejected the credential (HTTP 401) — check the key"),
    ).toBeInTheDocument();
    // A stale cached count beside a rejected key reads as though it still works.
    expect(screen.queryByText(/models available/)).not.toBeInTheDocument();
  });

  it("reports a rejected key from a real test rather than a green tick", async () => {
    apiMock.testModelProvider.mockResolvedValueOnce({
      ok: false,
      message: "OpenAI rejected the credential (HTTP 401) — check the key and its permissions",
      models: [],
    });
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();

    fireEvent.click(screen.getByText("Test"));

    await waitFor(() =>
      expect(storeState.pushToast).toHaveBeenCalledWith(
        "OpenAI rejected the credential (HTTP 401) — check the key and its permissions",
        "red",
      ),
    );
  });

  it("lists the models a connected provider actually reported", async () => {
    renderPage();
    await screen.findByText("OpenAI");

    fireEvent.click(screen.getByText("2 models available"));

    expect(await screen.findByText("gpt-5")).toBeInTheDocument();
    expect(screen.getByText("gpt-5-mini")).toBeInTheDocument();
  });

  it("does not call the catalog's guesses a verified model list", async () => {
    apiMock.listWorkspaceModels.mockResolvedValueOnce([
      {
        kind: "OPENAI",
        providerName: "OpenAI",
        providerId: 1,
        // Key saved, never tested — so this list came from the catalog.
        verified: false,
        defaultModel: null,
        models: ["gpt-5", "gpt-4o", "gpt-4o-mini"],
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    expect(await screen.findByText("3 likely models — not verified")).toBeInTheDocument();
    expect(screen.queryByText(/models available/)).not.toBeInTheDocument();
  });

  it("offers the vendor's models in the default-model dropdown before any test", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    const picker = screen.getByLabelText(/Default model/);
    expect([...picker.options].map((o) => o.value)).toEqual([
      "",
      "DeepSeek-V3",
      "DeepSeek-R1",
      "__custom__",
    ]);
    // ...and says so, rather than implying this key was checked.
    expect(
      screen.getByText(/Test to load the real list/),
    ).toBeInTheDocument();
    // The vendor's own caveat shows once for the whole column, not once per
    // picker — it was the same sentence three times.
    expect(
      screen.getByText(/ModelArts deployment id you created/),
    ).toBeInTheDocument();
  });

  it("shows the vendor's mark and what its model list is made of", async () => {
    apiMock.listWorkspaceModels.mockResolvedValueOnce([
      {
        kind: "OPENAI",
        providerName: "OpenAI",
        providerId: 1,
        verified: true,
        defaultModel: null,
        defaultEmbeddingModel: null,
        models: ["gpt-5", "text-embedding-3-large", "dall-e-3"],
        modelsByPurpose: {
          CHAT: ["gpt-5"],
          EMBEDDING: ["text-embedding-3-large"],
          IMAGE: ["dall-e-3"],
        },
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    // The vendor's own logo, not a generic glyph.
    expect(screen.getByAltText("OpenAI logo")).toBeInTheDocument();

    // A bare count hides that most of a vendor's list cannot hold a
    // conversation; the split says so on the card itself.
    expect(
      await screen.findByText("1 chat · 1 embedding · 1 image"),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByText("3 models available"));
    expect(await screen.findByText("embedding · 1")).toBeInTheDocument();
    expect(screen.getByText("image · 1")).toBeInTheDocument();
  });

  it("browses models by category in a dialog rather than inside the card", async () => {
    apiMock.listWorkspaceModels.mockResolvedValueOnce([
      {
        kind: "OPENAI",
        providerName: "OpenAI",
        providerId: 1,
        verified: true,
        defaultModel: null,
        defaultEmbeddingModel: null,
        models: ["gpt-5", "text-embedding-3-large", "dall-e-3"],
        modelsByPurpose: {
          CHAT: ["gpt-5"],
          EMBEDDING: ["text-embedding-3-large"],
          IMAGE: ["dall-e-3"],
        },
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    // Nothing is listed on the card itself — 119 ids inline is what made one
    // card tower over its neighbours.
    expect(screen.queryByText("gpt-5")).not.toBeInTheDocument();

    fireEvent.click(screen.getByText("3 models available"));
    expect(await screen.findByText("OpenAI models")).toBeInTheDocument();
    expect(screen.getByText("gpt-5")).toBeInTheDocument();
    expect(screen.getByText("dall-e-3")).toBeInTheDocument();

    // Narrowing to a category shows only that category.
    fireEvent.click(screen.getByText("embedding · 1"));
    expect(screen.getByText("text-embedding-3-large")).toBeInTheDocument();
    expect(screen.queryByText("dall-e-3")).not.toBeInTheDocument();
    expect(screen.queryByText("gpt-5")).not.toBeInTheDocument();
  });

  it("checks the credential before it is stored, then again to earn the badge", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    // The preflight is what makes the save safe; the post-save test is what
    // writes lastTestOk onto the row and caches the real model list the
    // category browser reads. Both run, in that order.
    await waitFor(() => expect(apiMock.saveModelProvider).toHaveBeenCalled());
    await waitFor(() => expect(apiMock.testModelProvider).toHaveBeenCalledWith(2));
    expect(apiMock.verifyModelCredentials.mock.invocationCallOrder[0]).toBeLessThan(
      apiMock.saveModelProvider.mock.invocationCallOrder[0],
    );
  });

  it("keeps embedding and image models out of the chat picker", async () => {
    // A vendor answers "list models" with everything the account can reach:
    // AWS returned 119, of which 15 embed and 14 draw. Offering those as a
    // chat default invites a failure that only shows up on the first call.
    apiMock.listWorkspaceModels.mockResolvedValueOnce([
      {
        kind: "OPENAI",
        providerName: "OpenAI",
        providerId: 1,
        verified: true,
        defaultModel: null,
        defaultEmbeddingModel: null,
        models: ["gpt-5", "text-embedding-3-large", "dall-e-3"],
        modelsByPurpose: {
          CHAT: ["gpt-5"],
          EMBEDDING: ["text-embedding-3-large"],
          IMAGE: ["dall-e-3"],
        },
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();
    fireEvent.click(screen.getByText("Replace key"));
    await screen.findByText("OpenAI credentials");

    expect(
      [...screen.getByLabelText(/Default model/).options].map((o) => o.value),
    ).toEqual(["", "gpt-5", "__custom__"]);

    // ...and the embedding picker offers only what can actually embed.
    expect(
      [...screen.getByLabelText(/Default embedding model/).options].map((o) => o.value),
    ).toEqual(["", "text-embedding-3-large", "__custom__"]);
  });

  it("saves the embedding model beside the chat model", async () => {
    renderPage();
    await screen.findByText("Huawei Cloud (Pangu / ModelArts)");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Huawei Cloud (Pangu / ModelArts) credentials");

    // Huawei lists none, so the field is a text box and says why.
    expect(
      screen.getByText(/lists no embedding model/),
    ).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText(/Default embedding model/), {
      target: { value: "my-modelarts-embedding-deployment" },
    });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() =>
      expect(apiMock.saveModelProvider).toHaveBeenCalledWith(
        expect.objectContaining({
          defaultEmbeddingModel: "my-modelarts-embedding-deployment",
        }),
      ),
    );
  });

  it("prefers what the vendor actually reported over the catalog's guesses", async () => {
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();
    fireEvent.click(screen.getByText("Replace key"));
    await screen.findByText("OpenAI credentials");

    const picker = screen.getByLabelText(/Default model/);
    // The probe returned gpt-5 and gpt-5-mini; the catalog's gpt-4o is dropped.
    expect([...picker.options].map((o) => o.value)).toEqual([
      "",
      "gpt-5",
      "gpt-5-mini",
      "__custom__",
    ]);

    fireEvent.change(picker, { target: { value: "gpt-5-mini" } });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() =>
      expect(apiMock.saveModelProvider).toHaveBeenCalledWith(
        expect.objectContaining({ kind: "OPENAI", defaultModel: "gpt-5-mini" }),
      ),
    );
  });

  it("still accepts a model id the vendor never listed", async () => {
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();
    fireEvent.click(screen.getByText("Replace key"));
    await screen.findByText("OpenAI credentials");

    fireEvent.change(screen.getByLabelText(/Default model/), {
      target: { value: "__custom__" },
    });
    fireEvent.change(screen.getByPlaceholderText("gpt-4o"), {
      target: { value: "ft:gpt-4o:acme::abc123" },
    });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() =>
      expect(apiMock.saveModelProvider).toHaveBeenCalledWith(
        expect.objectContaining({ defaultModel: "ft:gpt-4o:acme::abc123" }),
      ),
    );
  });

  // ---- named connections, auth methods, declared models, refresh ----

  it("holds several connections to one vendor and names them apart", async () => {
    apiMock.listModelProviders.mockResolvedValue([
      { id: 1, kind: "OPENAI", name: "Production", enabled: true, lastTestOk: true },
      { id: 2, kind: "OPENAI", name: "Sandbox", enabled: true, lastTestOk: null },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    // The names are the choice an operator makes, so they surface on the card.
    expect(screen.getByText("Production")).toBeInTheDocument();
    expect(screen.getByText("Sandbox")).toBeInTheDocument();
    expect(screen.getByText("2 connections · 1 verified")).toBeInTheDocument();
  });

  it("adds a second key rather than replacing the first", async () => {
    apiMock.listModelProviders.mockResolvedValue([
      { id: 1, kind: "OPENAI", name: "Production", enabled: true, lastTestOk: true },
    ]);
    renderPage();
    await screen.findByText("OpenAI");

    // The card offers to ADD; replacing is a per-connection action behind
    // Manage, so the two intents can never be confused for each other.
    fireEvent.click(screen.getByText("Add another key"));
    await screen.findByText("OpenAI credentials");

    fireEvent.change(screen.getByLabelText(/Connection name/), {
      target: { value: "Sandbox" },
    });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() =>
      expect(apiMock.saveModelProvider).toHaveBeenCalledWith(
        // No id: the server refuses a duplicate name instead of overwriting.
        expect.objectContaining({ id: null, name: "Sandbox", kind: "OPENAI" }),
      ),
    );
  });

  it("swaps the credential fields when Azure's auth method changes", async () => {
    apiMock.modelProviderCatalog.mockResolvedValueOnce([
      {
        kind: "AZURE_OPENAI",
        displayName: "Azure OpenAI",
        fields: [
          { key: "endpoint", label: "Endpoint", secret: false, required: true },
          { key: "apiKey", label: "API key", secret: true, required: true },
        ],
        fallbackModels: [],
        fallbackModelsByPurpose: {},
        declaresModels: true,
        authMethods: [
          {
            code: "API_KEY",
            label: "API key",
            fields: [
              { key: "endpoint", label: "Endpoint", secret: false, required: true },
              { key: "apiKey", label: "API key", secret: true, required: true },
            ],
          },
          {
            code: "ENTRA_ID",
            label: "Microsoft Entra ID (service principal)",
            fields: [
              { key: "endpoint", label: "Endpoint", secret: false, required: true },
              { key: "clientId", label: "Application (client) ID", secret: false, required: true },
              { key: "clientSecret", label: "Client secret", secret: true, required: true },
            ],
          },
        ],
      },
    ]);
    renderPage();
    await screen.findByText("Azure OpenAI");
    fireEvent.click(screen.getByText("Add key"));
    await screen.findByText("Azure OpenAI credentials");

    expect(screen.getByText("API key", { selector: "label" })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText(/Authentication method/), {
      target: { value: "ENTRA_ID" },
    });

    // The two methods share almost nothing, so the form is genuinely swapped
    // rather than having extra optional boxes appear.
    expect(screen.getByText("Client secret", { selector: "label" })).toBeInTheDocument();
    expect(screen.queryByText("API key", { selector: "label" })).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText(/Endpoint/), {
      target: { value: "https://r.openai.azure.com" },
    });
    fireEvent.change(screen.getByLabelText(/Application \(client\) ID/), {
      target: { value: "cid" },
    });
    fireEvent.change(screen.getByLabelText(/Client secret/), {
      target: { value: "secret" },
    });
    fireEvent.click(screen.getByText("Verify"));
    fireEvent.click(await screen.findByText("Save"));

    await waitFor(() => expect(apiMock.saveModelProvider).toHaveBeenCalled());
    const sent = apiMock.saveModelProvider.mock.calls[0][0];
    expect(sent.authMethod).toBe("ENTRA_ID");
    // No stale apiKey rides along from the method that was abandoned.
    expect(JSON.parse(sent.config)).toEqual({
      endpoint: "https://r.openai.azure.com",
      clientId: "cid",
      clientSecret: "secret",
    });
  });

  it("declares a model the vendor's list could never report", async () => {
    apiMock.listModelProviders.mockResolvedValue([
      { id: 1, kind: "OPENAI", name: "OpenAI", enabled: true, lastTestOk: true },
    ]);
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();
    fireEvent.click(screen.getByText("Settings"));

    fireEvent.click(await screen.findByText("Add model"));
    fireEvent.change(screen.getByLabelText(/Model name/), {
      target: { value: "prod-embed-v2" },
    });
    // Declared, not inferred: no naming rule can read a name its operator
    // invented, so the purpose is asked for outright.
    fireEvent.change(screen.getByLabelText(/Model type/), {
      target: { value: "EMBEDDING" },
    });
    fireEvent.click(screen.getByText("Add"));

    await waitFor(() =>
      expect(apiMock.saveModelDeployment).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ modelName: "prod-embed-v2", purpose: "EMBEDDING" }),
      ),
    );
  });

  it("changes a default model without re-sending the key", async () => {
    // The browser never receives the credential back, so requiring one in
    // order to re-point chat at another model would make it impossible.
    apiMock.listModelProviders.mockResolvedValue([
      {
        id: 1,
        kind: "OPENAI",
        name: "OpenAI",
        enabled: true,
        lastTestOk: true,
        defaultModel: "gpt-5",
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();
    fireEvent.click(screen.getByText("Settings"));

    fireEvent.change(await screen.findByLabelText(/^Default model/), {
      target: { value: "gpt-5-mini" },
    });
    fireEvent.click(screen.getByText("Save defaults"));

    await waitFor(() =>
      expect(apiMock.setModelProviderDefaults).toHaveBeenCalledWith(
        1,
        expect.objectContaining({ defaultModel: "gpt-5-mini" }),
      ),
    );
    expect(apiMock.saveModelProvider).not.toHaveBeenCalled();
  });

  it("says how stale a cached model list is", async () => {
    apiMock.listModelProviders.mockResolvedValue([
      {
        id: 1,
        kind: "OPENAI",
        name: "OpenAI",
        enabled: true,
        lastTestOk: true,
        // A list this old should admit it rather than read as current.
        modelsRefreshedAt: new Date(Date.now() - 3 * 86400 * 1000).toISOString(),
      },
    ]);
    renderPage();
    await screen.findByText("OpenAI");
    await openManage();

    expect(screen.getByText(/refreshed 3 days ago/)).toBeInTheDocument();
  });

  it("reports how many connections a refresh actually reached", async () => {
    apiMock.refreshAllModelProviders.mockResolvedValueOnce({ refreshed: 1, total: 2 });
    renderPage();
    await screen.findByText("OpenAI");

    fireEvent.click(screen.getByText("Refresh models"));

    // One vendor being unreachable must not be reported as a clean sweep.
    await waitFor(() =>
      expect(storeState.pushToast).toHaveBeenCalledWith(
        "1 of 2 connection(s) refreshed",
        "red",
      ),
    );
  });

  it("shows an honest error instead of an invented vendor list", async () => {
    apiMock.modelProviderCatalog.mockRejectedValueOnce(new Error("Service unavailable"));
    renderPage();

    expect(await screen.findByText("Service unavailable")).toBeInTheDocument();
  });
});
