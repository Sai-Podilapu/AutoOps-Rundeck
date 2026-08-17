package com.intertec.autoops.auth.service;

import java.util.Locale;
import java.util.Set;

/**
 * Distinguishes corporate email domains (which claim a workspace — one
 * organization per domain) from free mailbox providers (which never do:
 * the first gmail.com user must not lock out every other gmail.com user).
 * Keep this list in sync with the V8 migration's backfill exclusion list.
 */
public final class FreeEmailDomains {

    private static final Set<String> FREE_PROVIDERS = Set.of(
            "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "ymail.com",
            "outlook.com", "hotmail.com", "live.com", "msn.com",
            "icloud.com", "me.com", "mac.com", "aol.com",
            "proton.me", "protonmail.com", "pm.me", "zoho.com", "zohomail.in",
            "gmx.com", "gmx.net", "mail.com", "yandex.com", "yandex.ru", "rediffmail.com");

    private FreeEmailDomains() {
    }

    /**
     * The lowercase domain of the email when it is a claimable corporate
     * domain, or {@code null} for free providers / unparseable addresses.
     */
    public static String corporateDomain(String email) {
        int at = email == null ? -1 : email.lastIndexOf('@');
        if (at < 0 || at == email.length() - 1) {
            return null;
        }
        String domain = email.substring(at + 1).trim().toLowerCase(Locale.ROOT);
        return domain.isBlank() || FREE_PROVIDERS.contains(domain) ? null : domain;
    }
}
