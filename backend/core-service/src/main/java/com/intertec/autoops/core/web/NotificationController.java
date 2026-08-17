package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.AppNotification;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.NotificationService;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * The signed-in member's notification inbox. Tenant-wide rows, per-member
 * read state (the reader is the token subject). Never subscription-gated —
 * being told your run failed is not a premium feature.
 */
@RestController
@RequestMapping("/api/notifications")
public class NotificationController {

    private final NotificationService notificationService;

    public NotificationController(NotificationService notificationService) {
        this.notificationService = notificationService;
    }

    public record NotificationResponse(Long id, String kind, String title, String body,
                                       String link, boolean read, Instant createdAt) {

        static NotificationResponse from(NotificationService.NotificationView view) {
            var n = view.notification();
            return new NotificationResponse(n.getId(), n.getKind().name(), n.getTitle(),
                    n.getBody(), n.getLink(), view.read(), n.getCreatedAt());
        }
    }

    @GetMapping
    public List<NotificationResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return notificationService.list(tenant(jwt), jwt.getSubject()).stream()
                .map(NotificationResponse::from).toList();
    }

    @GetMapping("/unread-count")
    public Map<String, Long> unreadCount(@AuthenticationPrincipal Jwt jwt) {
        return Map.of("count", notificationService.unreadCount(tenant(jwt), jwt.getSubject()));
    }

    /**
     * The label and blurb ship with the preference rather than living in the
     * SPA so that a new {@link AppNotification.Kind} shows up in the settings
     * screen without a frontend change — the same rule the channels catalog
     * follows. The blurb names what actually publishes the kind, so nobody has
     * to guess what a switch controls.
     */
    public record PreferenceResponse(String kind, String label, String description,
                                     boolean enabled) {

        static PreferenceResponse from(NotificationService.Preference preference) {
            return new PreferenceResponse(preference.kind().name(),
                    label(preference.kind()), description(preference.kind()),
                    preference.enabled());
        }

        private static String label(AppNotification.Kind kind) {
            return switch (kind) {
                case ALERT -> "Alerts";
                case SYSTEM -> "Activity";
                case PROVIDER -> "Announcements";
            };
        }

        private static String description(AppNotification.Kind kind) {
            return switch (kind) {
                case ALERT -> "Failed runs and approval requests";
                case SYSTEM -> "Approval decisions and workspace activity";
                case PROVIDER -> "Broadcasts from the AutoOps team";
            };
        }
    }

    public record PreferenceRequest(String kind, Boolean enabled) {
    }

    @GetMapping("/preferences")
    public List<PreferenceResponse> preferences(@AuthenticationPrincipal Jwt jwt) {
        return notificationService.preferences(tenant(jwt), jwt.getSubject()).stream()
                .map(PreferenceResponse::from).toList();
    }

    @PutMapping("/preferences")
    public List<PreferenceResponse> setPreference(@RequestBody PreferenceRequest body,
                                                  @AuthenticationPrincipal Jwt jwt) {
        if (body == null || body.enabled() == null) {
            throw CoreException.badRequest("missing_enabled", "enabled is required");
        }
        AppNotification.Kind kind;
        try {
            kind = AppNotification.Kind.valueOf(
                    String.valueOf(body.kind()).trim().toUpperCase());
        } catch (IllegalArgumentException | NullPointerException ex) {
            throw CoreException.badRequest("unknown_kind",
                    "No such notification kind: " + body.kind());
        }
        notificationService.setPreference(tenant(jwt), jwt.getSubject(), kind, body.enabled());
        return preferences(jwt);
    }

    @PatchMapping("/read-all")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void markAllRead(@AuthenticationPrincipal Jwt jwt) {
        notificationService.markAllRead(tenant(jwt), jwt.getSubject());
    }

    @PatchMapping("/{id}/read")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void markRead(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        notificationService.markRead(tenant(jwt), jwt.getSubject(), id);
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
