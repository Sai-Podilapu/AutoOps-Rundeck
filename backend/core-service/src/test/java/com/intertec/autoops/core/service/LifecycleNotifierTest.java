package com.intertec.autoops.core.service;

import com.intertec.autoops.core.client.PluginClient;
import com.intertec.autoops.core.domain.Run;
import com.intertec.autoops.core.domain.RunStatus;
import com.intertec.autoops.core.domain.RunTargetType;
import com.intertec.autoops.core.domain.RunTrigger;
import com.intertec.autoops.core.repo.ProjectRepository;
import com.intertec.autoops.core.repo.RunRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The status → event mapping, and the one piece of real logic here: deciding
 * when a success is a recovery.
 */
class LifecycleNotifierTest {

    private PluginClient pluginClient;
    private RunRepository runRepository;
    private LifecycleNotifier notifier;

    @BeforeEach
    void setUp() {
        pluginClient = mock(PluginClient.class);
        runRepository = mock(RunRepository.class);
        ProjectRepository projectRepository = mock(ProjectRepository.class);
        when(projectRepository.findByIdAndTenantId(anyLong(), anyString()))
                .thenReturn(Optional.empty());
        notifier = new LifecycleNotifier(pluginClient, runRepository, projectRepository);
    }

    private static Run run(RunStatus status) {
        Run run = new Run();
        run.setTenantId("tenant-a");
        run.setProjectId(3L);
        run.setTargetType(RunTargetType.JOB);
        run.setTargetId(7L);
        run.setTargetName("Nightly backup");
        run.setStatus(status);
        run.setTrigger(RunTrigger.SCHEDULE);
        run.setDurationMs(90_000L);
        return run;
    }

    private List<PluginClient.LifecycleEvent> published() {
        ArgumentCaptor<PluginClient.LifecycleEvent> captor =
                ArgumentCaptor.forClass(PluginClient.LifecycleEvent.class);
        verify(pluginClient, times(1)).publish(captor.capture());
        return captor.getAllValues();
    }

    private void noPreviousRun() {
        when(runRepository
                .findFirstByTenantIdAndTargetTypeAndTargetIdAndStatusInAndIdLessThanOrderByIdDesc(
                        anyString(), any(), anyLong(), any(Collection.class), any()))
                .thenReturn(Optional.empty());
    }

    private void previousRunWas(RunStatus status) {
        Run previous = run(status);
        when(runRepository
                .findFirstByTenantIdAndTargetTypeAndTargetIdAndStatusInAndIdLessThanOrderByIdDesc(
                        anyString(), any(), anyLong(), any(Collection.class), any()))
                .thenReturn(Optional.of(previous));
    }

    /** RUNNING is the transition that means STARTED; RunStatus has no such member. */
    @Test
    void runningTransitionIsReportedAsStarted() {
        notifier.runStarted(run(RunStatus.RUNNING));

        assertThat(published().getFirst().event()).isEqualTo("STARTED");
    }

    @Test
    void failedCarriesTheErrorAndTheDuration() {
        Run run = run(RunStatus.FAILED);
        run.setError("step 2 exited 1");
        noPreviousRun();

        notifier.runFinished(run);

        PluginClient.LifecycleEvent event = published().getFirst();
        assertThat(event.event()).isEqualTo("FAILED");
        assertThat(event.detail()).isEqualTo("step 2 exited 1");
        assertThat(event.durationSeconds()).isEqualTo(90L);
        assertThat(event.targetType()).isEqualTo("JOB");
    }

    @Test
    void canceledUsesCoresSingleLSpelling() {
        noPreviousRun();

        notifier.runFinished(run(RunStatus.CANCELED));

        assertThat(published().getFirst().event()).isEqualTo("CANCELED");
    }

    /** A first-ever success is not a recovery. */
    @Test
    void successWithNoHistoryEmitsSucceededOnly() {
        noPreviousRun();

        notifier.runFinished(run(RunStatus.SUCCEEDED));

        assertThat(published()).extracting(PluginClient.LifecycleEvent::event)
                .containsExactly("SUCCEEDED");
    }

    @Test
    void successAfterASuccessIsNotARecovery() {
        previousRunWas(RunStatus.SUCCEEDED);

        notifier.runFinished(run(RunStatus.SUCCEEDED));

        assertThat(published()).extracting(PluginClient.LifecycleEvent::event)
                .containsExactly("SUCCEEDED");
    }

    /**
     * RECOVERED is emitted ALONGSIDE SUCCEEDED, never instead of it — a tenant
     * subscribed only to SUCCEEDED must still hear about the run that fixed it.
     */
    @Test
    void successAfterAFailureEmitsBothSucceededAndRecovered() {
        previousRunWas(RunStatus.FAILED);

        notifier.runFinished(run(RunStatus.SUCCEEDED));

        ArgumentCaptor<PluginClient.LifecycleEvent> captor =
                ArgumentCaptor.forClass(PluginClient.LifecycleEvent.class);
        verify(pluginClient, times(2)).publish(captor.capture());
        assertThat(captor.getAllValues()).extracting(PluginClient.LifecycleEvent::event)
                .containsExactly("SUCCEEDED", "RECOVERED");
    }

    /** QUEUED and RUNNING are not terminal — finish() cannot legitimately reach them. */
    @Test
    void aNonTerminalStatusEmitsNothing() {
        notifier.runFinished(run(RunStatus.RUNNING));

        verify(pluginClient, never()).publish(any());
    }

    @Test
    void stalledEventsCarryHowLongTheRunHasBeenOpen() {
        Run run = run(RunStatus.RUNNING);
        Instant now = Instant.parse("2026-08-06T12:00:00Z");
        run.setStartedAt(now.minusSeconds(3 * 3600));

        List<PluginClient.LifecycleEvent> events = notifier.stalledEvents(List.of(run), now);

        assertThat(events).hasSize(1);
        assertThat(events.getFirst().event()).isEqualTo("STALLED");
        assertThat(events.getFirst().durationSeconds()).isEqualTo(10_800L);
        assertThat(events.getFirst().detail()).contains("3 hours");
    }

    /** A run that never started must not produce a nonsense negative duration. */
    @Test
    void stalledHandlesARunWithNoStartTime() {
        Run run = run(RunStatus.RUNNING);
        run.setStartedAt(null);

        List<PluginClient.LifecycleEvent> events =
                notifier.stalledEvents(List.of(run), Instant.now());

        assertThat(events.getFirst().durationSeconds()).isZero();
    }
}
