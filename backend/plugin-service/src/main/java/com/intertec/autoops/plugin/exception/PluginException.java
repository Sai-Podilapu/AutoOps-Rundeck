package com.intertec.autoops.plugin.exception;

import org.springframework.http.HttpStatus;

/**
 * Domain error carrying a snake_case code + HTTP status, in the same shape
 * every other AutoOps service returns — the console keys off {@code error}.
 */
public class PluginException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    private PluginException(String error, String message, HttpStatus status) {
        super(message);
        this.error = error;
        this.status = status;
    }

    public static PluginException badRequest(String error, String message) {
        return new PluginException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static PluginException forbidden(String error, String message) {
        return new PluginException(error, message, HttpStatus.FORBIDDEN);
    }

    public static PluginException notFound(String error, String message) {
        return new PluginException(error, message, HttpStatus.NOT_FOUND);
    }

    public static PluginException conflict(String error, String message) {
        return new PluginException(error, message, HttpStatus.CONFLICT);
    }

    public static PluginException serviceUnavailable(String error, String message) {
        return new PluginException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }

    public String getError() {
        return error;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
