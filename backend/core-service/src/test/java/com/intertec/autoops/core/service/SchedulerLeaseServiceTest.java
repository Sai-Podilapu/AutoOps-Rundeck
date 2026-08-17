package com.intertec.autoops.core.service;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Lease semantics against H2. The table is Flyway-managed (no JPA entity),
 * so the test creates it by hand.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class SchedulerLeaseServiceTest {

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @BeforeEach
    void createTable() {
        jdbcTemplate.execute("CREATE TABLE IF NOT EXISTS scheduler_lease ("
                + "name VARCHAR(32) NOT NULL, holder VARCHAR(128) NOT NULL, "
                + "expires_at TIMESTAMP(6) NOT NULL, PRIMARY KEY (name))");
        jdbcTemplate.update("DELETE FROM scheduler_lease");
    }

    @Test
    void firstClaimerBecomesLeaderAndRenews() {
        SchedulerLeaseService a = new SchedulerLeaseService(jdbcTemplate);
        assertTrue(a.tryAcquire("job-scheduler"));
        assertTrue(a.tryAcquire("job-scheduler"), "holder must renew its own lease");
    }

    @Test
    void rivalCannotStealALiveLease() {
        SchedulerLeaseService a = new SchedulerLeaseService(jdbcTemplate);
        SchedulerLeaseService b = new SchedulerLeaseService(jdbcTemplate);
        assertTrue(a.tryAcquire("job-scheduler"));
        assertFalse(b.tryAcquire("job-scheduler"), "live lease must not change hands");
        assertTrue(a.tryAcquire("job-scheduler"), "the holder keeps leading");
    }

    @Test
    void rivalTakesOverAfterExpiry() {
        SchedulerLeaseService a = new SchedulerLeaseService(jdbcTemplate);
        SchedulerLeaseService b = new SchedulerLeaseService(jdbcTemplate);
        assertTrue(a.tryAcquire("job-scheduler"));
        // Simulate a crashed leader: expire its lease directly.
        jdbcTemplate.update("UPDATE scheduler_lease SET expires_at = ? WHERE name = ?",
                Timestamp.from(Instant.now().minusSeconds(5)), "job-scheduler");
        assertTrue(b.tryAcquire("job-scheduler"), "expired lease is up for grabs");
        assertFalse(a.tryAcquire("job-scheduler"), "the old leader lost it");
    }

    @Test
    void leasesAreIndependentPerName() {
        SchedulerLeaseService a = new SchedulerLeaseService(jdbcTemplate);
        SchedulerLeaseService b = new SchedulerLeaseService(jdbcTemplate);
        assertTrue(a.tryAcquire("job-scheduler"));
        assertTrue(b.tryAcquire("other-scheduler"));
    }
}
