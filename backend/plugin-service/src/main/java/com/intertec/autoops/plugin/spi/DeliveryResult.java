package com.intertec.autoops.plugin.spi;

/**
 * What happened on one delivery attempt.
 *
 * <p>{@code retryable} is the distinction that matters operationally: a 429 or
 * a 503 is worth another attempt, a 404 from a deleted Slack webhook never
 * will be. Getting this wrong in the permanent direction loses notifications;
 * getting it wrong in the transient direction hammers a third party until they
 * rate-limit the whole tenant.
 *
 * <p>A plugin must never throw. Anything it cannot handle becomes a
 * {@link #failure} so the attempt is recorded and the fan-out continues to the
 * tenant's other channels.
 */
public record DeliveryResult(boolean ok, Integer statusCode, String detail, boolean retryable) {

    // Named success(), not ok(): a static ok() would clash with the record's
    // own ok() accessor and the class would not compile.

    public static DeliveryResult success() {
        return new DeliveryResult(true, null, null, false);
    }

    public static DeliveryResult success(int statusCode) {
        return new DeliveryResult(true, statusCode, null, false);
    }

    public static DeliveryResult success(int statusCode, String detail) {
        return new DeliveryResult(true, statusCode, detail, false);
    }

    /** Permanent: bad credentials, deleted channel, malformed request. */
    public static DeliveryResult failure(String detail) {
        return new DeliveryResult(false, null, detail, false);
    }

    public static DeliveryResult failure(int statusCode, String detail) {
        return new DeliveryResult(false, statusCode, detail, false);
    }

    /** Transient: timeout, connection reset, 429, 5xx. Worth another attempt. */
    public static DeliveryResult retryable(String detail) {
        return new DeliveryResult(false, null, detail, true);
    }

    public static DeliveryResult retryable(int statusCode, String detail) {
        return new DeliveryResult(false, statusCode, detail, true);
    }

    /** Truncated for the delivery_attempts row — providers echo whole payloads. */
    public String detailForStorage() {
        if (detail == null) {
            return null;
        }
        return detail.length() <= 1000 ? detail : detail.substring(0, 1000) + "…";
    }
}
