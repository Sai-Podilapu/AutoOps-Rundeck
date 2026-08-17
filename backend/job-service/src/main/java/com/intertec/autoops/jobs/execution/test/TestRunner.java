package com.intertec.autoops.jobs.execution.test;

import com.intertec.autoops.jobs.execution.StepRunner;
import org.springframework.stereotype.Component;

import java.util.Set;

/** The palette's "Test Node": always succeeds, echoing its value if any. */
@Component
public class TestRunner implements StepRunner {

    @Override
    public Set<String> types() {
        return Set.of("test");
    }

    @Override
    public StepResult run(StepCommand command) {
        String note = command.value() == null || command.value().isBlank()
                ? "test step ok" : command.value();
        return StepResult.ok(note, 0);
    }
}
