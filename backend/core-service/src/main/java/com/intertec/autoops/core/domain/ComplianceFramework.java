package com.intertec.autoops.core.domain;

import java.util.Locale;

/** Frameworks a report can be generated against. Mirrors the MySQL ENUM. */
public enum ComplianceFramework {
    SOC2("SOC 2"),
    ISO_27001("ISO 27001"),
    HIPAA("HIPAA"),
    PCI_DSS("PCI-DSS"),
    GDPR("GDPR");

    private final String label;

    ComplianceFramework(String label) {
        this.label = label;
    }

    public String label() {
        return label;
    }

    /** Null-safe lenient parse ("SOC 2", "soc2", "PCI-DSS" all work); null when unknown. */
    public static ComplianceFramework fromCode(String code) {
        if (code == null || code.isBlank()) {
            return null;
        }
        String normalized = code.trim().toUpperCase(Locale.ROOT).replaceAll("[^A-Z0-9]", "");
        for (ComplianceFramework framework : values()) {
            if (framework.name().replace("_", "").equals(normalized)) {
                return framework;
            }
        }
        return null;
    }
}