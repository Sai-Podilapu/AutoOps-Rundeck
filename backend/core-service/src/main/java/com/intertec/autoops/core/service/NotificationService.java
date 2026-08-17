package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.AppNotification;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.AppNotificationRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.EnumSet;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Tenant-wide notification inbox. Rows are written by the platform (run
 * failures, approval lifecycle) — best-effort, never breaking the flow that
 * triggered them. Read state is per member in {@code notification_reads}
 * (plain SQL — a two-column join table doesn't need an entity), and so are
 * per-member mutes in {@code notification_preferences}.
 *
 * <p>A muted kind is filtered out of {@link #list} <em>and</em>
 * {@link #unreadCount}: a preference that left the badge counting things you
 * asked not to see would be decoration, not a setting. Publishing is
 * deliberately unaffected — the row is still written, so unmuting shows the
 * history rather than a gap.
 */
@Service
public class NotificationService {

    private static final Logger log = LoggerFactory.getLogger(NotificationService.class);

    private final AppNotificationRepository notificationRepository;
    private final JdbcTemplate jdbcTemplate;

    public NotificationService(AppNotificationRepository notificationRepository,
                               JdbcTemplate jdbcTemplate) {
        this.notificationRepository = notificationRepository;
        this.jdbcTemplate = jdbcTemplate;
    }

    /** Best-effort publish — notification failures must never fail the caller. */
    public void publish(String tenantId, AppNotification.Kind kind, String title,
                        String body, String link) {
        try {
            AppNotification notification = new AppNotification();
            notification.setTenantId(tenantId);
            notification.setKind(kind);
            notification.setTitle(truncate(title, 255));
            notification.setBody(truncate(body, 1024));
            notification.setLink(truncate(link, 255));
            notificationRepository.save(notification);
        } catch (Exception ex) {
            log.error("Failed to publish notification '{}': {}", title, ex.getMessage());
        }
    }

    public record NotificationView(AppNotification notification, boolean read) {
    }

    @Transactional(readOnly = true)
    public List<NotificationView> list(String tenantId, String reader) {
        List<AppNotification> rows =
                notificationRepository.findTop100ByTenantIdOrderByCreatedAtDesc(tenantId);
        if (rows.isEmpty()) {
            return List.of();
        }
        Set<AppNotification.Kind> muted = mutedKinds(tenantId, reader);
        Set<Long> readIds = new HashSet<>(jdbcTemplate.queryForList(
                "SELECT notification_id FROM notification_reads WHERE reader = ?",
                Long.class, reader));
        return rows.stream()
                .filter(n -> !muted.contains(n.getKind()))
                .map(n -> new NotificationView(n, readIds.contains(n.getId())))
                .toList();
    }

    @Transactional(readOnly = true)
    public long unreadCount(String tenantId, String reader) {
        Set<AppNotification.Kind> muted = mutedKinds(tenantId, reader);
        // Counted in SQL, but the mute list is small and bounded by the enum,
        // so it is applied as a NOT IN rather than a second join.
        StringBuilder sql = new StringBuilder(
                "SELECT COUNT(*) FROM notifications n WHERE n.tenant_id = ? AND NOT EXISTS "
                        + "(SELECT 1 FROM notification_reads r "
                        + "WHERE r.notification_id = n.id AND r.reader = ?)");
        List<Object> args = new java.util.ArrayList<>(List.of(tenantId, reader));
        if (!muted.isEmpty()) {
            sql.append(" AND n.kind NOT IN (")
                    .append("?,".repeat(muted.size() - 1)).append("?)");
            muted.forEach(kind -> args.add(kind.name()));
        }
        Long count = jdbcTemplate.queryForObject(sql.toString(), Long.class, args.toArray());
        return count != null ? count : 0;
    }

    // ---------------- preferences ----------------

    /**
     * What this member has chosen, one entry per kind the platform can
     * publish — including the kinds they have never touched, so the caller
     * renders the full list without having to know the defaults.
     */
    @Transactional(readOnly = true)
    public List<Preference> preferences(String tenantId, String reader) {
        Set<AppNotification.Kind> muted = mutedKinds(tenantId, reader);
        return java.util.Arrays.stream(AppNotification.Kind.values())
                .map(kind -> new Preference(kind, !muted.contains(kind)))
                .toList();
    }

    /** Idempotent upsert — the UI toggles, it does not track whether a row exists. */
    @Transactional
    public void setPreference(String tenantId, String reader, AppNotification.Kind kind,
                              boolean enabled) {
        int updated = jdbcTemplate.update(
                "UPDATE notification_preferences SET muted = ? "
                        + "WHERE tenant_id = ? AND reader = ? AND kind = ?",
                enabled ? 0 : 1, tenantId, reader, kind.name());
        if (updated == 0) {
            jdbcTemplate.update("INSERT INTO notification_preferences "
                            + "(tenant_id, reader, kind, muted) VALUES (?, ?, ?, ?)",
                    tenantId, reader, kind.name(), enabled ? 0 : 1);
        }
    }

    /** {@code enabled == true} means "show me these". */
    public record Preference(AppNotification.Kind kind, boolean enabled) {
    }

    /**
     * Absent row means subscribed, so only the mutes are read. An unreadable
     * preference table must not blank the inbox — on failure everything stays
     * visible, which is the safe direction to fail in.
     */
    private Set<AppNotification.Kind> mutedKinds(String tenantId, String reader) {
        try {
            List<String> rows = jdbcTemplate.queryForList(
                    "SELECT kind FROM notification_preferences "
                            + "WHERE tenant_id = ? AND reader = ? AND muted = 1",
                    String.class, tenantId, reader);
            Set<AppNotification.Kind> muted = EnumSet.noneOf(AppNotification.Kind.class);
            for (String row : rows) {
                try {
                    muted.add(AppNotification.Kind.valueOf(row));
                } catch (IllegalArgumentException retiredKind) {
                    // A kind dropped from the enum leaves a harmless stale row.
                }
            }
            return muted;
        } catch (DataAccessException ex) {
            log.warn("Could not read notification preferences for {}: {}", reader, ex.getMessage());
            return EnumSet.noneOf(AppNotification.Kind.class);
        }
    }

    @Transactional
    public void markRead(String tenantId, String reader, Long id) {
        notificationRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("notification_not_found",
                        "No such notification"));
        try {
            jdbcTemplate.update(
                    "INSERT INTO notification_reads (notification_id, reader) VALUES (?, ?)",
                    id, reader);
        } catch (DataAccessException alreadyRead) {
            // idempotent: marking twice is fine
        }
    }

    @Transactional
    public void markAllRead(String tenantId, String reader) {
        jdbcTemplate.update(
                "INSERT INTO notification_reads (notification_id, reader) "
                        + "SELECT n.id, ? FROM notifications n WHERE n.tenant_id = ? "
                        + "AND NOT EXISTS (SELECT 1 FROM notification_reads r "
                        + "WHERE r.notification_id = n.id AND r.reader = ?)",
                reader, tenantId, reader);
    }

    private static String truncate(String value, int maxLength) {
        return value == null || value.length() <= maxLength ? value
                : value.substring(0, maxLength);
    }
}
