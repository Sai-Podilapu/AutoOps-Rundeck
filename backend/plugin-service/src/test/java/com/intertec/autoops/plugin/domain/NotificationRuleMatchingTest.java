package com.intertec.autoops.plugin.domain;

import org.junit.jupiter.api.Test;

import java.util.EnumSet;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The wildcard semantics of a rule's scope. These are the decisions that
 * decide whether an alert fires at all, and every one of them is a place a
 * null check could silently widen a rule across projects.
 */
class NotificationRuleMatchingTest {

    private static NotificationRule rule(TargetType type, Long targetId, Long projectId,
                                         LifecycleEvent... events) {
        NotificationRule rule = new NotificationRule();
        rule.setTenantId("t1");
        rule.setInstallationId(1L);
        rule.setTargetType(type);
        rule.setTargetId(targetId);
        rule.setProjectId(projectId);
        rule.setEventSet(EnumSet.copyOf(java.util.List.of(events)));
        return rule;
    }

    @Test
    void targetScopedRuleMatchesOnlyThatTarget() {
        NotificationRule rule = rule(TargetType.JOB, 7L, null, LifecycleEvent.FAILED);

        assertThat(rule.matches(TargetType.JOB, 7L, 3L, LifecycleEvent.FAILED)).isTrue();
        assertThat(rule.matches(TargetType.JOB, 8L, 3L, LifecycleEvent.FAILED)).isFalse();
    }

    @Test
    void projectScopedRuleMatchesEveryTargetInThatProject() {
        NotificationRule rule = rule(TargetType.JOB, null, 3L, LifecycleEvent.FAILED);

        assertThat(rule.matches(TargetType.JOB, 7L, 3L, LifecycleEvent.FAILED)).isTrue();
        assertThat(rule.matches(TargetType.JOB, 99L, 3L, LifecycleEvent.FAILED)).isTrue();
        assertThat(rule.matches(TargetType.JOB, 7L, 4L, LifecycleEvent.FAILED)).isFalse();
    }

    /** A project rule must not fire for an event that carries no project. */
    @Test
    void projectScopedRuleDoesNotMatchAProjectlessEvent() {
        NotificationRule rule = rule(TargetType.JOB, null, 3L, LifecycleEvent.MISSED);

        assertThat(rule.matches(TargetType.JOB, 7L, null, LifecycleEvent.MISSED)).isFalse();
    }

    @Test
    void unscopedRuleMatchesTheWholeWorkspaceIncludingProjectlessEvents() {
        NotificationRule rule = rule(TargetType.JOB, null, null, LifecycleEvent.FAILED);

        assertThat(rule.matches(TargetType.JOB, 7L, 3L, LifecycleEvent.FAILED)).isTrue();
        assertThat(rule.matches(TargetType.JOB, 1L, null, LifecycleEvent.FAILED)).isTrue();
    }

    /** Jobs and workflows share a run engine but must never share alerts. */
    @Test
    void aJobRuleNeverMatchesAWorkflow() {
        NotificationRule rule = rule(TargetType.JOB, null, null, LifecycleEvent.FAILED);

        assertThat(rule.matches(TargetType.WORKFLOW, 7L, 3L, LifecycleEvent.FAILED)).isFalse();
    }

    @Test
    void anUnsubscribedEventDoesNotMatch() {
        NotificationRule rule = rule(TargetType.JOB, null, null, LifecycleEvent.FAILED);

        assertThat(rule.matches(TargetType.JOB, 7L, 3L, LifecycleEvent.SUCCEEDED)).isFalse();
    }

    @Test
    void aDisabledRuleMatchesNothing() {
        NotificationRule rule = rule(TargetType.JOB, null, null, LifecycleEvent.FAILED);
        rule.setEnabled(false);

        assertThat(rule.matches(TargetType.JOB, 7L, 3L, LifecycleEvent.FAILED)).isFalse();
    }

    /** Round-trips through the comma-separated column, in enum order. */
    @Test
    void eventSetSurvivesStorageAsAString() {
        NotificationRule rule = rule(TargetType.JOB, null, null,
                LifecycleEvent.FAILED, LifecycleEvent.STARTED, LifecycleEvent.MISSED);

        assertThat(rule.getEvents()).isEqualTo("STARTED,FAILED,MISSED");
        assertThat(rule.eventSet()).containsExactlyInAnyOrder(
                LifecycleEvent.STARTED, LifecycleEvent.FAILED, LifecycleEvent.MISSED);
    }
}
