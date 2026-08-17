package com.intertec.autoops.core.service;

import com.intertec.autoops.core.config.CoreProperties;
import com.intertec.autoops.core.domain.Node;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.NodeRepository;
import com.intertec.autoops.core.repo.ProjectRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;

/**
 * Project-scoped execution-target registry. Mutations pass the subscription
 * gate like every other resource. Node status is honest: RUNNER nodes execute
 * through the platform runtime, so they report the runtime's REAL health
 * (job-service /actuator/health in remote mode, always up in simulated
 * mode); other kinds are "registered" until per-node agents exist — we never
 * invent an "online" we can't observe.
 */
@Service
public class NodeService {

    private static final Logger log = LoggerFactory.getLogger(NodeService.class);
    private static final Duration HEALTH_CACHE_TTL = Duration.ofSeconds(30);

    private final NodeRepository nodeRepository;
    private final ProjectRepository projectRepository;
    private final SubscriptionGate gate;
    private final CoreProperties properties;
    private final RestClient healthClient;

    private volatile Boolean runtimeHealthy;
    private volatile Instant runtimeCheckedAt = Instant.EPOCH;

    public NodeService(NodeRepository nodeRepository, ProjectRepository projectRepository,
                       SubscriptionGate gate, CoreProperties properties) {
        this.nodeRepository = nodeRepository;
        this.projectRepository = projectRepository;
        this.gate = gate;
        this.properties = properties;
        JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory();
        requestFactory.setReadTimeout(Duration.ofSeconds(2));
        this.healthClient = RestClient.builder()
                .baseUrl(properties.getExecution().getJobServiceUrl())
                .requestFactory(requestFactory)
                .build();
    }

    @Transactional(readOnly = true)
    public List<Node> list(String tenantId, Long projectId) {
        return nodeRepository.findByTenantIdAndProjectIdOrderByCreatedAtDesc(tenantId, projectId);
    }

    @Transactional
    public Node create(String tenantId, String actor, String accessToken, Long projectId,
                       String name, String type, String region) {
        projectRepository.findByIdAndTenantId(projectId, tenantId)
                .orElseThrow(() -> CoreException.notFound("project_not_found", "No such project"));
        if (nodeRepository.existsByTenantIdAndProjectIdAndName(tenantId, projectId, name)) {
            throw CoreException.conflict("node_exists",
                    "A node with this name already exists in the project");
        }
        gate.requireActive(accessToken);
        Node node = new Node();
        node.setTenantId(tenantId);
        node.setProjectId(projectId);
        node.setName(name);
        node.setType(parseType(type));
        node.setRegion(blankToNull(region));
        node.setCreatedBy(actor);
        Node saved = nodeRepository.save(node);
        log.info("Tenant {} registered node {} ({})", tenantId, saved.getId(), saved.getType());
        return saved;
    }

    @Transactional
    public Node update(String tenantId, String accessToken, Long id,
                       String name, String type, String region) {
        gate.requireActive(accessToken);
        Node node = require(tenantId, id);
        if (name != null && !name.isBlank() && !name.equals(node.getName())) {
            if (nodeRepository.existsByTenantIdAndProjectIdAndName(tenantId,
                    node.getProjectId(), name)) {
                throw CoreException.conflict("node_exists",
                        "A node with this name already exists in the project");
            }
            node.setName(name);
        }
        if (type != null && !type.isBlank()) {
            node.setType(parseType(type));
        }
        if (region != null) {
            node.setRegion(blankToNull(region));
        }
        return nodeRepository.save(node);
    }

    @Transactional
    public void delete(String tenantId, String accessToken, Long id) {
        gate.requireActive(accessToken);
        nodeRepository.delete(require(tenantId, id));
    }

    /** "online"/"offline" for RUNNER nodes (real runtime health); "registered" else. */
    public String statusFor(Node node) {
        if (node.getType() != Node.Type.RUNNER) {
            return "registered";
        }
        if (!"remote".equals(properties.getExecution().getMode())) {
            return "online"; // built-in simulated executor is always available
        }
        return runtimeHealthy() ? "online" : "offline";
    }

    private boolean runtimeHealthy() {
        Instant now = Instant.now();
        if (runtimeHealthy != null && runtimeCheckedAt.plus(HEALTH_CACHE_TTL).isAfter(now)) {
            return runtimeHealthy;
        }
        boolean healthy;
        try {
            String body = healthClient.get().uri("/actuator/health").retrieve()
                    .body(String.class);
            healthy = body != null && body.contains("UP");
        } catch (Exception ex) {
            healthy = false;
        }
        runtimeHealthy = healthy;
        runtimeCheckedAt = now;
        return healthy;
    }

    private Node require(String tenantId, Long id) {
        return nodeRepository.findByIdAndTenantId(id, tenantId)
                .orElseThrow(() -> CoreException.notFound("node_not_found", "No such node"));
    }

    private static Node.Type parseType(String type) {
        if (type == null || type.isBlank()) {
            return Node.Type.RUNNER;
        }
        try {
            return Node.Type.valueOf(type.trim().toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException ex) {
            throw CoreException.badRequest("unknown_node_type",
                    "Unknown node type: " + type + " — use runner, container, vm, or serverless");
        }
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
