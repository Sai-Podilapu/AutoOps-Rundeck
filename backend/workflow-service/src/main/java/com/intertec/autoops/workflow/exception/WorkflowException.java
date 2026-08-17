package com.intertec.autoops.workflow.exception;

import org.springframework.http.HttpStatus;

/**
 * Domain error carrying a snake_case code + HTTP status. The codes are the
 * SAME ones core-service used to return for workflows ({@code
 * workflow_not_found}, {@code workflow_exists}, {@code invalid_definition},
 * {@code project_not_found}, plus the gate's reasons) — the console keys off
 * them, so the split must not change a single one.
 */
public class WorkflowException extends RuntimeException {

    private final String error;
    private final HttpStatus status;

    private WorkflowException(String error, String message, HttpStatus status) {
        super(message);
        this.error = error;
        this.status = status;
    }

    public static WorkflowException badRequest(String error, String message) {
        return new WorkflowException(error, message, HttpStatus.BAD_REQUEST);
    }

    public static WorkflowException forbidden(String error, String message) {
        return new WorkflowException(error, message, HttpStatus.FORBIDDEN);
    }

    public static WorkflowException notFound(String error, String message) {
        return new WorkflowException(error, message, HttpStatus.NOT_FOUND);
    }

    public static WorkflowException conflict(String error, String message) {
        return new WorkflowException(error, message, HttpStatus.CONFLICT);
    }

    public static WorkflowException serviceUnavailable(String error, String message) {
        return new WorkflowException(error, message, HttpStatus.SERVICE_UNAVAILABLE);
    }

    public String getError() {
        return error;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
