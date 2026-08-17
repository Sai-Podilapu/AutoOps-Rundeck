import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fetchSequence, response } from "../test/setup";
import AegisVoice from "./AegisVoice";

// The SDK owns a WebSocket and an AudioContext, neither of which exists in
// jsdom. Standing in for it lets the suite assert the part that is ours: the
// signed-URL handshake and what the pill says at each step.
const sdk = {
  status: "disconnected",
  isSpeaking: false,
  startSession: vi.fn(),
  endSession: vi.fn(),
};
let handlers = {};

vi.mock("@elevenlabs/react", () => ({
  ConversationProvider: ({ children }) => children,
  useConversation: (options) => {
    handlers = options || {};
    return { ...sdk };
  },
}));

function stubMicrophone(getUserMedia) {
  Object.defineProperty(navigator, "mediaDevices", {
    value: { getUserMedia },
    configurable: true,
    writable: true,
  });
}

const enabled = () => response(200, { enabled: true, agentName: "Aegis-01" });
const grantedMic = () => vi.fn(async () => ({ getTracks: () => [{ stop: vi.fn() }] }));

beforeEach(() => {
  sdk.status = "disconnected";
  sdk.isSpeaking = false;
  sdk.startSession = vi.fn();
  sdk.endSession = vi.fn();
  handlers = {};
  stubMicrophone(grantedMic());
});

describe("AegisVoice", () => {
  it("still shows the pill when the backend reports no credentials", async () => {
    const fetchMock = fetchSequence(response(200, { enabled: false, agentName: "Aegis-01" }));

    render(<AegisVoice />);

    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith("/api/voice/config"));
    const pill = await screen.findByRole("button", { name: /tap to speak with aegis-01/i });

    // Inert: tapping explains itself instead of spending a session call.
    await userEvent.click(pill);
    expect(await screen.findByText(/not connected in this environment/i)).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(sdk.startSession).not.toHaveBeenCalled();
  });

  it("stays visible when the config call itself fails", async () => {
    fetchSequence(response(500, { message: "boom" }));

    render(<AegisVoice />);

    await waitFor(() => expect(global.fetch).toHaveBeenCalled());
    expect(await screen.findByRole("button", { name: /tap to speak with aegis-01/i }))
      .toBeInTheDocument();
  });

  it("invites the visitor to speak once voice is configured", async () => {
    fetchSequence(enabled());

    render(<AegisVoice />);

    expect(await screen.findByRole("button", { name: /tap to speak with aegis-01/i }))
      .toBeInTheDocument();
  });

  it("asks for the microphone, mints a session, and connects with the signed url", async () => {
    const getUserMedia = grantedMic();
    stubMicrophone(getUserMedia);
    fetchSequence(
      enabled(),
      response(200, { signedUrl: "wss://api.elevenlabs.io/x?token=abc", expiresInSeconds: 900 }),
    );

    render(<AegisVoice />);
    await userEvent.click(await screen.findByRole("button"));

    expect(getUserMedia).toHaveBeenCalledWith({ audio: true });
    await waitFor(() =>
      expect(sdk.startSession).toHaveBeenCalledWith({
        signedUrl: "wss://api.elevenlabs.io/x?token=abc",
      }),
    );
  });

  it("never spends a session when the microphone is refused", async () => {
    stubMicrophone(
      vi.fn(async () => {
        throw Object.assign(new Error("no"), { name: "NotAllowedError" });
      }),
    );
    const fetchMock = fetchSequence(enabled());

    render(<AegisVoice />);
    await userEvent.click(await screen.findByRole("button"));

    expect(await screen.findByText(/microphone access is needed/i)).toBeInTheDocument();
    // Only the config call — /api/voice/session was never reached.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(sdk.startSession).not.toHaveBeenCalled();
  });

  it("shows the server's rate-limit message and offers a retry", async () => {
    fetchSequence(
      enabled(),
      response(429, { error: "rate_limited", message: "Aegis-01 is at capacity right now" }),
    );

    render(<AegisVoice />);
    await userEvent.click(await screen.findByRole("button"));

    expect(await screen.findByText("Aegis-01 is at capacity right now")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /tap to try again/i })).toBeInTheDocument();
  });

  it("says it is listening while connected, and speaking while the agent talks", async () => {
    fetchSequence(enabled());
    sdk.status = "connected";

    const { rerender } = render(<AegisVoice />);
    expect(await screen.findByRole("button", { name: /listening/i })).toBeInTheDocument();

    sdk.isSpeaking = true;
    rerender(<AegisVoice />);
    expect(screen.getByRole("button", { name: /aegis-01 is speaking/i })).toBeInTheDocument();
  });

  it("hangs up instead of dialling again when already connected", async () => {
    fetchSequence(enabled());
    sdk.status = "connected";

    render(<AegisVoice />);
    await userEvent.click(await screen.findByRole("button"));

    expect(sdk.endSession).toHaveBeenCalled();
    expect(sdk.startSession).not.toHaveBeenCalled();
  });

  it("captions what the agent says, not what the visitor says", async () => {
    fetchSequence(enabled());
    sdk.status = "connected";

    render(<AegisVoice />);
    await screen.findByRole("button");

    act(() => {
      handlers.onMessage({ message: "show me the workflows", source: "user", role: "user" });
      handlers.onMessage({ message: "AutoOps governs every agent run.", source: "ai", role: "agent" });
    });

    expect(await screen.findByText("AutoOps governs every agent run.")).toBeInTheDocument();
    expect(screen.queryByText("show me the workflows")).not.toBeInTheDocument();
  });

  it("surfaces a dropped call from the SDK", async () => {
    fetchSequence(enabled());
    sdk.status = "connected";

    render(<AegisVoice />);
    await screen.findByRole("button");

    act(() => handlers.onError("The agent hung up."));

    expect(await screen.findByText("The agent hung up.")).toBeInTheDocument();
  });

  it("ends the session when the page unmounts", async () => {
    fetchSequence(enabled());
    sdk.status = "connected";

    const { unmount } = render(<AegisVoice />);
    await screen.findByRole("button");
    unmount();

    expect(sdk.endSession).toHaveBeenCalled();
  });
});
