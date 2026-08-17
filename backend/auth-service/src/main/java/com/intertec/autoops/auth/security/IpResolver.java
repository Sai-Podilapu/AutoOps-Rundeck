package com.intertec.autoops.auth.security;

import com.intertec.autoops.auth.config.AuthProperties;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Component;

import java.net.InetAddress;

/**
 * Client IP resolution with a trusted-proxy allow-list.
 *
 * <p>X-Forwarded-For / X-Real-IP are attacker-controlled unless the direct
 * peer is a known proxy, so they are honored ONLY when the connecting address
 * matches {@code autoops.auth.trusted-proxies} (exact IPs or CIDRs). With an
 * empty allow-list (the default) the socket address is always used, so
 * spoofed headers can never be used to rotate rate-limit keys.
 *
 * <p>When headers are trusted, X-Forwarded-For is walked right-to-left and
 * the first hop that is not itself a trusted proxy is taken as the client.
 */
@Component
public class IpResolver {

    private final AuthProperties properties;

    public IpResolver(AuthProperties properties) {
        this.properties = properties;
    }

    public String resolve(HttpServletRequest request) {
        String remoteAddr = request.getRemoteAddr();
        if (!isTrustedProxy(remoteAddr)) {
            // Direct connection (or unknown proxy): never trust forwarding headers.
            return remoteAddr;
        }

        String forwardedFor = request.getHeader("X-Forwarded-For");
        if (forwardedFor != null && !forwardedFor.isBlank()) {
            String[] hops = forwardedFor.split(",");
            for (int i = hops.length - 1; i >= 0; i--) {
                String hop = hops[i].trim();
                if (!hop.isEmpty() && !isTrustedProxy(hop)) {
                    return hop;
                }
            }
            return hops[0].trim();
        }

        String realIp = request.getHeader("X-Real-IP");
        if (realIp != null && !realIp.isBlank()) {
            return realIp.trim();
        }
        return remoteAddr;
    }

    private boolean isTrustedProxy(String address) {
        for (String entry : properties.getTrustedProxies()) {
            String trimmed = entry == null ? "" : entry.trim();
            if (!trimmed.isEmpty() && matches(trimmed, address)) {
                return true;
            }
        }
        return false;
    }

    /** Matches an exact IP or a CIDR block (IPv4 or IPv6). */
    private boolean matches(String cidrOrIp, String address) {
        try {
            InetAddress target = InetAddress.getByName(address);
            int slash = cidrOrIp.indexOf('/');
            if (slash < 0) {
                return target.equals(InetAddress.getByName(cidrOrIp));
            }
            InetAddress network = InetAddress.getByName(cidrOrIp.substring(0, slash));
            int prefix = Integer.parseInt(cidrOrIp.substring(slash + 1));
            byte[] targetBytes = target.getAddress();
            byte[] networkBytes = network.getAddress();
            if (targetBytes.length != networkBytes.length
                    || prefix < 0 || prefix > targetBytes.length * 8) {
                return false;
            }
            int fullBytes = prefix / 8;
            int remainderBits = prefix % 8;
            for (int i = 0; i < fullBytes; i++) {
                if (targetBytes[i] != networkBytes[i]) {
                    return false;
                }
            }
            if (remainderBits > 0) {
                int mask = (0xFF00 >> remainderBits) & 0xFF;
                return (targetBytes[fullBytes] & mask) == (networkBytes[fullBytes] & mask);
            }
            return true;
        } catch (Exception ex) {
            return false;
        }
    }
}
