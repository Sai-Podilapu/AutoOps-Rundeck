package com.intertec.autoops.jobs.execution.aws;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;

/**
 * Minimal AWS Signature V4 signer for the handful of AWS API calls this
 * runtime makes (Lambda Invoke, STS GetCallerIdentity). Kept dependency-free
 * on purpose — the whole service is JDK HttpClient based and pulling the AWS
 * SDK for two endpoints would triple the image for no gain.
 *
 * <p>Returns the headers to add to the request: {@code x-amz-date},
 * {@code authorization} and, for temporary credentials,
 * {@code x-amz-security-token}. The {@code host} header is computed exactly
 * as JDK HttpClient will send it (it cannot be set manually) so the
 * signature matches the wire request.
 */
public final class AwsV4 {

    private static final DateTimeFormatter AMZ_DATE =
            DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);
    private static final DateTimeFormatter DATE_STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC);

    private AwsV4() {
    }

    /**
     * @param uri full request URI; its raw path/query are used verbatim as the
     *            canonical path/query, so the caller must pre-encode path
     *            segments (see {@link #encodeSegment})
     */
    public static Map<String, String> headers(String method, URI uri, String region,
                                              String service, String accessKey,
                                              String secretKey, String sessionToken,
                                              byte[] payload, Instant now) {
        String amzDate = AMZ_DATE.format(now);
        String dateStamp = DATE_STAMP.format(now);
        String payloadHash = sha256Hex(payload == null ? new byte[0] : payload);

        String hostHeader = uri.getHost()
                + (uri.getPort() != -1 && uri.getPort() != defaultPort(uri)
                        ? ":" + uri.getPort() : "");

        TreeMap<String, String> signedHeaderMap = new TreeMap<>();
        signedHeaderMap.put("host", hostHeader);
        signedHeaderMap.put("x-amz-date", amzDate);
        if (sessionToken != null && !sessionToken.isBlank()) {
            signedHeaderMap.put("x-amz-security-token", sessionToken);
        }
        StringBuilder canonicalHeaders = new StringBuilder();
        signedHeaderMap.forEach((k, v) -> canonicalHeaders.append(k).append(':')
                .append(v.trim()).append('\n'));
        String signedHeaders = String.join(";", signedHeaderMap.keySet());

        String canonicalPath = uri.getRawPath() == null || uri.getRawPath().isEmpty()
                ? "/" : uri.getRawPath();
        String canonicalQuery = canonicalQuery(uri.getRawQuery());
        String canonicalRequest = method + '\n' + canonicalPath + '\n' + canonicalQuery + '\n'
                + canonicalHeaders + '\n' + signedHeaders + '\n' + payloadHash;

        String scope = dateStamp + '/' + region + '/' + service + "/aws4_request";
        String stringToSign = "AWS4-HMAC-SHA256\n" + amzDate + '\n' + scope + '\n'
                + sha256Hex(canonicalRequest.getBytes(StandardCharsets.UTF_8));

        byte[] kDate = hmac(("AWS4" + secretKey).getBytes(StandardCharsets.UTF_8), dateStamp);
        byte[] kRegion = hmac(kDate, region);
        byte[] kService = hmac(kRegion, service);
        byte[] kSigning = hmac(kService, "aws4_request");
        String signature = hex(hmac(kSigning, stringToSign));

        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("x-amz-date", amzDate);
        if (sessionToken != null && !sessionToken.isBlank()) {
            headers.put("x-amz-security-token", sessionToken);
        }
        headers.put("authorization", "AWS4-HMAC-SHA256 Credential=" + accessKey + '/' + scope
                + ", SignedHeaders=" + signedHeaders + ", Signature=" + signature);
        return headers;
    }

    /** RFC 3986 encoding of one path segment (':' in ARNs becomes %3A). */
    public static String encodeSegment(String segment) {
        StringBuilder out = new StringBuilder();
        for (byte b : segment.getBytes(StandardCharsets.UTF_8)) {
            char c = (char) (b & 0xFF);
            boolean unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
            if (unreserved) {
                out.append(c);
            } else {
                out.append('%').append(String.format("%02X", b & 0xFF));
            }
        }
        return out.toString();
    }

    /** Query params sorted by name; caller pre-encodes values. */
    private static String canonicalQuery(String rawQuery) {
        if (rawQuery == null || rawQuery.isEmpty()) {
            return "";
        }
        TreeMap<String, String> params = new TreeMap<>();
        for (String pair : rawQuery.split("&")) {
            int eq = pair.indexOf('=');
            params.put(eq < 0 ? pair : pair.substring(0, eq),
                    eq < 0 ? "" : pair.substring(eq + 1));
        }
        StringBuilder out = new StringBuilder();
        params.forEach((k, v) -> {
            if (out.length() > 0) {
                out.append('&');
            }
            out.append(k).append('=').append(v);
        });
        return out.toString();
    }

    private static int defaultPort(URI uri) {
        return "https".equalsIgnoreCase(uri.getScheme()) ? 443 : 80;
    }

    private static byte[] hmac(byte[] key, String data) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(data.getBytes(StandardCharsets.UTF_8));
        } catch (Exception ex) {
            throw new IllegalStateException("HmacSHA256 unavailable", ex);
        }
    }

    private static String sha256Hex(byte[] data) {
        try {
            return hex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (Exception ex) {
            throw new IllegalStateException("SHA-256 unavailable", ex);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xF, 16))
                    .append(Character.forDigit(b & 0xF, 16));
        }
        return out.toString();
    }
}
