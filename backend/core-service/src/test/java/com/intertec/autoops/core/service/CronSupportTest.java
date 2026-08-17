package com.intertec.autoops.core.service;

import com.intertec.autoops.core.exception.CoreException;
import org.junit.jupiter.api.Test;
import org.springframework.scheduling.support.CronExpression;

import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Zone-aware cron semantics. The invariant under test: a cron is a LOCAL-TIME
 * rule in the job's own zone, and the instant it resolves to shifts across DST.
 */
class CronSupportTest {

    private static final String DAILY_2AM = "0 2 * * *";

    /** Fires the cron as if "now" were the given local moment in that zone. */
    private static ZonedDateTime nextFrom(String cron, String zone, String localNow) {
        return CronSupport.parse(cron).next(ZonedDateTime.of(
                java.time.LocalDateTime.parse(localNow), ZoneId.of(zone)));
    }

    // ---------- the core promise ----------

    @Test
    void sameCronInDifferentZonesResolvesToDifferentInstants() {
        Instant chicago = nextFrom(DAILY_2AM, "America/Chicago", "2026-01-15T00:00:00").toInstant();
        Instant kolkata = nextFrom(DAILY_2AM, "Asia/Kolkata", "2026-01-15T00:00:00").toInstant();

        assertThat(chicago).isNotEqualTo(kolkata);
        // 2 AM CST is 08:00Z; 2 AM IST is 20:30Z the previous day.
        assertThat(chicago).isEqualTo(Instant.parse("2026-01-15T08:00:00Z"));
        assertThat(kolkata).isEqualTo(Instant.parse("2026-01-14T20:30:00Z"));
    }

    @Test
    void nextIsAbsoluteAndStrictlyInTheFuture() {
        Instant next = CronSupport.next(DAILY_2AM, "America/Chicago");
        assertThat(next).isAfter(Instant.now());
    }

    @Test
    void blankTimezoneMeansUtc() {
        assertThat(CronSupport.zone(null).getId()).isEqualTo("UTC");
        assertThat(CronSupport.zone("  ").getId()).isEqualTo("UTC");
    }

    // ---------- DST: the whole reason IANA IDs are required ----------

    @Test
    void chicagoHoldsLocalTwoAmAcrossTheDstBoundary() {
        // Winter (CST, UTC-6) and summer (CDT, UTC-5) are an hour apart in UTC,
        // but both are 2 AM to the customer. That is the point.
        Instant winter = nextFrom(DAILY_2AM, "America/Chicago", "2026-01-15T00:00:00").toInstant();
        Instant summer = nextFrom(DAILY_2AM, "America/Chicago", "2026-07-15T00:00:00").toInstant();

        assertThat(winter).isEqualTo(Instant.parse("2026-01-15T08:00:00Z"));
        assertThat(summer).isEqualTo(Instant.parse("2026-07-15T07:00:00Z"));
    }

    @Test
    void denverShiftsForDstButPhoenixNeverDoes() {
        // Both are "MST" in casual speech, and they diverge for most of the year.
        Instant denver = nextFrom(DAILY_2AM, "America/Denver", "2026-07-15T00:00:00").toInstant();
        Instant phoenix = nextFrom(DAILY_2AM, "America/Phoenix", "2026-07-15T00:00:00").toInstant();

        assertThat(denver).isEqualTo(Instant.parse("2026-07-15T08:00:00Z"));
        assertThat(phoenix).isEqualTo(Instant.parse("2026-07-15T09:00:00Z"));
        assertThat(denver).isNotEqualTo(phoenix);
    }

    /**
     * KNOWN BEHAVIOUR, not a preference: on the spring-forward day the local
     * time 02:30 does not exist in America/Chicago (02:00 jumps to 03:00), and
     * the run is SKIPPED — the job's next fire is the following day. A daily
     * 02:30 job therefore loses exactly one run per year.
     */
    @Test
    void springForwardSkipsTheRunEntirely() {
        ZonedDateTime fire = nextFrom("30 2 * * *", "America/Chicago", "2026-03-08T00:00:00");

        assertThat(fire.toLocalDate()).isEqualTo(java.time.LocalDate.parse("2026-03-09"));
        assertThat(fire.toInstant()).isEqualTo(Instant.parse("2026-03-09T07:30:00Z"));
    }

    /**
     * KNOWN BEHAVIOUR: on the fall-back day 01:30 happens twice in
     * America/Chicago (once at -05:00, once at -06:00) and the job fires on
     * BOTH — two runs, one hour apart, on the same local date. Harmless for an
     * idempotent job, a duplicate for anything with side effects.
     */
    @Test
    void fallBackFiresTwiceOnTheDuplicatedLocalHour() {
        ZonedDateTime first = nextFrom("30 1 * * *", "America/Chicago", "2026-11-01T00:00:00");
        ZonedDateTime second = CronSupport.parse("30 1 * * *").next(first);

        assertThat(first.toInstant()).isEqualTo(Instant.parse("2026-11-01T06:30:00Z"));
        assertThat(second.toInstant()).isEqualTo(Instant.parse("2026-11-01T07:30:00Z"));
        assertThat(first.toLocalDate()).isEqualTo(second.toLocalDate());
        assertThat(java.time.Duration.between(first, second)).isEqualTo(java.time.Duration.ofHours(1));
    }

    // ---------- zone validation ----------

    @Test
    void acceptsIanaRegionIdsAndUtc() {
        assertThat(CronSupport.zone("America/Chicago").getId()).isEqualTo("America/Chicago");
        assertThat(CronSupport.zone("Asia/Kolkata").getId()).isEqualTo("Asia/Kolkata");
        assertThat(CronSupport.zone(" America/Denver ").getId()).isEqualTo("America/Denver");
        assertThat(CronSupport.zone("UTC").getId()).isEqualTo("UTC");
    }

    @Test
    void rejectsAbbreviationsBecauseTheyAreAmbiguous() {
        for (String bad : new String[]{"CST", "MST", "EST", "IST", "PST"}) {
            assertThatThrownBy(() -> CronSupport.zone(bad))
                    .isInstanceOf(CoreException.class)
                    .hasMessageContaining("IANA");
        }
    }

    @Test
    void rejectsFixedOffsetsBecauseTheyCarryNoDstRules() {
        for (String bad : new String[]{"-06:00", "+05:30", "GMT+2"}) {
            assertThatThrownBy(() -> CronSupport.zone(bad))
                    .isInstanceOf(CoreException.class);
        }
    }

    @Test
    void rejectsUnknownRegionIds() {
        assertThatThrownBy(() -> CronSupport.zone("America/Atlantis"))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("Not a known IANA time zone");
    }

    /**
     * Pins the rationale for rejecting abbreviations outright. ZoneId.of()
     * already refuses them, but the "helpful" fix someone will eventually
     * reach for — ZoneId.SHORT_IDS — resolves MST to a FIXED -07:00, i.e. it
     * hands a user who meant Denver the never-shifting Phoenix behaviour, and
     * guesses CST as America/Chicago over America/Mexico_City. Our guard keeps
     * that door shut.
     */
    @Test
    void shortIdsWouldSilentlyGiveTheWrongZoneWhichIsWhyWeRejectAbbreviations() {
        assertThatThrownBy(() -> ZoneId.of("MST"))
                .isInstanceOf(java.time.zone.ZoneRulesException.class);

        assertThat(ZoneId.SHORT_IDS.get("MST")).isEqualTo("-07:00");           // fixed, no DST
        assertThat(ZoneId.SHORT_IDS.get("CST")).isEqualTo("America/Chicago");  // a guess

        // Denver moves between winter and summer; Phoenix does not. (Phoenix is
        // NOT isFixedOffset() — Arizona did observe DST in 1967 — so compare the
        // offsets that actually apply rather than the zone's fixed-ness.)
        Instant jan = Instant.parse("2026-01-15T12:00:00Z");
        Instant jul = Instant.parse("2026-07-15T12:00:00Z");
        assertThat(ZoneId.of("America/Denver").getRules().getOffset(jan))
                .isNotEqualTo(ZoneId.of("America/Denver").getRules().getOffset(jul));
        assertThat(ZoneId.of("America/Phoenix").getRules().getOffset(jan))
                .isEqualTo(ZoneId.of("America/Phoenix").getRules().getOffset(jul));
    }

    // ---------- cron parsing (unchanged behaviour) ----------

    @Test
    void acceptsFiveAndSixFieldExpressions() {
        assertThat(CronSupport.parse("0 2 * * *")).isInstanceOf(CronExpression.class);
        assertThat(CronSupport.parse("0 0 2 * * *")).isInstanceOf(CronExpression.class);
    }

    @Test
    void rejectsGarbageCron() {
        assertThatThrownBy(() -> CronSupport.next("not a cron", "UTC"))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("Not a valid cron expression");
    }
}
