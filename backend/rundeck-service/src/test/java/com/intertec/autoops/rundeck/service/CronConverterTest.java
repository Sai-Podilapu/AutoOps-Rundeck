package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.exception.RundeckException;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CronConverterTest {

    /**
     * Every schedule actually in the jobs table, because these are the ones that
     * will fire in production. A regression here moves a real batch window.
     */
    @ParameterizedTest(name = "{0} -> {1}")
    @CsvSource({
            "'30 23 * * 1-5',  '0 30 23 ? * MON-FRI'",   // EOD batch close, weeknights
            "'0 */2 * * *',    '0 0 */2 * * ?'",         // SWIFT ingestion, every 2h
            "'15 * * * *',     '0 15 * * * ?'",          // NEFT/RTGS, hourly at :15
            "'45 2 * * *',     '0 45 2 * * ?'",          // card settlement
            "'*/15 * * * *',   '0 */15 * * * ?'",        // AML screening
            "'0 5 * * *',      '0 0 5 * * ?'",           // KYC sweep
            "'0 2 1 * *',      '0 0 2 1 * ?'",           // regulatory return, 1st of month
            "'0 */6 * * *',    '0 0 */6 * * ?'",         // DR replication
            "'0 6 * * 0',      '0 0 6 ? * SUN'",         // dormant accounts, Sundays
            "'0 16 * * 1-5',   '0 0 16 ? * MON-FRI'",    // nostro sweep
    })
    void convertsEveryScheduleCurrentlyInUse(String unix, String quartz) {
        assertEquals(quartz, CronConverter.toQuartz(unix));
    }

    @Test
    @DisplayName("a seconds field is prepended, never borrowed from minutes")
    void prependsSeconds() {
        // The failure this guards: handing Quartz the 5-field string directly
        // reads 30 as seconds and 23 as minutes, turning a nightly job hourly.
        assertTrue(CronConverter.toQuartz("30 23 * * 1-5").startsWith("0 30 23 "));
    }

    @Test
    @DisplayName("Sunday is 0 OR 7 in Unix and both mean SUN")
    void bothUnixSundaysMapToSun() {
        assertEquals("0 0 6 ? * SUN", CronConverter.toQuartz("0 6 * * 0"));
        assertEquals("0 0 6 ? * SUN", CronConverter.toQuartz("0 6 * * 7"));
    }

    @Test
    @DisplayName("day-of-week numbers become names, so the off-by-one cannot resurface")
    void numericDaysBecomeNames() {
        // Unix 1 = Monday. Emitting a bare "1" would mean SUNDAY to Quartz.
        assertEquals("0 0 9 ? * MON", CronConverter.toQuartz("0 9 * * 1"));
        assertEquals("0 0 9 ? * SAT", CronConverter.toQuartz("0 9 * * 6"));
    }

    @Test
    void namedDaysPassThroughUnchanged() {
        assertEquals("0 0 9 ? * MON-FRI", CronConverter.toQuartz("0 9 * * MON-FRI"));
    }

    @Test
    @DisplayName("a step divisor is not a day and must not be shifted")
    void stepDivisorSurvivesUnshifted() {
        // 1-5/2 is "every other weekday". Shifting the 2 would make it every third.
        assertEquals("0 0 9 ? * MON-FRI/2", CronConverter.toQuartz("0 9 * * 1-5/2"));
    }

    @Test
    void commaSeparatedDaysEachShift() {
        assertEquals("0 0 9 ? * MON,WED,FRI", CronConverter.toQuartz("0 9 * * 1,3,5"));
    }

    @Test
    @DisplayName("exactly one of day-of-month / day-of-week is '?'")
    void exactlyOneDayFieldIsQuestionMark() {
        // day-of-month constrained -> day-of-week yields
        assertEquals("0 0 2 1 * ?", CronConverter.toQuartz("0 2 1 * *"));
        // day-of-week constrained -> day-of-month yields
        assertEquals("0 0 6 ? * SUN", CronConverter.toQuartz("0 6 * * 0"));
        // neither constrained -> day-of-week yields, day-of-month stays '*'
        assertEquals("0 0 4 * * ?", CronConverter.toQuartz("0 4 * * *"));
    }

    @Test
    @DisplayName("both day fields set is refused, not silently halved")
    void refusesBothDayFields() {
        // Unix means "the 1st OR any Monday". Quartz cannot say that, and
        // picking one would drop half the schedule without telling anyone.
        RundeckException ex = assertThrows(RundeckException.class,
                () -> CronConverter.toQuartz("0 2 1 * 1"));
        assertEquals("schedule_unsupported", ex.getError());
    }

    @Test
    @DisplayName("a 6-field expression is refused rather than double-shifted")
    void refusesWrongFieldCount() {
        // Most likely already Quartz. Passing it through would shift it again.
        assertThrows(RundeckException.class, () -> CronConverter.toQuartz("0 30 23 ? * MON-FRI"));
        assertThrows(RundeckException.class, () -> CronConverter.toQuartz("30 23 * *"));
    }

    @Test
    void refusesBlankAndOutOfRange() {
        assertThrows(RundeckException.class, () -> CronConverter.toQuartz(null));
        assertThrows(RundeckException.class, () -> CronConverter.toQuartz("   "));
        assertThrows(RundeckException.class, () -> CronConverter.toQuartz("0 9 * * 8"));
    }
}
