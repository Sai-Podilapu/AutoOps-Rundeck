package com.intertec.autoops.workflow.repo;

import com.intertec.autoops.workflow.domain.Workflow;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * How many customers hold each catalog workflow.
 *
 * <p>The bug this pins: the provider library showed "0 rollouts" forever. It was
 * reading {@code library_items.installs}, a counter only ever incremented when a
 * customer IMPORTS a script — nothing on the rollout path touched it, so an
 * agent or workflow delivered to ten customers still read zero.
 *
 * <p>Counted from live rows rather than a counter, which is what makes it fall
 * as well as rise.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
class RolloutCountTest {

    @Autowired
    private WorkflowRepository workflowRepository;

    private Workflow delivered(String tenantId, Long projectId, Long sourceId, String name) {
        Workflow w = new Workflow();
        w.setTenantId(tenantId);
        w.setProjectId(projectId);
        w.setName(name);
        w.setDefinition("{\"nodes\":[]}");
        w.setSourceId(sourceId);
        w.setOrigin(Workflow.Origin.PROVIDER);
        return workflowRepository.save(w);
    }

    private Map<String, Long> counts() {
        Map<String, Long> out = new HashMap<>();
        for (Object[] row : workflowRepository.countGroupedBySourceId()) {
            out.put(String.valueOf(row[0]), ((Number) row[1]).longValue());
        }
        return out;
    }

    @Test
    void countsOneEntryPerDeliveredCopy() {
        delivered("acme-1", 1L, 100L, "Patch Tuesday");
        delivered("beta-2", 2L, 100L, "Patch Tuesday");
        delivered("acme-1", 1L, 200L, "Offboarding");

        assertThat(counts()).containsEntry("100", 2L).containsEntry("200", 1L);
    }

    @Test
    void aCatalogItemNobodyHoldsIsAbsentRatherThanZero() {
        delivered("acme-1", 1L, 100L, "Patch Tuesday");

        // The response carries only what exists; the caller defaults a missing
        // key to 0. Emitting an explicit zero would mean enumerating every
        // catalog item, which this service knows nothing about.
        assertThat(counts()).doesNotContainKey("999");
    }

    @Test
    void aTenantsOwnWorkflowIsNotSomebodysRollout() {
        Workflow own = new Workflow();
        own.setTenantId("acme-1");
        own.setProjectId(1L);
        own.setName("Built here");
        own.setDefinition("{\"nodes\":[]}");
        own.setOrigin(Workflow.Origin.TENANT);
        workflowRepository.save(own); // sourceId stays null

        delivered("acme-1", 1L, 100L, "Patch Tuesday");

        // Null source ids must not collapse into a "null" bucket that the
        // provider console would then render as a catalog item's count.
        assertThat(counts()).containsOnlyKeys("100");
    }

    @Test
    void revokingADeliveryTakesTheCountBackDown() {
        Workflow first = delivered("acme-1", 1L, 100L, "Patch Tuesday");
        delivered("beta-2", 2L, 100L, "Patch Tuesday");
        assertThat(counts()).containsEntry("100", 2L);

        workflowRepository.delete(first);

        // The whole reason this is not a stored counter: a counter could only
        // ever go up, and would keep claiming two customers hold it.
        assertThat(counts()).containsEntry("100", 1L);
    }

    @Test
    void theSameItemInTwoProjectsOfOneCustomerCountsTwice() {
        // Deliberate: the unique index is (project_id, source_id), so delivering
        // into two of a customer's projects is a legitimate rollout, and the
        // number reflects copies in existence rather than customers reached.
        delivered("acme-1", 1L, 100L, "Patch Tuesday");
        delivered("acme-1", 2L, 100L, "Patch Tuesday");

        assertThat(counts()).containsEntry("100", 2L);
    }

    @Test
    void noDeliveriesAtAllIsAnEmptyMapNotAFailure() {
        assertThat(counts()).isEmpty();
        assertThat(workflowRepository.countGroupedBySourceId()).isEqualTo(List.of());
    }
}
