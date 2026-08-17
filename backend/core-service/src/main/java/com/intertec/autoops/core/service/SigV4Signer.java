package com.intertec.autoops.core.service;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Map;
import java.util.TreeMap;

/**
 * Request signing for the two model vendors that will not accept a bearer
 * token: AWS Bedrock (AWS Signature V4) and Huawei Cloud (SDK-HMAC-SHA256,
 * their APIG derivative of the same scheme).
 *
 * <p>Written by hand rather than pulled from a vendor SDK: core-service has no
 * AWS or Huawei dependency today, and this is used for exactly one read-only
 * GET per vendor. Cloud-account credential verification is a different
 * concern and still belongs to job-service — do not route that through here.
 *
 * <p>The two schemes share a canonical-request layout and differ in how the
 * signing key is produced: AWS derives a four-step key chain scoped to
 * date/region/service, Huawei signs the string directly with the secret key.
 */
final class SigV4Signer {

    private static final DateTimeFormatter STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);
    private static final DateTimeFormatter DAY =
            DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC);
    private static final String HMAC = "HmacSHA256";
    /** SHA-256 of the empty string — every request here is a bodyless GET. */
    private static final String EMPTY_BODY_SHA256 = sha256Hex("");

    private SigV4Signer() {
    }

    /** Headers to add to the outbound request, in name -> value form. */
    record SignedHeaders(Map<String, String> headers) {
    }

    /**
     * AWS Signature Version 4 for a bodyless GET.
     *
     * @param host          e.g. {@code bedrock.us-east-1.amazonaws.com}
     * @param canonicalUri  path, already URI-encoded, e.g. {@code /foundation-models}
     * @param service       e.g. {@code bedrock}
     */
    static SignedHeaders signAws(String host, String canonicalUri, String service,
                                 String region, String accessKeyId, String secretAccessKey,
                                 Instant now) {
        return signAws("GET", host, canonicalUri, service, region, accessKeyId,
                secretAccessKey, "", now);
    }

    /**
     * The same signature over a request that carries a body.
     *
     * <p>Needed because not every AWS service answers a GET: SageMaker's
     * control plane is JSON-RPC, so listing a tenant's endpoints is a POST
     * with {@code X-Amz-Target}. The payload hash is the ONLY part that
     * changes — {@code X-Amz-Target} and {@code Content-Type} are sent
     * unsigned, which AWS accepts because verification covers exactly the
     * headers named in {@code SignedHeaders}.
     *
     * @param payload the exact bytes that will be sent, "" for a bodyless call
     */
    static SignedHeaders signAws(String method, String host, String canonicalUri, String service,
                                 String region, String accessKeyId, String secretAccessKey,
                                 String payload, Instant now) {
        String amzDate = STAMP.format(now);
        String day = DAY.format(now);
        String payloadSha256 = payload == null || payload.isEmpty()
                ? EMPTY_BODY_SHA256
                : sha256Hex(payload);

        String canonicalHeaders = "host:" + host + "\n" + "x-amz-date:" + amzDate + "\n";
        String signedHeaderNames = "host;x-amz-date";
        String canonicalRequest = String.join("\n",
                method, canonicalUri, "", canonicalHeaders, signedHeaderNames, payloadSha256);

        String scope = day + "/" + region + "/" + service + "/aws4_request";
        String stringToSign = String.join("\n",
                "AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(canonicalRequest));

        // Derived key chain — this is what distinguishes AWS from Huawei below.
        byte[] key = hmac(("AWS4" + secretAccessKey).getBytes(StandardCharsets.UTF_8), day);
        key = hmac(key, region);
        key = hmac(key, service);
        key = hmac(key, "aws4_request");
        String signature = hex(hmac(key, stringToSign));

        String authorization = "AWS4-HMAC-SHA256 Credential=" + accessKeyId + "/" + scope
                + ", SignedHeaders=" + signedHeaderNames + ", Signature=" + signature;

        return new SignedHeaders(Map.of(
                "X-Amz-Date", amzDate,
                "Authorization", authorization));
    }

    /**
     * Huawei Cloud APIG SDK-HMAC-SHA256 for a bodyless GET.
     *
     * <p>Huawei requires the canonical URI to end in {@code /} — a path signed
     * without the trailing slash produces a valid-looking signature the
     * gateway then rejects.
     */
    static SignedHeaders signHuawei(String host, String canonicalUri, String accessKey,
                                    String secretKey, Instant now) {
        String sdkDate = STAMP.format(now);
        String uri = canonicalUri.endsWith("/") ? canonicalUri : canonicalUri + "/";

        Map<String, String> signed = new TreeMap<>();
        signed.put("host", host);
        signed.put("x-sdk-date", sdkDate);

        StringBuilder canonicalHeaders = new StringBuilder();
        signed.forEach((k, v) -> canonicalHeaders.append(k).append(':').append(v).append('\n'));
        String signedHeaderNames = String.join(";", signed.keySet());

        String canonicalRequest = String.join("\n",
                "GET", uri, "", canonicalHeaders.toString(), signedHeaderNames,
                EMPTY_BODY_SHA256);
        String stringToSign = String.join("\n",
                "SDK-HMAC-SHA256", sdkDate, sha256Hex(canonicalRequest));

        // Direct HMAC with the secret key — no derived chain, no credential scope.
        String signature = hex(hmac(secretKey.getBytes(StandardCharsets.UTF_8), stringToSign));

        String authorization = "SDK-HMAC-SHA256 Access=" + accessKey
                + ", SignedHeaders=" + signedHeaderNames + ", Signature=" + signature;

        return new SignedHeaders(Map.of(
                "X-Sdk-Date", sdkDate,
                "Authorization", authorization));
    }

    private static byte[] hmac(byte[] key, String data) {
        try {
            Mac mac = Mac.getInstance(HMAC);
            mac.init(new SecretKeySpec(key, HMAC));
            return mac.doFinal(data.getBytes(StandardCharsets.UTF_8));
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot sign request", ex);
        }
    }

    private static String sha256Hex(String value) {
        try {
            return hex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception ex) {
            throw new IllegalStateException("Cannot hash request", ex);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xf, 16))
                    .append(Character.forDigit(b & 0xf, 16));
        }
        return out.toString();
    }
}
