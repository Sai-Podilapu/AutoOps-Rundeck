package com.intertec.autoops.plugin.spi;

/**
 * One input a plugin needs before it can deliver anything. The console renders
 * the install form straight from these, so a new plugin needs no frontend work.
 *
 * <p>{@link Type#SECRET} is load-bearing, not cosmetic: those values are the
 * only ones encrypted at rest, and they are the only ones the API refuses to
 * read back. A webhook URL counts as a secret — possession of it IS the
 * authority to post into the channel.
 */
public record ConfigField(
        String name,
        String label,
        Type type,
        boolean required,
        String placeholder,
        String help) {

    public enum Type {
        TEXT,
        /** Write-only: encrypted at rest, never serialised back to a caller. */
        SECRET,
        URL,
        EMAIL,
        NUMBER,
        BOOLEAN
    }

    public static ConfigField text(String name, String label, boolean required, String help) {
        return new ConfigField(name, label, Type.TEXT, required, null, help);
    }

    public static ConfigField secret(String name, String label, boolean required, String help) {
        return new ConfigField(name, label, Type.SECRET, required, null, help);
    }

    public static ConfigField url(String name, String label, boolean required, String help) {
        return new ConfigField(name, label, Type.URL, required, null, help);
    }

    public static ConfigField email(String name, String label, boolean required, String help) {
        return new ConfigField(name, label, Type.EMAIL, required, null, help);
    }

    public static ConfigField number(String name, String label, boolean required, String help) {
        return new ConfigField(name, label, Type.NUMBER, required, null, help);
    }

    public ConfigField withPlaceholder(String value) {
        return new ConfigField(name, label, type, required, value, help);
    }

    public boolean isSecret() {
        return type == Type.SECRET;
    }
}
