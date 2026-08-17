package com.intertec.autoops.plugin.service;

import com.intertec.autoops.plugin.exception.PluginException;
import com.intertec.autoops.plugin.spi.ConfigField;
import com.intertec.autoops.plugin.spi.PluginDescriptor;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * The catalog is assembled from whatever {@code NotificationPlugin} beans are
 * on the classpath, so this doubles as the check that every provider package
 * is actually wired.
 */
@SpringBootTest
class PluginRegistryTest {

    @Autowired
    private PluginRegistry registry;

    @Test
    void everyProviderPackageIsRegistered() {
        assertThat(registry.catalog())
                .extracting(PluginDescriptor::key)
                .containsExactlyInAnyOrder(
                        "slack", "microsoft-teams", "outlook", "gmail", "github", "webhook");
    }

    @Test
    void anUnknownKeyIsRejectedRatherThanReturningNull() {
        assertThatThrownBy(() -> registry.require("nope"))
                .isInstanceOf(PluginException.class)
                .hasMessageContaining("No notification plugin named");
    }

    /**
     * Every plugin has to declare at least one secret. One that stored nothing
     * sensitive would mean its credential was living in a plain column.
     */
    @Test
    void everyPluginDeclaresAtLeastOneSecretField() {
        for (PluginDescriptor descriptor : registry.catalog()) {
            assertThat(descriptor.secretFieldNames())
                    .as("%s must mark its credential as SECRET", descriptor.key())
                    .isNotEmpty();
        }
    }

    /** The console renders the install form from these; a blank label is a bug. */
    @Test
    void everyConfigFieldIsRenderable() {
        for (PluginDescriptor descriptor : registry.catalog()) {
            assertThat(descriptor.fields()).isNotEmpty();
            for (ConfigField field : descriptor.fields()) {
                assertThat(field.name()).as("field name in %s", descriptor.key()).isNotBlank();
                assertThat(field.label()).as("field label in %s", descriptor.key()).isNotBlank();
                assertThat(field.type()).as("field type in %s", descriptor.key()).isNotNull();
            }
        }
    }
}
