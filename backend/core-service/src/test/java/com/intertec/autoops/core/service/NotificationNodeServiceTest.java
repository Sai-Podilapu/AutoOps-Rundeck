package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.AppNotification;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.AppNotificationRepository;
import com.intertec.autoops.core.repo.NodeRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

/** Inbox + node registry against H2 with real commit semantics. */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({NotificationService.class, NodeService.class, ProjectService.class,
        SubscriptionGate.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class NotificationNodeServiceTest {

    private static final String TENANT = "acme-corp-cafe0123";
    private static final String ALICE = "alice@acme.io";
    private static final String BOB = "bob@acme.io";
    private static final String TOKEN = "test-access-token";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);

    @Autowired
    private NotificationService notificationService;
    @Autowired
    private NodeService nodeService;
    @Autowired
    private ProjectService projectService;
    @Autowired
    private AppNotificationRepository notificationRepository;
    @Autowired
    private NodeRepository nodeRepository;
    @Autowired
    private ProjectRepository projectRepository;
    @Autowired
    private JdbcTemplate jdbcTemplate;
    @MockBean
    private EntitlementClient entitlementClient;

    @TestConfiguration
    static class TestConfig {
        @Bean
        ObjectMapper objectMapper() {
            return new ObjectMapper();
        }

        @Bean
        CoreProperties coreProperties() {
            return new CoreProperties(); // simulated mode → runner nodes online
        }
    }

    @BeforeEach
    void reset() {
        jdbcTemplate.execute("CREATE TABLE IF NOT EXISTS notification_reads ("
                + "notification_id BIGINT NOT NULL, reader VARCHAR(255) NOT NULL, "
                + "read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
                + "PRIMARY KEY (notification_id, reader))");
        jdbcTemplate.execute("CREATE TABLE IF NOT EXISTS notification_preferences ("
                + "tenant_id VARCHAR(64) NOT NULL, reader VARCHAR(255) NOT NULL, "
                + "kind VARCHAR(16) NOT NULL, muted TINYINT NOT NULL DEFAULT 0, "
                + "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
                + "PRIMARY KEY (tenant_id, reader, kind))");
        jdbcTemplate.update("DELETE FROM notification_preferences");
        jdbcTemplate.update("DELETE FROM notification_reads");
        notificationRepository.deleteAll();
        nodeRepository.deleteAll();
        projectRepository.deleteAll();
        when(entitlementClient.checkActive(any())).thenReturn(OK);
        when(entitlementClient.checkQuota(any(), any(), org.mockito.ArgumentMatchers.anyLong()))
                .thenReturn(OK);
    }

    // ------ notifications ------

    @Test
    void readStateIsPerMemberNotPerNotification() {
        notificationService.publish(TENANT, AppNotification.Kind.ALERT, "Run failed: deploy",
                "step 2 exited 1", "/app/projects/1/executions");

        notificationService.markAllRead(TENANT, ALICE);

        assertTrue(notificationService.list(TENANT, ALICE).get(0).read());
        assertFalse(notificationService.list(TENANT, BOB).get(0).read(),
                "Alice reading must not mark Bob's inbox");
        assertEquals(0, notificationService.unreadCount(TENANT, ALICE));
        assertEquals(1, notificationService.unreadCount(TENANT, BOB));
    }

    @Test
    void markReadIsIdempotentAndTenantScoped() {
        notificationService.publish(TENANT, AppNotification.Kind.SYSTEM, "Hello", null, null);
        Long id = notificationService.list(TENANT, ALICE).get(0).notification().getId();

        notificationService.markRead(TENANT, ALICE, id);
        notificationService.markRead(TENANT, ALICE, id); // second time is a no-op

        assertEquals(0, notificationService.unreadCount(TENANT, ALICE));
        assertThrows(CoreException.class,
                () -> notificationService.markRead("rival-inc-beef4567", BOB, id),
                "another tenant must not even see the notification");
    }

    @Test
    void publishFailuresNeverThrow() {
        // 5000-char title exceeds the column but publish() must swallow it.
        notificationService.publish(TENANT, AppNotification.Kind.SYSTEM,
                "x".repeat(5000), null, null);
        // Truncated to 255 and stored, or dropped — either way, no exception.
        assertTrue(notificationService.list(TENANT, ALICE).size() <= 1);
    }

    // ------ preferences ------

    @Test
    void everyKindIsSubscribedUntilTheMemberSaysOtherwise() {
        var prefs = notificationService.preferences(TENANT, ALICE);

        assertEquals(AppNotification.Kind.values().length, prefs.size(),
                "the screen renders one row per publishable kind, defaults included");
        assertTrue(prefs.stream().allMatch(NotificationService.Preference::enabled));
    }

    @Test
    void mutingAKindHidesItFromTheInboxAndTheBadge() {
        notificationService.publish(TENANT, AppNotification.Kind.ALERT, "Run failed", null, null);
        notificationService.publish(TENANT, AppNotification.Kind.PROVIDER, "New release",
                null, null);

        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.ALERT, false);

        assertEquals(1, notificationService.list(TENANT, ALICE).size());
        assertEquals(AppNotification.Kind.PROVIDER,
                notificationService.list(TENANT, ALICE).get(0).notification().getKind());
        assertEquals(1, notificationService.unreadCount(TENANT, ALICE),
                "a muted kind must not keep counting against the badge");
    }

    @Test
    void mutingIsPerMemberAndPerTenant() {
        notificationService.publish(TENANT, AppNotification.Kind.ALERT, "Run failed", null, null);
        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.ALERT, false);

        assertEquals(0, notificationService.list(TENANT, ALICE).size());
        assertEquals(1, notificationService.list(TENANT, BOB).size(),
                "Alice's choice is hers alone");
        assertTrue(notificationService.preferences("rival-inc-beef4567", ALICE).stream()
                        .allMatch(NotificationService.Preference::enabled),
                "the same address in another tenant starts from the defaults");
    }

    @Test
    void unmutingRestoresTheHistoryRatherThanLeavingAGap() {
        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.ALERT, false);
        notificationService.publish(TENANT, AppNotification.Kind.ALERT, "Run failed", null, null);
        assertEquals(0, notificationService.list(TENANT, ALICE).size());

        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.ALERT, true);

        assertEquals(1, notificationService.list(TENANT, ALICE).size(),
                "publishing is unaffected by a mute — only the reading is filtered");
        assertEquals(1, notificationService.unreadCount(TENANT, ALICE));
    }

    @Test
    void setPreferenceIsAnUpsertNotAnInsert() {
        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.SYSTEM, false);
        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.SYSTEM, false);
        notificationService.setPreference(TENANT, ALICE, AppNotification.Kind.SYSTEM, true);

        assertEquals(1, (int) jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM notification_preferences WHERE reader = ?",
                Integer.class, ALICE), "toggling must not accumulate rows");
        assertTrue(notificationService.preferences(TENANT, ALICE).stream()
                .filter(p -> p.kind() == AppNotification.Kind.SYSTEM)
                .allMatch(NotificationService.Preference::enabled));
    }

    // ------ nodes ------

    @Test
    void nodeLifecycleIsTenantScopedAndGated() {
        var project = projectService.create(TENANT, ALICE, TOKEN, "Alpha", null);
        var node = nodeService.create(TENANT, ALICE, TOKEN, project.getId(),
                "prod-runner-01", "runner", "us-east-1");

        assertEquals("online", nodeService.statusFor(node),
                "simulated mode: the built-in executor is always available");
        assertEquals(1, nodeService.list(TENANT, project.getId()).size());

        // Duplicate name in the same project is a conflict.
        CoreException dup = assertThrows(CoreException.class,
                () -> nodeService.create(TENANT, ALICE, TOKEN, project.getId(),
                        "prod-runner-01", "vm", null));
        assertEquals("node_exists", dup.getError());

        var updated = nodeService.update(TENANT, TOKEN, node.getId(), "prod-runner-02",
                "vm", "eu-west-1");
        assertEquals("prod-runner-02", updated.getName());
        assertEquals("registered", nodeService.statusFor(updated),
                "non-runner kinds have no live health source yet");

        nodeService.delete(TENANT, TOKEN, node.getId());
        assertEquals(0, nodeService.list(TENANT, project.getId()).size());
    }

    @Test
    void unknownNodeTypeIsRejected() {
        var project = projectService.create(TENANT, ALICE, TOKEN, "Alpha", null);
        CoreException ex = assertThrows(CoreException.class,
                () -> nodeService.create(TENANT, ALICE, TOKEN, project.getId(),
                        "n1", "mainframe", null));
        assertEquals("unknown_node_type", ex.getError());
    }
}
