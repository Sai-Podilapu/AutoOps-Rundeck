package com.intertec.autoops.core.web.dto;

/**
 * Returned by the run trigger instead of a run when the job needs an admin
 * sign-off: the client keys off {@code approvalRequired}.
 */
public record ApprovalRequiredResponse(boolean approvalRequired, ApprovalResponse approval) {

    public static ApprovalRequiredResponse of(ApprovalResponse approval) {
        return new ApprovalRequiredResponse(true, approval);
    }
}