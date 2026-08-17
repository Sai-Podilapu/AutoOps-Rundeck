package com.intertec.autoops.auth.web.dto;

import java.util.Map;

public record AuthorizeResponse(
        boolean allowed,
        String reason,
        Map<String, Object> claims) {
}
