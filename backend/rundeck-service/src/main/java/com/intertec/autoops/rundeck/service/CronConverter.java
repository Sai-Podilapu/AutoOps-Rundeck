package com.intertec.autoops.rundeck.service;

import com.intertec.autoops.rundeck.exception.RundeckException;

import java.util.Locale;

/**
 * Translates an AutoOps schedule (standard 5-field Unix cron) into the Quartz
 * 6-field crontab Rundeck's scheduler reads.
 *
 * <p>These two formats look alike and are not, which is the whole reason this
 * class exists rather than a string concatenation at the call site. A job that
 * runs at the wrong hour is worse than one that fails to import, so every
 * difference below is handled explicitly and anything unrecognised is REFUSED:
 *
 * <ul>
 *   <li><b>A seconds field.</b> Unix starts at minutes; Quartz starts at
 *       seconds. A 5-field string handed to Quartz silently shifts every field
 *       one place left — {@code 30 23 * * 1-5} would become "second 30, minute
 *       23, hour *", i.e. hourly instead of nightly.
 *   <li><b>Day-of-week numbering is off by one.</b> Unix is 0-6 with Sunday=0
 *       (and 7 also Sunday); Quartz is 1-7 with Sunday=1. Copying {@code 1-5}
 *       across unchanged moves a Mon-Fri job to Sun-Thu — it still runs, on the
 *       wrong days, which is exactly the kind of bug nobody notices until a
 *       weekend batch fires.
 *   <li><b>{@code ?} is mandatory.</b> Quartz rejects a crontab where both
 *       day-of-month and day-of-week are specified; exactly one must be
 *       {@code ?}. Unix has no such rule.
 * </ul>
 *
 * <p><b>Names are preferred to numbers for day-of-week</b> where the whole
 * field is expressible that way, because {@code MON-FRI} means the same thing
 * in both formats and needs no arithmetic — the shifted-number path is where
 * this is easiest to get wrong, so it is used only when it must be.
 */
public final class CronConverter {

    /** Unix day-of-week 0..7 to the Quartz name for that day. 0 and 7 are both Sunday. */
    private static final String[] DOW_NAMES =
            {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"};

    private CronConverter() {
    }

    /**
     * @param unixCron a 5-field cron: {@code minute hour day-of-month month day-of-week}
     * @return a 6-field Quartz crontab suitable for a Rundeck job's
     *         {@code schedule.crontab}
     * @throws RundeckException if the expression is not a 5-field cron, or uses
     *         a shape Quartz cannot represent
     */
    public static String toQuartz(String unixCron) {
        if (unixCron == null || unixCron.isBlank()) {
            throw RundeckException.badRequest("schedule_missing",
                    "A scheduled job needs a cron expression");
        }
        String[] f = unixCron.trim().split("\s+");
        if (f.length != 5) {
            // Refused rather than guessed. A 6-field string here is most likely
            // ALREADY Quartz — passing it through would double-shift it, and
            // rejecting says so while accepting would not.
            throw RundeckException.badRequest("schedule_invalid",
                    "Expected a 5-field cron (minute hour day-of-month month day-of-week), got "
                            + f.length + " fields: " + unixCron);
        }
        String minute = f[0];
        String hour = f[1];
        String dom = f[2];
        String month = f[3];
        String dow = f[4];

        boolean domWild = isWildcard(dom);
        boolean dowWild = isWildcard(dow);

        if (!domWild && !dowWild) {
            // Unix ORs the two ("the 1st, and every Monday"); Quartz has no way
            // to say that. Approximating would mean silently dropping half the
            // schedule, so this is a refusal with the reason spelled out.
            throw RundeckException.badRequest("schedule_unsupported",
                    "This schedule sets BOTH a day-of-month (" + dom + ") and a day-of-week ("
                            + dow + "). The execution engine cannot express \"either day\" — "
                            + "use one or the other.");
        }

        // Exactly one must be '?'. When neither is constrained, day-of-week
        // yields, matching how "every day" is normally written for Quartz.
        String quartzDom = domWild ? (dowWild ? "*" : "?") : dom;
        String quartzDow = dowWild ? "?" : shiftDayOfWeek(dow);

        return "0 " + minute + " " + hour + " " + quartzDom + " " + month + " " + quartzDow;
    }

    /** True for the fields Quartz treats as "unconstrained". */
    private static boolean isWildcard(String field) {
        return "*".equals(field) || "?".equals(field);
    }

    /**
     * Renumbers a Unix day-of-week field for Quartz, token by token.
     *
     * <p>Steps are split off first: in {@code 1-5/2} only the {@code 1-5} is a
     * day, and shifting the {@code 2} would change "every other day" into
     * "every third".
     */
    private static String shiftDayOfWeek(String field) {
        StringBuilder out = new StringBuilder();
        for (String part : field.split(",", -1)) {
            if (out.length() > 0) {
                out.append(',');
            }
            String step = null;
            int slash = part.indexOf('/');
            if (slash >= 0) {
                step = part.substring(slash + 1);
                part = part.substring(0, slash);
            }
            out.append(shiftRange(part));
            if (step != null) {
                out.append('/').append(step);
            }
        }
        return out.toString();
    }

    private static String shiftRange(String part) {
        int dash = part.indexOf('-');
        if (dash > 0) {
            return shiftDay(part.substring(0, dash)) + "-" + shiftDay(part.substring(dash + 1));
        }
        return shiftDay(part);
    }

    /**
     * One day token. Numbers become NAMES rather than shifted numbers: a name
     * carries no numbering convention, so it cannot be misread later by anyone
     * comparing the AutoOps cron with the Rundeck one.
     */
    private static String shiftDay(String token) {
        String t = token.trim().toUpperCase(Locale.ROOT);
        if (t.isEmpty() || "*".equals(t)) {
            return t;
        }
        if (!t.chars().allMatch(Character::isDigit)) {
            // Already a name (MON, FRI, ...). Both formats spell these the same.
            return t;
        }
        int day = Integer.parseInt(t);
        if (day < 0 || day > 7) {
            throw RundeckException.badRequest("schedule_invalid",
                    "Day-of-week must be 0-7 (0 and 7 are both Sunday), got " + token);
        }
        return DOW_NAMES[day];
    }
}
