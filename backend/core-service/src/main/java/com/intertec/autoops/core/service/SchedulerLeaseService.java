package com.intertec.autoops.core.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.net.InetAddress;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

/**
 * DB-lease leader election for the cron scheduler. Exactly one instance holds
 * the lease at a time: the holder renews it on every poll; a rival can only
 * take it after it expires (a crashed leader is replaced within the TTL).
 * Claiming is a plain atomic UPDATE — portable across MySQL and the H2 test
 * database, no advisory locks.
 */
@Service
public class SchedulerLeaseService {

    private static final Logger log = LoggerFactory.getLogger(SchedulerLeaseService.class);

    /** Lease outlives two missed polls before a rival may steal it. */
    public static final Duration LEASE_TTL = Duration.ofSeconds(90);

    private final JdbcTemplate jdbcTemplate;
    private final String instanceId;

    private volatile boolean leader;

    public SchedulerLeaseService(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
        this.instanceId = hostName() + "-" + UUID.randomUUID().toString().substring(0, 8);
    }

    /** True iff this instance now holds (or just renewed) the named lease. */
    public boolean tryAcquire(String name) {
        Instant now = Instant.now();
        Timestamp expiresAt = Timestamp.from(now.plus(LEASE_TTL));
        try {
            int renewed = jdbcTemplate.update(
                    "UPDATE scheduler_lease SET holder = ?, expires_at = ? "
                            + "WHERE name = ? AND (holder = ? OR expires_at < ?)",
                    instanceId, expiresAt, name, instanceId, Timestamp.from(now));
            if (renewed == 1) {
                markLeader(name, true);
                return true;
            }
            Integer rows = jdbcTemplate.queryForObject(
                    "SELECT COUNT(*) FROM scheduler_lease WHERE name = ?", Integer.class, name);
            if (rows != null && rows == 0) {
                try {
                    jdbcTemplate.update(
                            "INSERT INTO scheduler_lease (name, holder, expires_at) VALUES (?, ?, ?)",
                            name, instanceId, expiresAt);
                    markLeader(name, true);
                    return true;
                } catch (DataAccessException raced) {
                    // Another instance inserted first — it leads this cycle.
                }
            }
            markLeader(name, false);
            return false;
        } catch (DataAccessException ex) {
            // DB trouble: better to skip a poll than to double-fire.
            log.warn("Scheduler lease check failed ({}): {}", name, ex.getMessage());
            markLeader(name, false);
            return false;
        }
    }

    public String instanceId() {
        return instanceId;
    }

    private void markLeader(String name, boolean isLeader) {
        if (isLeader != leader) {
            log.info("Instance {} {} the '{}' scheduler lease", instanceId,
                    isLeader ? "acquired" : "lost", name);
        }
        leader = isLeader;
    }

    private static String hostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (Exception ex) {
            return "core";
        }
    }
}
