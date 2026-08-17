package com.intertec.autoops.auth.exception;

import org.springframework.http.HttpStatus;

/**
 * Domain exception for business validation failures. Rendered as a consistent
 * JSON error body by {@link GlobalExceptionHandler}.
 */
public class AuthException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    public AuthException(String error, String message, HttpStatus status) {
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

    public static AuthException badRequest(String error, String message) {
        return new AuthException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static AuthException unauthorized(String error, String message) {
        return new AuthException(error, message, HttpStatus.UNAUTHORIZED);
    }

    public static AuthException forbidden(String error, String message) {
        return new AuthException(error, message, HttpStatus.FORBIDDEN);
    }

    public static AuthException notFound(String error, String message) {
        return new AuthException(error, message, HttpStatus.NOT_FOUND);
    }

    public static AuthException conflict(String error, String message) {
        return new AuthException(error, message, HttpStatus.CONFLICT);
    }

    public static AuthException tooManyRequests(String error, String message) {
        return new AuthException(error, message, HttpStatus.TOO_MANY_REQUESTS);
    }

    public static AuthException serviceUnavailable(String error, String message) {
        return new AuthException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }
}
