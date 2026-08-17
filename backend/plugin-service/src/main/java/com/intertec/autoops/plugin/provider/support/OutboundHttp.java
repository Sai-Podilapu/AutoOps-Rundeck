package com.intertec.autoops.plugin.provider.support;

import com.intertec.autoops.plugin.spi.DeliveryResult;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.UnknownHostException;
import java.time.Duration;
import java.util.function.Consumer;

/**
 * The one outbound HTTP path every webhook-style plugin shares: bounded
 * timeouts, no redirect following, and a uniform mapping from what came back
 * to a {@link DeliveryResult}.
 *
 * <p>Centralised so the retryable/permanent decision is made once. A plugin
 * that classified its own status codes would drift from its siblings, and the
 * consequence of drifting is either lost alerts or a rate-limit ban.
 *
 * <p>Built as a bean by {@code DeliveryConfig} so the timeouts come from
 * {@code autoops.plugin.delivery.*} rather than being hard-coded here.
 */
public class OutboundHttp {

    private final RestClient client;

    public OutboundHttp(Duration connectTimeout, Duration readTimeout) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) connectTimeout.toMillis());
        factory.setReadTimeout((int) readTimeout.toMillis());
        this.client = RestClient.builder()
                .requestFactory(factory)
                // 4xx/5xx must reach us as a response, not an exception, so the
                // status code lands in the delivery_attempts row.
                .defaultStatusHandler(status -> true, (request, response) -> { })
                .build();
    }

    public DeliveryResult postJson(String url, Object body) {
        return postJson(url, body, headers -> { });
    }

    public DeliveryResult postJson(String url, Object body, Consumer<org.springframework.http.HttpHeaders> headers) {
        URI target = target(url);
        if (target == null) {
            return DeliveryResult.failure("Not a usable URL: " + url);
        }
        return exchange(() -> client.post()
                .uri(target)
                .contentType(MediaType.APPLICATION_JSON)
                .headers(headers)
                .body(body)
                .retrieve()
                .toEntity(String.class));
    }

    public DeliveryResult get(String url, Consumer<org.springframework.http.HttpHeaders> headers) {
        URI target = target(url);
        if (target == null) {
            return DeliveryResult.failure("Not a usable URL: " + url);
        }
        return exchange(() -> client.get()
                .uri(target)
                .headers(headers)
                .retrieve()
                .toEntity(String.class));
    }

    /**
     * Parse to a {@link URI} rather than handing the RestClient the raw string.
     *
     * <p>Load-bearing: {@code uri(String)} treats its argument as a URI
     * <em>template</em> and re-encodes it, so a Teams webhook whose SAS
     * signature already contains {@code %2F}/{@code %2B} goes out with every
     * {@code %} doubled to {@code %25} — the signature no longer verifies and
     * Logic Apps answers 401. The {@code uri(URI)} overload is passed through
     * untouched. It also stops a literal <code>{</code> in a tenant's webhook
     * URL being read as a placeholder.
     *
     * <p>Provider-issued webhook URLs are already correctly encoded, so
     * anything that fails to parse here is a typo the tenant must fix — a
     * permanent failure, not something to retry.
     */
    private static URI target(String url) {
        if (url == null || url.isBlank()) {
            return null;
        }
        try {
            return new URI(url.trim());
        } catch (URISyntaxException ex) {
            return null;
        }
    }

    private DeliveryResult exchange(Call call) {
        try {
            var response = call.execute();
            int status = response.getStatusCode().value();
            String body = response.getBody();
            if (response.getStatusCode().is2xxSuccessful()) {
                return DeliveryResult.success(status, body);
            }
            // 408/429 and every 5xx are worth another attempt; the rest are
            // the tenant's configuration to fix, not ours to retry.
            boolean retryable = status == 408 || status == 429 || status >= 500;
            // Note: on a 401 the body is normally absent whatever the provider
            // sent — HttpURLConnection consumes the error stream when it finds
            // no WWW-Authenticate header to act on. Other statuses carry theirs.
            String detail = body == null || body.isBlank()
                    ? "HTTP " + status
                    : "HTTP " + status + ": " + body;
            return retryable
                    ? DeliveryResult.retryable(status, detail)
                    : DeliveryResult.failure(status, detail);
        } catch (Exception ex) {
            Throwable root = rootCause(ex);
            if (root instanceof UnknownHostException) {
                // DNS does not resolve — a typo'd host, not a blip.
                return DeliveryResult.failure("Cannot resolve host: " + root.getMessage());
            }
            if (root instanceof SocketTimeoutException) {
                return DeliveryResult.retryable("Timed out talking to the service");
            }
            return DeliveryResult.retryable(root.getClass().getSimpleName()
                    + ": " + root.getMessage());
        }
    }

    private static Throwable rootCause(Throwable ex) {
        Throwable current = ex;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        return current;
    }

    @FunctionalInterface
    private interface Call {
        org.springframework.http.ResponseEntity<String> execute();
    }
}
