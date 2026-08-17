package com.intertec.autoops.core.service;

import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The signer is hand-rolled, so a mistake here surfaces only as an opaque 403
 * from AWS or Huawei against a credential the operator believes is correct.
 *
 * <p>These are structural and differential checks rather than assertions
 * against the vendors' published test vectors: the header layout, the
 * date/scope wiring, and the property that changing any signing input changes
 * the signature. That catches format and plumbing errors — the failure modes
 * that would otherwise be indistinguishable from a bad key.
 */
class SigV4SignerTest {

    private static final Instant AT = Instant.parse("2026-08-06T05:10:42Z");

    // ---- AWS Signature V4 ----------------------------------------------

    @Test
    void awsProducesTheDocumentedHeaderLayout() {
        var signed = SigV4Signer.signAws("bedrock.us-east-1.amazonaws.com", "/foundation-models",
                "bedrock", "us-east-1", "AKIAEXAMPLE", "secret", AT);

        assertThat(signed.headers()).containsKeys("Authorization", "X-Amz-Date");
        assertThat(signed.headers().get("X-Amz-Date")).isEqualTo("20260806T051042Z");

        String auth = signed.headers().get("Authorization");
        assertThat(auth).startsWith("AWS4-HMAC-SHA256 ");
        // Credential scope is date/region/service/aws4_request — a wrong scope
        // is accepted by the signer and rejected by AWS.
        assertThat(auth).contains("Credential=AKIAEXAMPLE/20260806/us-east-1/bedrock/aws4_request");
        assertThat(auth).contains("SignedHeaders=host;x-amz-date");
        assertThat(auth).containsPattern("Signature=[0-9a-f]{64}$");
    }

    @Test
    void awsSignsTheBodyWhenThereIsOne() {
        // SageMaker's control plane is JSON-RPC, so listing a tenant's
        // endpoints is a POST. The payload hash is part of the canonical
        // request: sign the empty string while sending a body and AWS rejects
        // it, which is a failure that only ever shows up against the real API.
        var withBody = SigV4Signer.signAws("POST", "api.sagemaker.us-east-1.amazonaws.com", "/",
                "sagemaker", "us-east-1", "AKIAEXAMPLE", "secret", "{\"MaxResults\":100}", AT);
        var withoutBody = SigV4Signer.signAws("POST", "api.sagemaker.us-east-1.amazonaws.com", "/",
                "sagemaker", "us-east-1", "AKIAEXAMPLE", "secret", "", AT);

        assertThat(withBody.headers().get("Authorization"))
                .isNotEqualTo(withoutBody.headers().get("Authorization"));
        assertThat(withBody.headers().get("Authorization"))
                .contains("Credential=AKIAEXAMPLE/20260806/us-east-1/sagemaker/aws4_request")
                .containsPattern("Signature=[0-9a-f]{64}$");

        // The method is signed too — a GET and a POST over the same path and
        // body must not produce the same signature.
        assertThat(SigV4Signer.signAws("GET", "h", "/p", "sagemaker", "us-east-1", "AK", "SK",
                        "{}", AT).headers().get("Authorization"))
                .isNotEqualTo(SigV4Signer.signAws("POST", "h", "/p", "sagemaker", "us-east-1",
                        "AK", "SK", "{}", AT).headers().get("Authorization"));
    }

    @Test
    void awsBodylessOverloadStillMatchesTheGeneralForm() {
        // The 7-arg form is the one Bedrock and every existing caller use; it
        // must stay byte-identical to an explicit bodyless GET.
        assertThat(SigV4Signer.signAws("h", "/p", "bedrock", "us-east-1", "AK", "SK", AT).headers())
                .isEqualTo(SigV4Signer.signAws("GET", "h", "/p", "bedrock", "us-east-1",
                        "AK", "SK", "", AT).headers());
    }

    @Test
    void awsSignatureIsDeterministicForTheSameInputs() {
        var a = SigV4Signer.signAws("h", "/p", "bedrock", "us-east-1", "AK", "SK", AT);
        var b = SigV4Signer.signAws("h", "/p", "bedrock", "us-east-1", "AK", "SK", AT);
        assertThat(a.headers()).isEqualTo(b.headers());
    }

    @Test
    void awsSignatureChangesWithEverySigningInput() {
        String base = sigAws("host", "/p", "bedrock", "us-east-1", "AK", "SK", AT);

        assertThat(sigAws("other", "/p", "bedrock", "us-east-1", "AK", "SK", AT))
                .as("host is part of the canonical request").isNotEqualTo(base);
        assertThat(sigAws("host", "/other", "bedrock", "us-east-1", "AK", "SK", AT))
                .as("path is part of the canonical request").isNotEqualTo(base);
        assertThat(sigAws("host", "/p", "s3", "us-east-1", "AK", "SK", AT))
                .as("service is part of the scope").isNotEqualTo(base);
        assertThat(sigAws("host", "/p", "bedrock", "eu-west-1", "AK", "SK", AT))
                .as("region is part of the scope").isNotEqualTo(base);
        assertThat(sigAws("host", "/p", "bedrock", "us-east-1", "AK", "other", AT))
                .as("secret key drives the derived key").isNotEqualTo(base);
        assertThat(sigAws("host", "/p", "bedrock", "us-east-1", "AK", "SK",
                AT.plusSeconds(86_400)))
                .as("a different day is a different scope").isNotEqualTo(base);
    }

    // ---- Huawei SDK-HMAC-SHA256 -----------------------------------------

    @Test
    void huaweiProducesItsOwnHeaderLayout() {
        var signed = SigV4Signer.signHuawei("modelarts.cn-north-4.myhuaweicloud.com",
                "/v1/proj/models", "AK", "SK", AT);

        assertThat(signed.headers()).containsKeys("Authorization", "X-Sdk-Date");
        assertThat(signed.headers().get("X-Sdk-Date")).isEqualTo("20260806T051042Z");

        String auth = signed.headers().get("Authorization");
        // Huawei uses Access=, not Credential=, and carries no credential scope.
        assertThat(auth).startsWith("SDK-HMAC-SHA256 ");
        assertThat(auth).contains("Access=AK");
        assertThat(auth).doesNotContain("aws4_request");
        assertThat(auth).contains("SignedHeaders=host;x-sdk-date");
        assertThat(auth).containsPattern("Signature=[0-9a-f]{64}$");
    }

    @Test
    void huaweiTreatsAPathAsAlreadySlashTerminated() {
        // Huawei canonicalises the URI with a trailing slash. Signing "/a" and
        // "/a/" must therefore agree, or one of the two silently 403s.
        String withoutSlash = sigHuawei("host", "/v1/proj/models");
        String withSlash = sigHuawei("host", "/v1/proj/models/");
        assertThat(withoutSlash).isEqualTo(withSlash);
    }

    @Test
    void huaweiSignatureChangesWithTheSecret() {
        assertThat(SigV4Signer.signHuawei("host", "/p", "AK", "SK", AT).headers()
                .get("Authorization"))
                .isNotEqualTo(SigV4Signer.signHuawei("host", "/p", "AK", "other", AT).headers()
                        .get("Authorization"));
    }

    @Test
    void theTwoSchemesDoNotProduceTheSameSignature() {
        // Guards against a copy-paste that routes one vendor through the
        // other's key derivation.
        assertThat(sigAws("host", "/p", "bedrock", "us-east-1", "AK", "SK", AT))
                .isNotEqualTo(sigHuawei("host", "/p"));
    }

    private static String sigAws(String host, String path, String service, String region,
                                 String ak, String sk, Instant at) {
        return SigV4Signer.signAws(host, path, service, region, ak, sk, at)
                .headers().get("Authorization");
    }

    private static String sigHuawei(String host, String path) {
        return SigV4Signer.signHuawei(host, path, "AK", "SK", AT).headers().get("Authorization");
    }
}
