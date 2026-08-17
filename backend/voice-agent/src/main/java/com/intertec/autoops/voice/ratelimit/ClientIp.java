package com.intertec.autoops.voice.ratelimit;

import jakarta.servlet.http.HttpServletRequest;

/**
 * Best-effort client address for rate-limiting.
 *
 * <p>Requests reach this service through nginx and the api-gateway, so the
 * socket address is always a container IP; the original client only survives in
 * {@code X-Forwarded-For}. That header is client-supplied and therefore
 * forgeable — which is why the per-IP cap is the courtesy limit and the global
 * cap is the one that actually protects the ElevenLabs bill.
 */
public final class ClientIp {

    private ClientIp() {
    }

    public static String of(HttpServletRequest request) {
        String forwarded = request.getHeader("X-Forwarded-For");
        if (forwarded != null && !forwarded.isBlank()) {
            // "client, proxy1, proxy2" — the leftmost entry is the original client.
            String first = forwarded.split(",", 2)[0].trim();
            if (!first.isEmpty()) {
                return first;
            }
        }
        String remote = request.getRemoteAddr();
        return remote == null || remote.isBlank() ? "unknown" : remote;
    }
}
