package com.intertec.autoops.core.web.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * definition is the steps JSON ({@code {"steps":[{type,label,category}]}});
 * its step count is parsed server-side.
 *
 * <p>scheduleTimezone is the IANA zone the cron is read in (e.g.
 * {@code America/Chicago}); omitting it on create means UTC, and omitting it
 * on update leaves the job's current zone untouched.
 */
public record JobRequest(
        @NotBlank @Size(max = 128) String name,
        @Size(max = 64) String group,
        @Size(max = 255) String description,
        String definition,
        @Size(max = 64) String schedule,
        @Size(max = 64) String scheduleTimezone,
        Boolean requiresApproval) {
}
