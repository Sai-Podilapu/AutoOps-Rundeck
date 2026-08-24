package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.exception.RundeckException;
import com.intertec.autoops.rundeck.web.dto.StepExecutionRequest;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * The translator is where a customer's step becomes a shell script, so its
 * failure modes are shell failure modes: a quote in a password, a heredoc
 * terminator inside a payload, a credential landing in a log. Each case below
 * is one of those.
 */
class StepTranslatorTest {

    private final StepTranslator translator = new StepTranslator();

    private static StepExecutionRequest step(String type, String value) {
        return step(type, value, null, null);
    }

    private static StepExecutionRequest step(String type, String value,
                                             Map<String, String> credentials,
                                             Map<String, Object> raw) {
        return new StepExecutionRequest("acme", 7L, 1L, 0, type, "label", value,
                raw, 60, credentials, null, null, null);
    }

    @Test
    @DisplayName("every script is bash, fails fast, and disables tracing before secrets")
    void preamble() {
        String body = translator.translate(step("command", "echo hi")).body();

        assertThat(body).startsWith("#!/bin/bash\n");
        // `set +x` must come BEFORE any export. With tracing on, every
        // credential below would be echoed into the execution log in clear.
        assertThat(body.indexOf("set +x")).isLessThan(body.indexOf("echo hi"));
    }

    @Test
    @DisplayName("pipefail is NOT imposed on a customer's script")
    void pipefailIsNotImposed() {
        // job-service ran step bodies as plain bash. Much of the automation
        // library pipes into `head`/`grep -q`, which close the pipe early and
        // SIGPIPE the upstream command (exit 141). Under pipefail that is a
        // failed step for a script that has worked for years — so the semantics
        // stay exactly as they were. This was caught by a live smoke test, not
        // by review.
        String command =
                translator.translate(step("command", "terraform version | head -1")).body();
        String script = translator.translate(step("script", "df -h | grep -q /")).body();

        assertThat(command).doesNotContain("pipefail");
        assertThat(command).doesNotContain("set -e\n");
        assertThat(script).doesNotContain("pipefail");
    }

    @Test
    @DisplayName("but a GENERATED sequence still stops on first failure")
    void generatedSequencesFailFast() {
        // `terraform init` failing must not be followed by `terraform apply`.
        String body = translator.translate(step("terraform", "resource {}")).body();

        assertThat(body).contains("set -e");
        assertThat(body.indexOf("set -e")).isLessThan(body.indexOf("terraform init"));
    }

    @Test
    @DisplayName("credentials become the env vars each toolchain already reads")
    void credentialsBecomeEnvironment() {
        String body = translator.translate(step("terraform", "resource \"null_resource\" \"x\" {}",
                Map.of("accessKeyId", "AKIA123", "secretAccessKey", "sec/ret",
                        "region", "eu-west-1"),
                Map.of("action", "plan"))).body();

        assertThat(body).contains("export AWS_ACCESS_KEY_ID='AKIA123'");
        assertThat(body).contains("export AWS_SECRET_ACCESS_KEY='sec/ret'");
        assertThat(body).contains("export AWS_DEFAULT_REGION='eu-west-1'");
        assertThat(body).contains("export AWS_REGION='eu-west-1'");
    }

    @Test
    @DisplayName("a quote in a secret cannot break out of its literal")
    void quotingIsInjectionSafe() {
        // A password of  '; rm -rf / #  is the classic. Single-quote escaping
        // must close, escape and reopen rather than let the value terminate.
        String body = translator.translate(step("pyscript", "print(1)",
                Map.of("secretAccessKey", "'; rm -rf / #"), null)).body();

        // '' (empty) + \' (a literal quote) + '; rm -rf / #' (a literal string)
        // — bash reads the whole thing as ONE word, so nothing executes.
        assertThat(body).contains("export AWS_SECRET_ACCESS_KEY=''\\''; rm -rf / #'");

        // The property that actually matters: the payload never becomes a
        // command of its own. Asserting on the escaped text alone would pass
        // just as happily for output that also injected — so check that no line
        // is the injected command.
        assertThat(body.lines())
                .noneMatch(line -> line.trim().startsWith("rm -rf"))
                .noneMatch(line -> line.trim().startsWith("; rm"));
        // And the export occupies exactly one line: a value that escaped its
        // quoting would spill onto the next.
        assertThat(body.lines().filter(l -> l.startsWith("export AWS_SECRET_ACCESS_KEY=")))
                .hasSize(1);
    }

    @Test
    @DisplayName("an absent credential emits no export at all")
    void blankCredentialsAreSkipped() {
        String body = translator.translate(step("command", "true",
                Map.of("accessKeyId", "", "region", "eu-west-1"), null)).body();

        assertThat(body).doesNotContain("AWS_ACCESS_KEY_ID");
        assertThat(body).contains("AWS_DEFAULT_REGION");
    }

    @Test
    @DisplayName("python is written to a file so tracebacks name real line numbers")
    void pythonRunsFromAFile() {
        String body = translator.translate(step("pyscript", "import boto3\nprint(1)")).body();

        assertThat(body).contains("mktemp");
        assertThat(body).contains("autoops-python");
        assertThat(body).contains("import boto3");
        // Cleaned up even when the step fails.
        assertThat(body).contains("trap 'rm -f \"$__step_py\"' EXIT");
    }

    @Test
    @DisplayName("a quoted heredoc means the body reaches the interpreter verbatim")
    void heredocDoesNotExpand() {
        String body = translator.translate(step("pyscript", "print('$HOME and `date`')")).body();

        // <<'DELIM' — quoted, so the shell expands nothing inside.
        assertThat(body).contains("<<'AUTOOPS_STEP_EOF_9f3c1'");
        assertThat(body).contains("print('$HOME and `date`')");
    }

    @Test
    @DisplayName("a body containing the delimiter is REFUSED, not silently truncated")
    void delimiterCollisionIsRefused() {
        // Truncating here would run a fragment of the author's code and report
        // success — a correctness cliff, not a cosmetic bug.
        assertThatThrownBy(() -> translator.translate(
                step("pyscript", "x = 1\nAUTOOPS_STEP_EOF_9f3c1\ny = 2")))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("would truncate");
    }

    @Test
    @DisplayName("terraform init always runs, and the action is bounded")
    void terraform() {
        String plan = translator.translate(
                step("terraform", "resource {}", null, Map.of("action", "plan"))).body();
        assertThat(plan).contains("terraform init -input=false");
        assertThat(plan).contains("terraform plan -input=false");

        String apply = translator.translate(step("terraform", "resource {}")).body();
        assertThat(apply).contains("terraform apply -auto-approve");

        assertThatThrownBy(() -> translator.translate(
                step("terraform", "x", null, Map.of("action", "nuke"))))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("init, plan, apply or destroy");
    }

    @Test
    @DisplayName("the kubeconfig is written 0600 and removed on exit")
    void kubernetesKubeconfig() {
        String body = translator.translate(step("kubernetes", "get pods -A",
                Map.of("kubeconfig", "apiVersion: v1"), null)).body();

        assertThat(body).contains("chmod 600 \"$__step_kube\"");
        assertThat(body).contains("export KUBECONFIG=");
        assertThat(body).contains("trap 'rm -f \"$__step_kube\"' EXIT");
        assertThat(body).contains("kubectl get pods -A");
    }

    @Test
    @DisplayName("a manifest goes in on stdin, leaving nothing on disk")
    void kubernetesManifestOnStdin() {
        String body = translator.translate(
                step("kubernetes", "apply\napiVersion: v1\nkind: Pod")).body();

        assertThat(body).contains("kubectl apply -f - <<'AUTOOPS_STEP_EOF_9f3c1'");
        assertThat(body).contains("kind: Pod");
    }

    @Test
    @DisplayName("lambda prints the response payload — invoke alone says nothing useful")
    void lambdaPrintsPayload() {
        String body = translator.translate(step("awslambda", "my-fn\n{\"k\":1}", null,
                Map.of("region", "us-east-1", "qualifier", "prod"))).body();

        assertThat(body).contains("aws lambda invoke --function-name 'my-fn'");
        assertThat(body).contains("--region 'us-east-1'");
        assertThat(body).contains("--qualifier 'prod'");
        assertThat(body).contains("cat \"$__step_out\"");
    }

    @Test
    @DisplayName("rest infers POST when a body is present and fails on 4xx WITH the body")
    void restMethodInference() {
        String get = translator.translate(step("rest", "https://api.x/health")).body();
        assertThat(get).contains("-X GET");

        String post = translator.translate(step("rest", "https://api.x/deploy\n{\"a\":1}")).body();
        assertThat(post).contains("-X POST");
        // --fail-with-body, not --fail: an operator needs the error response,
        // which plain --fail throws away.
        assertThat(post).contains("--fail-with-body");

        String explicit = translator.translate(step("rest", "DELETE https://api.x/thing")).body();
        assertThat(explicit).contains("-X DELETE");
    }

    @Test
    @DisplayName("the azure function key rides in a header, never in the URL")
    void azureKeyIsNotInTheUrl() {
        String body = translator.translate(step("azurefn",
                "https://app.azurewebsites.net/api/Fn\n{\"a\":1}",
                Map.of("functionKey", "super-secret-key"), null)).body();

        // The URL is what Rundeck records and logs; the header is not.
        assertThat(body).contains("x-functions-key: $AZURE_FUNCTION_KEY");
        assertThat(body).doesNotContain("?code=super-secret-key");
        // The body file must be written BEFORE the curl that reads it.
        assertThat(body.indexOf("__step_body=")).isLessThan(body.indexOf("curl -sS"));
    }

    @Test
    @DisplayName("ssh uses BatchMode so a password prompt fails instead of hanging")
    void sshBatchMode() {
        String body = translator.translate(step("ssh", "deploy@web-01 systemctl restart app"))
                .body();

        assertThat(body).contains("ssh -o BatchMode=yes");
        assertThat(body).contains("'deploy@web-01'");
        assertThat(body).contains("'systemctl restart app'");
    }

    @Test
    @DisplayName("an ssh step without a command is refused")
    void sshNeedsACommand() {
        assertThatThrownBy(() -> translator.translate(step("ssh", "deploy@web-01")))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("user@host");
    }

    @Test
    @DisplayName("powershell is refused clearly rather than half-working on Linux")
    void powershellIsRefused() {
        // pwsh on Linux lacks the Windows-only cmdlets the script library uses,
        // so "installed" would mean failing deep inside someone's script.
        assertThatThrownBy(() -> translator.translate(step("powershell", "Get-Service")))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("Windows execution node");
    }

    @Test
    @DisplayName("an EMPTY step body is refused — a silent no-op is worse than a failure")
    void emptyBodyIsRefused() {
        // job-service's ScriptRunner refused this. Without the guard the
        // translator emits a script of nothing, exits 0, and the run log reads
        // "ok" for a job that did nothing at all. Found by running against real
        // job definitions, not by review.
        for (String type : new String[]{"script", "pyscript", "command", "terraform",
                "kubernetes", "awslambda", "rest", "ssh"}) {
            assertThatThrownBy(() -> translator.translate(step(type, "   ")))
                    .as("empty %s step", type)
                    .isInstanceOf(RundeckException.class)
                    .hasMessageContaining("no content");
        }
    }

    @Test
    @DisplayName("a `test` step may be empty — it exists to succeed")
    void testStepMayBeEmpty() {
        assertThat(translator.translate(step("test", "")).body()).contains("echo ''");
    }

    @Test
    @DisplayName("an unknown step type is refused, not silently run as a shell command")
    void unknownTypeIsRefused() {
        assertThatThrownBy(() -> translator.translate(step("wat", "rm -rf /")))
                .isInstanceOf(RundeckException.class)
                .hasMessageContaining("Unknown step type");
    }
}
