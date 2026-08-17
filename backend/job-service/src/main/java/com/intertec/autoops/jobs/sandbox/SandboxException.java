package com.intertec.autoops.jobs.sandbox;

/**
 * The step cannot be given a safe place to run — so it does not run. The
 * message is shown to the user in the run log, so it says what to do about it.
 */
public class SandboxException extends Exception {

    public SandboxException(String message) {
        super(message);
    }
}
