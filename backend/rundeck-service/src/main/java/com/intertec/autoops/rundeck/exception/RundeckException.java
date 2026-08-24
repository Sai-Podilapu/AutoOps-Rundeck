package com.intertec.autoops.rundeck.exception;

import org.springframework.http.HttpStatus;

/**
 * Domain error carrying a snake_case code + HTTP status, matching the
 * convention every other AutoOps service uses so the console can key off the
 * code rather than parse prose.
 *
 * <p>The codes that matter to the UI:
 * {@code connection_not_found}, {@code connection_exists},
 * {@code connection_disabled}, {@code insecure_upstream},
 * {@code rundeck_unreachable}, {@code rundeck_unauthorized},
 * {@code rundeck_error}, plus the subscription gate's reasons.
 */
public class RundeckException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    private RundeckException(String error, String message, HttpStatus status) {
        super(message);
        this.error = error;
        this.status = status;
    }

    public static RundeckException badRequest(String error, String message) {
        return new RundeckException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static RundeckException forbidden(String error, String message) {
        return new RundeckException(error, message, HttpStatus.FORBIDDEN);
    }

    public static RundeckException notFound(String error, String message) {
        return new RundeckException(error, message, HttpStatus.NOT_FOUND);
    }

    public static RundeckException conflict(String error, String message) {
        return new RundeckException(error, message, HttpStatus.CONFLICT);
    }

    /**
     * The upstream Rundeck failed us — it was unreachable, refused our token,
     * or answered with something we could not use. Deliberately 502, not 500:
     * this service is healthy, the server it depends on is not, and an operator
     * reading the status code should be pointed at the right box.
     */
    public static RundeckException upstream(String error, String message) {
        return new RundeckException(error, message, HttpStatus.BAD_GATEWAY);
    }

    public static RundeckException serviceUnavailable(String error, String message) {
        return new RundeckException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }

    public String getError() {
        return error;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
