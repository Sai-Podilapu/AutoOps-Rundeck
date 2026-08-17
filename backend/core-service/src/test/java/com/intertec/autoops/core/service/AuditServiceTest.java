package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.repo.CoreAuditLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Audit rows against H2 with real commit semantics. */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import(AuditService.class)
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class AuditServiceTest {

    private static final String TENANT = "acme-corp-cafe0123";

    @Autowired
    private AuditService auditService;
    @Autowired
    private CoreAuditLogRepository repository;

    @BeforeEach
    void reset() {
        repository.deleteAll();
    }

    @Test
    void recordWritesAnAttributedRow() {
        auditService.record(CoreAuditEventType.PROJECT_CREATED, TENANT, "admin@acme.io",
                7L, "PROJECT", 7L, "Alpha", null);

        var rows = repository
                .findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        TENANT, Instant.EPOCH);
        assertEquals(1, rows.size());
        var row = rows.get(0);
        assertEquals(CoreAuditEventType.PROJECT_CREATED, row.getEventType());
        assertEquals("admin@acme.io", row.getActor());
        assertEquals("7", row.getTargetId());
        assertEquals("Alpha", row.getTargetName());
        assertNotNull(row.getCreatedAt());
    }

    @Test
    void oversizedDetailIsTruncatedNotFatal() {
        auditService.record(CoreAuditEventType.SCM_EXPORTED, TENANT, "admin@acme.io",
                null, "SCM", null, null, "x".repeat(5000));

        var rows = repository
                .findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        TENANT, Instant.EPOCH);
        assertEquals(1, rows.size());
        assertEquals(1024, rows.get(0).getDetail().length());
    }

    @Test
    void eventsAreTenantIsolatedAndProjectFilterable() {
        auditService.record(CoreAuditEventType.JOB_CREATED, TENANT, "a@x.io",
                1L, "JOB", 10L, "Deploy", null);
        auditService.record(CoreAuditEventType.JOB_CREATED, TENANT, "a@x.io",
                2L, "JOB", 11L, "Backup", null);
        auditService.record(CoreAuditEventType.JOB_CREATED, "rival-inc-beef4567", "b@y.io",
                1L, "JOB", 12L, "Steal", null);

        assertEquals(2, repository
                .findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        TENANT, Instant.EPOCH).size());
        var projectScoped = repository
                .findTop200ByTenantIdAndProjectIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        TENANT, 1L, Instant.EPOCH);
        assertEquals(1, projectScoped.size());
        assertEquals("Deploy", projectScoped.get(0).getTargetName());
    }

    @Test
    void retentionWindowBoundsReads() {
        auditService.record(CoreAuditEventType.RUN_TRIGGERED, TENANT, "a@x.io",
                1L, "RUN", 1L, "Old", null);
        // A "since" in the future excludes everything — the window works.
        assertTrue(repository
                .findTop200ByTenantIdAndCreatedAtGreaterThanEqualOrderByCreatedAtDesc(
                        TENANT, Instant.now().plusSeconds(3600)).isEmpty());
    }
}
