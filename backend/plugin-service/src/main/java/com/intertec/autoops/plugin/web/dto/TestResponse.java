package com.intertec.autoops.plugin.web.dto;

import com.intertec.autoops.plugin.spi.DeliveryResult;

/**
 * The outcome of a connection test. Always HTTP 200 — a failed test is a
 * successful answer to "does this work?", and returning 4xx would make the
 * console treat a diagnosis as a request error.
 */
public record TestResponse(boolean ok, Integer statusCode, String detail, boolean retryable) {

    public static TestResponse from(DeliveryResult result) {
        return new TestResponse(result.ok(), result.statusCode(),
                result.detailForStorage(), result.retryable());
    }
}
