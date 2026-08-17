package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.CoreAuditEventType;
import com.intertec.autoops.core.domain.LibraryItem;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.AuditService;
import com.intertec.autoops.core.service.LibraryService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Locale;

/**
 * Template catalog + the tenant's imports. Cloning a premium template is
 * gated on PREMIUM_TEMPLATES; writing and editing your own scripts needs only
 * a live subscription.
 */
@RestController
@RequestMapping("/api/library")
public class LibraryController {

    private final LibraryService libraryService;
    private final AuditService auditService;

    public LibraryController(LibraryService libraryService, AuditService auditService) {
        this.libraryService = libraryService;
        this.auditService = auditService;
    }

    public record LibraryItemResponse(Long id, String title, String description, String type,
                                      String category, boolean premium, boolean managed,
                                      boolean owned, boolean locked, int installs,
                                      String definition) {

        static LibraryItemResponse from(LibraryService.LibraryView view) {
            LibraryItem i = view.item();
            return new LibraryItemResponse(i.getId(), i.getTitle(), i.getDescription(),
                    i.getType().name().toLowerCase(Locale.ROOT), i.getCategory(),
                    i.isPremium(), view.managed(), view.owned(), view.locked(),
                    i.getInstalls(),
                    // Definitions of LOCKED premium templates stay server-side.
                    view.locked() ? null : i.getDefinition());
        }
    }

    public record CreateTemplateRequest(@NotBlank @Size(max = 128) String title,
                                        @Size(max = 512) String description,
                                        @Size(max = 16) String type,
                                        @Size(max = 64) String category,
                                        @NotBlank String definition) {
    }

    @GetMapping
    public List<LibraryItemResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return libraryService.list(tenant(jwt), jwt.getTokenValue()).stream()
                .map(LibraryItemResponse::from).toList();
    }

    @PostMapping("/{id}/clone")
    @ResponseStatus(HttpStatus.CREATED)
    public LibraryItemResponse clone(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        LibraryItem copy = libraryService.clone(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), id);
        auditService.record(CoreAuditEventType.LIBRARY_CLONED, tenant(jwt), jwt.getSubject(),
                null, "TEMPLATE", copy.getId(), copy.getTitle(), "from catalog item " + id);
        return new LibraryItemResponse(copy.getId(), copy.getTitle(), copy.getDescription(),
                copy.getType().name().toLowerCase(Locale.ROOT), copy.getCategory(),
                copy.isPremium(), false, true, false, copy.getInstalls(),
                copy.getDefinition());
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public LibraryItemResponse create(@Valid @RequestBody CreateTemplateRequest request,
                                      @AuthenticationPrincipal Jwt jwt) {
        LibraryItem item = libraryService.createOwn(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), request.title(), request.description(),
                request.type(), request.category(), request.definition());
        auditService.record(CoreAuditEventType.LIBRARY_CREATED, tenant(jwt), jwt.getSubject(),
                null, "TEMPLATE", item.getId(), item.getTitle(), null);
        return new LibraryItemResponse(item.getId(), item.getTitle(), item.getDescription(),
                item.getType().name().toLowerCase(Locale.ROOT), item.getCategory(),
                item.isPremium(), false, true, false, item.getInstalls(),
                item.getDefinition());
    }

    /** Every field optional — a rename need not resend the whole script. */
    public record UpdateTemplateRequest(@Size(max = 128) String title,
                                        @Size(max = 512) String description,
                                        @Size(max = 64) String category,
                                        String definition) {
    }

    /**
     * Edit a script this workspace owns — authored here, or imported from the
     * catalog and since adapted. The tenant claim decides which rows are
     * reachable, so a catalog item can never be edited through this path.
     */
    @PutMapping("/{id}")
    public LibraryItemResponse update(@PathVariable Long id,
                                      @Valid @RequestBody UpdateTemplateRequest request,
                                      @AuthenticationPrincipal Jwt jwt) {
        LibraryItem item = libraryService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.title(), request.description(), request.category(),
                request.definition());
        auditService.record(CoreAuditEventType.LIBRARY_UPDATED, tenant(jwt), jwt.getSubject(),
                null, "TEMPLATE", item.getId(), item.getTitle(), null);
        return new LibraryItemResponse(item.getId(), item.getTitle(), item.getDescription(),
                item.getType().name().toLowerCase(Locale.ROOT), item.getCategory(),
                item.isPremium(), false, true, false, item.getInstalls(),
                item.getDefinition());
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
