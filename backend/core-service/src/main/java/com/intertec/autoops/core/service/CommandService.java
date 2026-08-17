package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.CommandRecord;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.execution.StepExecutor;
import com.intertec.autoops.core.repo.CommandRecordRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Ad-hoc command dispatch: one shell command run RIGHT NOW on the platform
 * runner (the same executor that powers job steps), synchronously, with the
 * captured output stored in history. Gated like any other mutation.
 */
@Service
public class CommandService {

    private static final Logger log = LoggerFactory.getLogger(CommandService.class);

    private final CommandRecordRepository commandRepository;
    private final SubscriptionGate gate;
    private final StepExecutor stepExecutor;
    private final ObjectMapper objectMapper;

    public CommandService(CommandRecordRepository commandRepository, SubscriptionGate gate,
                          StepExecutor stepExecutor, ObjectMapper objectMapper) {
        this.commandRepository = commandRepository;
        this.gate = gate;
        this.stepExecutor = stepExecutor;
        this.objectMapper = objectMapper;
    }

    @Transactional(readOnly = true)
    public List<CommandRecord> history(String tenantId) {
        return commandRepository.findTop100ByTenantIdOrderByCreatedAtDesc(tenantId);
    }

    @Transactional
    public CommandRecord dispatch(String tenantId, String actor, String accessToken,
                                  String command) {
        gate.requireActive(accessToken);
        if (command == null || command.isBlank()) {
            throw CoreException.badRequest("missing_command", "Nothing to run");
        }
        if (command.length() > 512) {
            throw CoreException.badRequest("command_too_long",
                    "Commands are capped at 512 characters — save longer ones as a job");
        }
        var raw = objectMapper.createObjectNode()
                .put("id", "command").put("label", "ad-hoc").put("value", command);
        long start = System.currentTimeMillis();
        // No project context: ad-hoc commands see only GLOBAL integrations,
        // never one dedicated to a particular project.
        StepExecutor.StepOutcome outcome = stepExecutor.execute(tenantId, null,
                new StepExecutor.RunStep(0, 1, "command", "ad-hoc", raw, 0));

        CommandRecord record = new CommandRecord();
        record.setTenantId(tenantId);
        record.setCommand(command);
        record.setDispatchedBy(actor);
        record.setStatus(outcome.success()
                ? CommandRecord.Status.SUCCEEDED : CommandRecord.Status.FAILED);
        record.setOutput(outcome.success() ? outcome.detail() : outcome.error()
                + (outcome.detail() != null ? "\n" + outcome.detail() : ""));
        record.setDurationMs(System.currentTimeMillis() - start);
        CommandRecord saved = commandRepository.save(record);
        log.info("Tenant {} dispatched command ({}ms, {})", tenantId,
                saved.getDurationMs(), saved.getStatus());
        return saved;
    }
}
