package com.intertec.autoops.jobs.sandbox;

import java.nio.file.attribute.GroupPrincipal;
import java.nio.file.attribute.UserPrincipal;

/**
 * One throwaway OS identity from the step pool. It owns nothing in the image,
 * has no shell and no home of its own — its only purpose is to be a different
 * uid from whatever the concurrent step is running as.
 *
 * @param suExecPath the absolute path of the privilege-dropping helper, resolved once at startup
 */
record StepUser(String name, UserPrincipal principal, GroupPrincipal group, String suExecPath) {
}
