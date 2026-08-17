package com.intertec.autoops.subscription.web.dto;

import jakarta.validation.constraints.NotBlank;

/** planCode: STARTER | TEAM | BUSINESS | ENTERPRISE (case-insensitive). */
public record SubscribeRequest(@NotBlank String planCode) {
}
