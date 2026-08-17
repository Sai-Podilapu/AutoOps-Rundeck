package com.intertec.autoops.agent.exception;

import org.springframework.http.HttpStatus;

/**
 * Domain error carrying a snake_case code + HTTP status. The codes are the
 * SAME ones core-service used to return for workflows ({@code
 * workflow_not_found}, {@code workflow_exists}, {@code invalid_definition},
 * {@code project_not_found}, plus the gate's reasons) — the console keys off
 * them, so the split must not change a single one.
 */
public class AgentException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    private AgentException(String error, String message, HttpStatus status) {
        super(message);
        this.error = error;
        this.status = status;
    }

    public static AgentException badRequest(String error, String message) {
        return new AgentException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static AgentException forbidden(String error, String message) {
        return new AgentException(error, message, HttpStatus.FORBIDDEN);
    }

    public static AgentException notFound(String error, String message) {
        return new AgentException(error, message, HttpStatus.NOT_FOUND);
    }

    public static AgentException conflict(String error, String message) {
        return new AgentException(error, message, HttpStatus.CONFLICT);
    }

    public static AgentException serviceUnavailable(String error, String message) {
        return new AgentException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }

    /**
     * Our fault, not the caller's — a run whose saved state cannot be read or
     * written. Kept distinct from {@link #badRequest} so an operator is not
     * sent looking for a mistake they did not make.
     */
    public static AgentException internal(String error, String message) {
        return new AgentException(error, message, HttpStatus.INTERNAL_SERVER_ERROR);
    }

    public String getError() {
        return error;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
