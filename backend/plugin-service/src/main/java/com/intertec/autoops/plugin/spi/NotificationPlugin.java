package com.intertec.autoops.plugin.spi;

/**
 * A notification transport. One implementation per third party, each in its
 * own package under {@code provider/} — see {@code provider/slack},
 * {@code provider/teams}, {@code provider/outlook}, {@code provider/gmail},
 * {@code provider/github}.
 *
 * <p>Implementations are plain Spring beans; {@code PluginRegistry} collects
 * them all at construction and indexes them by {@link PluginDescriptor#key()},
 * the same way job-service's {@code StepExecutionService} indexes its
 * {@code StepRunner}s. Adding a channel means adding a package and a bean —
 * no registry edit, no frontend change, no migration.
 *
 * <p><b>Contract for implementors</b>
 * <ul>
 *   <li>Never throw. Every failure path returns a {@link DeliveryResult};
 *       an escaped exception would abort the fan-out and rob the tenant's
 *       other channels of the same event.</li>
 *   <li>Never log a config value. The map holds webhook URLs, API tokens and
 *       SMTP passwords, all of which are credentials in their own right.</li>
 *   <li>Be honest about {@code retryable}. See {@link DeliveryResult}.</li>
 *   <li>{@link #verify} must make a real call to the third party. A test
 *       button that returns green without touching the network tells the
 *       tenant nothing.</li>
 * </ul>
 */
public interface NotificationPlugin {

    /** Catalog entry: identity, category and the install form. */
    PluginDescriptor descriptor();

    /** Stable identifier used in URLs, the DB and rule bindings. */
    default String key() {
        return descriptor().key();
    }

    /** Deliver one lifecycle event through this transport. */
    DeliveryResult send(PluginContext context, NotificationMessage message);

    /**
     * Prove the stored credentials still work, without sending a notification
     * anyone would mistake for a real alert. Called on install and by the
     * console's "Test connection" button.
     */
    DeliveryResult verify(PluginContext context);
}
