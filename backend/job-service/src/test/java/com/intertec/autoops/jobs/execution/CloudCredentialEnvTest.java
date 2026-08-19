package com.intertec.autoops.jobs.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The mapping that decides whether a cloud automation can authenticate at all.
 *
 * <p>Every SDK finds credentials by reading specific environment variable names.
 * Get one wrong and the failure surfaces as an opaque provider error — an
 * {@code InvalidClientTokenId} or an anonymous-caller denial — several frames
 * from the missing variable that caused it. So the names are asserted exactly.
 */
class CloudCredentialEnvTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private Map<String, String> env(String json, Path workDir) throws Exception {
        return CloudCredentialEnv.forBundle(MAPPER.readTree(json), workDir);
    }

    @Test
    void awsCredentialsBecomeTheVariablesBoto3AndTheCliRead() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AWS","connection":"AWS - Auto-Ops",
                 "data":{"accessId":"AKIAEXAMPLE","secret":"s3cr3t","region":"eu-west-1"}}
                """, null);

        assertEquals("AKIAEXAMPLE", env.get("AWS_ACCESS_KEY_ID"));
        assertEquals("s3cr3t", env.get("AWS_SECRET_ACCESS_KEY"));
        // Both spellings: boto3 prefers AWS_DEFAULT_REGION, the newer SDKs
        // AWS_REGION. Setting one and not the other produces a client that
        // works in one language and not another.
        assertEquals("eu-west-1", env.get("AWS_DEFAULT_REGION"));
        assertEquals("eu-west-1", env.get("AWS_REGION"));
    }

    /**
     * Integrations have been stored under several spellings over time. Reading
     * only the newest would silently produce a half-set credential.
     */
    @Test
    void awsAcceptsEveryStoredSpellingOfTheKeyFields() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AWS","data":{"accessKeyId":"AKIA2","secretAccessKey":"shhh"}}
                """, null);

        assertEquals("AKIA2", env.get("AWS_ACCESS_KEY_ID"));
        assertEquals("shhh", env.get("AWS_SECRET_ACCESS_KEY"));
    }

    /**
     * A role-assumed integration is useless without its session token — the
     * key pair alone is rejected as an invalid client token, which reads like
     * a wrong password rather than a missing third field.
     */
    @Test
    void awsSessionTokenIsCarriedWhenPresent() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AWS","data":{"accessId":"A","secret":"B","sessionToken":"tok"}}
                """, null);

        assertEquals("tok", env.get("AWS_SESSION_TOKEN"));
    }

    @Test
    void awsOmitsTheSessionTokenWhenThereIsNone() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AWS","data":{"accessId":"A","secret":"B"}}
                """, null);

        // Absent, not empty: an empty AWS_SESSION_TOKEN is treated by the SDKs
        // as a token that is present and invalid.
        assertFalse(env.containsKey("AWS_SESSION_TOKEN"));
    }

    /**
     * Terraform reads {@code ARM_*}; the Azure SDKs and Connect-AzAccount read
     * {@code AZURE_*}. Emitting only one is how "it works in terraform but not
     * in Python" happens.
     */
    @Test
    void azureEmitsBothTheTerraformAndSdkVariableNames() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AZURE","data":{"clientId":"cid","clientSecret":"csec",
                 "tenantId":"tid","subscriptionId":"sub"}}
                """, null);

        assertEquals("cid", env.get("ARM_CLIENT_ID"));
        assertEquals("csec", env.get("ARM_CLIENT_SECRET"));
        assertEquals("tid", env.get("ARM_TENANT_ID"));
        assertEquals("sub", env.get("ARM_SUBSCRIPTION_ID"));

        assertEquals("cid", env.get("AZURE_CLIENT_ID"));
        assertEquals("csec", env.get("AZURE_CLIENT_SECRET"));
        assertEquals("tid", env.get("AZURE_TENANT_ID"));
        assertEquals("sub", env.get("AZURE_SUBSCRIPTION_ID"));
    }

    @Test
    void gcpWritesItsServiceAccountIntoTheStepsOwnWorkspace(@TempDir Path workDir)
            throws Exception {
        Map<String, String> env = env("""
                {"platform":"GCP","data":{"serviceAccount":"{\\"type\\":\\"service_account\\"}",
                 "projectId":"proj"}}
                """, workDir);

        Path written = Path.of(env.get("GOOGLE_APPLICATION_CREDENTIALS"));
        assertTrue(Files.exists(written));
        assertTrue(written.startsWith(workDir), "the key must land in the step's private area");
        assertEquals("proj", env.get("GOOGLE_PROJECT"));
    }

    /**
     * The common case: a step with no integration bound to it. It must get an
     * empty overlay rather than an exception — plenty of legitimate scripts
     * call a public API or do local work.
     */
    @Test
    void noBundleYieldsNoVariablesRatherThanFailing() throws Exception {
        assertTrue(CloudCredentialEnv.forBundle(null, null).isEmpty());
        assertTrue(env("null", null).isEmpty());
        assertTrue(env("{}", null).isEmpty());
    }

    /**
     * A platform this build does not know must produce NOTHING. Guessing a
     * partial mapping would hand an SDK half a credential, which fails later
     * and less clearly than having none.
     */
    @Test
    void anUnknownPlatformContributesNothing() throws Exception {
        assertTrue(env("""
                {"platform":"ORACLE","data":{"user":"u","key":"k"}}
                """, null).isEmpty());
    }

    @Test
    void blankValuesAreDroppedRatherThanExported() throws Exception {
        Map<String, String> env = env("""
                {"platform":"AWS","data":{"accessId":"A","secret":"B","region":"  "}}
                """, null);

        assertFalse(env.containsKey("AWS_REGION"),
                "a blank region would override the SDK's own default with nothing");
    }
}
