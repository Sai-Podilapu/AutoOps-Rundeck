package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.exception.PluginException;
import com.intertec.autoops.plugin.spi.NotificationPlugin;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.springframework.stereotype.Component;

import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Indexes every {@link NotificationPlugin} bean by its key at construction —
 * the same constructor-collection idiom job-service uses for {@code
 * StepRunner}. A new provider package is discovered automatically; nothing
 * here needs editing.
 *
 * <p>A duplicate key fails startup rather than letting one plugin silently
 * shadow another: two beans claiming {@code "slack"} would make which one
 * receives a tenant's credentials depend on classpath order.
 */
@Component
public class PluginRegistry {

    private final Map<String, NotificationPlugin> byKey = new LinkedHashMap<>();

    public PluginRegistry(List<NotificationPlugin> plugins) {
        plugins.stream()
                .sorted(Comparator.comparing(p -> p.descriptor().displayName()))
                .forEach(plugin -> {
                    NotificationPlugin existing = byKey.putIfAbsent(plugin.key(), plugin);
                    if (existing != null) {
                        throw new IllegalStateException("Duplicate notification plugin key '"
                                + plugin.key() + "': " + existing.getClass().getName()
                                + " and " + plugin.getClass().getName());
                    }
                });
    }

    /** The catalog, alphabetical by display name. */
    public List<PluginDescriptor> catalog() {
        return byKey.values().stream().map(NotificationPlugin::descriptor).toList();
    }

    public NotificationPlugin require(String key) {
        NotificationPlugin plugin = byKey.get(key);
        if (plugin == null) {
            throw PluginException.notFound("unknown_plugin",
                    "No notification plugin named '" + key + "'");
        }
        return plugin;
    }

    public PluginDescriptor descriptor(String key) {
        return require(key).descriptor();
    }

    public boolean exists(String key) {
        return byKey.containsKey(key);
    }
}
