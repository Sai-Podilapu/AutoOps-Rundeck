import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { CHANNEL_LOGO, VENDOR_LOGO, channelLogo, vendorLogo } from "./brandLogos";

// A logo slug that does not match the file on disk fails SILENTLY: the image
// 404s, BrandLogo swaps in its fallback glyph, and the card looks like a
// vendor nobody supplied artwork for. Three separate mismatches shipped that
// way — a plugin key ("microsoft-teams" vs "teams"), a capitalised filename
// (SageMaker.png) and a hyphenated one (hugging-face.png). The filesystem is
// the only thing that can settle it, so the test reads the filesystem.

const PUBLIC = join(process.cwd(), "public");

describe("brand logos", () => {
  it("every model vendor's logo file exists, exactly as named", () => {
    const missing = Object.keys(VENDOR_LOGO)
      .map((kind) => ({ kind, path: vendorLogo(kind) }))
      .filter(({ path }) => !existsSync(join(PUBLIC, path)));

    expect(missing).toEqual([]);
  });

  it("every notification channel's logo file exists, exactly as named", () => {
    const missing = Object.keys(CHANNEL_LOGO)
      .map((key) => ({ key, path: channelLogo(key) }))
      .filter(({ path }) => !existsSync(join(PUBLIC, path)));

    expect(missing).toEqual([]);
  });

  it("returns null for an unmapped key rather than a path that 404s", () => {
    // BrandLogo renders its fallback on null. A guessed path would instead
    // request a file that does not exist on every single render.
    expect(vendorLogo("SOME_NEW_VENDOR")).toBeNull();
    expect(channelLogo("some-new-plugin")).toBeNull();
    expect(vendorLogo(undefined)).toBeNull();
    expect(channelLogo(undefined)).toBeNull();
  });
});
