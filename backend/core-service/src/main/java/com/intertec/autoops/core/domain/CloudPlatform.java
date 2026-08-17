package com.intertec.autoops.core.domain;

import java.util.Locale;

/** Supported cloud/integration platforms (mirrors the frontend catalog). */
public enum CloudPlatform {
    AWS,
    AZURE,
    GCP,
    HUAWEI,
    ORACLE,
    M365,
    KUBERNETES;

    /** Case-insensitive, null-safe parse (same convention as the other enums). */
    public static CloudPlatform fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        try {
            return valueOf(code.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            return null;
        }
    }
}
