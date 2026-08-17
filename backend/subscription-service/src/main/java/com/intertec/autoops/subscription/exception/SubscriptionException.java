package com.intertec.autoops.subscription.exception;

import org.springframework.http.HttpStatus;

/** Domain exception rendered as a consistent JSON error body. */
public class SubscriptionException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    public SubscriptionException(String error, String message, HttpStatus status) {
        super(message);
        this.error = error;
        this.status = status;
    }

    public String getError() {
        return error;
    }

    public HttpStatus getStatus() {
        return status;
    }

    public static SubscriptionException badRequest(String error, String message) {
        return new SubscriptionException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static SubscriptionException notFound(String error, String message) {
        return new SubscriptionException(error, message, HttpStatus.NOT_FOUND);
    }

    public static SubscriptionException conflict(String error, String message) {
        return new SubscriptionException(error, message, HttpStatus.CONFLICT);
    }

    public static SubscriptionException serviceUnavailable(String error, String message) {
        return new SubscriptionException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }
}
