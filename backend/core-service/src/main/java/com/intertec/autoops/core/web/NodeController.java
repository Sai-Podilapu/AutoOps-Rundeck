package com.intertec.autoops.core.web;

import com.intertec.autoops.core.domain.Node;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.service.NodeService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.List;
import java.util.Locale;

/**
 * Execution-target registry, nested under the owning project for list/create,
 * flat by id for update/delete (same shape as jobs). Tenant always from the
 * token claim.
 */
@RestController
public class NodeController {

    private final NodeService nodeService;

    public NodeController(NodeService nodeService) {
        this.nodeService = nodeService;
    }

    public record NodeRequest(
            @NotBlank @Size(max = 128) String name,
            @Size(max = 32) String type,
            @Size(max = 64) String region) {
    }

    /** Update: all fields optional, null = unchanged. */
    public record NodeUpdateRequest(
            @Size(max = 128) String name,
            @Size(max = 32) String type,
            @Size(max = 64) String region) {
    }

    public record NodeResponse(Long id, Long projectId, String name, String type,
                               String region, String status, String createdBy,
                               Instant createdAt) {
    }

    @GetMapping("/api/projects/{projectId}/nodes")
    public List<NodeResponse> list(@PathVariable Long projectId,
                                   @AuthenticationPrincipal Jwt jwt) {
        return nodeService.list(tenant(jwt), projectId).stream().map(this::toResponse).toList();
    }

    @PostMapping("/api/projects/{projectId}/nodes")
    @ResponseStatus(HttpStatus.CREATED)
    public NodeResponse create(@PathVariable Long projectId,
                               @Valid @RequestBody NodeRequest request,
                               @AuthenticationPrincipal Jwt jwt) {
        return toResponse(nodeService.create(tenant(jwt), jwt.getSubject(),
                jwt.getTokenValue(), projectId, request.name(), request.type(),
                request.region()));
    }

    @PutMapping("/api/nodes/{id}")
    public NodeResponse update(@PathVariable Long id,
                               @Valid @RequestBody NodeUpdateRequest request,
                               @AuthenticationPrincipal Jwt jwt) {
        return toResponse(nodeService.update(tenant(jwt), jwt.getTokenValue(), id,
                request.name(), request.type(), request.region()));
    }

    @DeleteMapping("/api/nodes/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id, @AuthenticationPrincipal Jwt jwt) {
        nodeService.delete(tenant(jwt), jwt.getTokenValue(), id);
    }

    private NodeResponse toResponse(Node node) {
        return new NodeResponse(node.getId(), node.getProjectId(), node.getName(),
                node.getType().name().toLowerCase(Locale.ROOT), node.getRegion(),
                nodeService.statusFor(node), node.getCreatedBy(), node.getCreatedAt());
    }

    private String tenant(Jwt jwt) {
        String tenantId = jwt.getClaimAsString("tenantId");
        if (tenantId == null || tenantId.isBlank()) {
            throw CoreException.badRequest("missing_tenant", "Token has no tenantId claim");
        }
        return tenantId;
    }
}
