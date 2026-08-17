package com.intertec.autoops.core.service;

import com.intertec.autoops.core.exception.CoreException;
import org.springframework.scheduling.support.CronExpression;

import java.time.DateTimeException;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;

/**
 * Cron handling for job schedules. Accepts both 5-field unix crons (what the
 * UI produces, e.g. {@code 0 2 * * *}) and 6-field Spring crons — a 5-field
 * expression is normalized by prepending seconds.
 *
 * <p>A schedule is a LOCAL-TIME rule evaluated in the job's own zone:
 * {@code 0 2 * * *} in {@code America/Chicago} means 2 AM Chicago time all
 * year round, so the absolute instant it fires at moves by an hour across a
 * DST transition. The computed fire time is always returned as an absolute
 * {@link Instant}, which is what {@code jobs.next_run_at} stores.
 */
final class CronSupport {

    /** Zone assumed when a job carries none — preserves pre-timezone behaviour. */
    static final String DEFAULT_TIMEZONE = "UTC";

    private CronSupport() {
    }

    /** @throws CoreException {@code invalid_schedule} (400) when unparseable. */
    static CronExpression parse(String schedule) {
        try {
            return CronExpression.parse(normalize(schedule));
        } catch (IllegalArgumentException ex) {
            throw CoreException.badRequest("invalid_schedule",
                    "Not a valid cron expression: " + schedule);
        }
    }

    /**
     * Resolves an IANA zone ID such as {@code America/Chicago} or {@code UTC}.
     *
     * <p>Only {@code Region/City} IDs (and bare {@code UTC}) are accepted.
     * Abbreviations and fixed offsets are rejected on purpose:
     * <ul>
     *   <li>{@code -06:00} has no DST rules, so it silently drifts an hour at
     *       the next transition;</li>
     *   <li>abbreviations are ambiguous. {@link ZoneId#of(String)} already
     *       rejects them, but {@link ZoneId#SHORT_IDS} — which a future
     *       "be helpful and accept CST" change would reach for — resolves
     *       {@code MST} to a FIXED {@code -07:00}, silently giving a user who
     *       meant Denver the never-shifting Phoenix behaviour, and resolves
     *       {@code CST} to America/Chicago, quietly guessing against
     *       America/Mexico_City. This guard exists so that shortcut stays shut.</li>
     * </ul>
     *
     * @throws CoreException {@code invalid_timezone} (400) when unknown or ambiguous.
     */
    static ZoneId zone(String timezone) {
        if (timezone == null || timezone.isBlank()) {
            return ZoneId.of(DEFAULT_TIMEZONE);
        }
        String trimmed = timezone.trim();
        if (!DEFAULT_TIMEZONE.equals(trimmed) && trimmed.indexOf('/') < 0) {
            throw CoreException.badRequest("invalid_timezone",
                    "Use a full IANA zone ID like 'America/Chicago' or 'UTC', not '"
                            + trimmed + "' — abbreviations and fixed offsets carry no DST rules");
        }
        try {
            return ZoneId.of(trimmed);
        } catch (DateTimeException ex) {
            throw CoreException.badRequest("invalid_timezone",
                    "Not a known IANA time zone: " + trimmed);
        }
    }

    /**
     * Next fire time strictly after now, evaluated in {@code timezone}, or null
     * for a cron that never fires again. Validates both arguments.
     */
    static Instant next(String schedule, String timezone) {
        ZonedDateTime next = parse(schedule).next(ZonedDateTime.now(zone(timezone)));
        return next != null ? next.toInstant() : null;
    }

    private static String normalize(String schedule) {
        String trimmed = schedule == null ? "" : schedule.trim();
        return trimmed.split("\\s+").length == 5 ? "0 " + trimmed : trimmed;
    }
}
