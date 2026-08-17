package com.intertec.autoops.auth.security;

/**
 * ThreadLocal tenant holder populated by {@link TenantFilter} and cleared in a
 * finally block after each request. There is no silent fallback here: the
 * filter decides the tenant (validated header or configured default) before
 * any request handling runs.
 */
public final class TenantContext {

    public static final String HEADER = "X-Tenant-ID";

    private static final ThreadLocal<String> CURRENT = new ThreadLocal<>();

    private TenantContext() {
    }

    public static String get() {
        String tenantId = CURRENT.get();
        if (tenantId == null || tenantId.isBlank()) {
            throw new IllegalStateException(
                    "Tenant has not been resolved for this request (TenantFilter not applied?)");
        }
        return tenantId;
    }

    public static void set(String tenantId) {
        CURRENT.set(tenantId);
    }

    public static void clear() {
        CURRENT.remove();
    }
}
