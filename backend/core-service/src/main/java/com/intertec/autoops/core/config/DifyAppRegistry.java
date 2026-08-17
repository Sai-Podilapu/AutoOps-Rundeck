package com.intertec.autoops.core.config;

import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.PropertySource;
import org.springframework.stereotype.Component;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Slug → Dify Service API key, for the workflows this platform can run.
 *
 * <p><b>Why a registry of per-workflow keys rather than one key.</b> Dify issues
 * two different credentials and they are not interchangeable. The workspace
 * console token ({@link DifyProperties#getApiKey()}) drives {@code /console/api}
 * — designing, publishing, model providers. Running a published workflow uses
 * the <b>Service API</b> under {@code /v1}, and Dify mints those keys
 * <b>per app</b>, in the form {@code app-…}. So "which workflows can AutoOps
 * run" is answered by "which app keys has the operator supplied", and that is
 * this map.
 *
 * <p><b>The key never leaves the server.</b> A library item stores only
 * {@code {"difyWorkflow":"<slug>"}}; the slug is resolved to a key here, at run
 * time. This matters concretely: the provider Library dialog renders an item's
 * {@code definition} into a {@code <pre>} in the browser, so a key stored in a
 * definition would be on screen and in the DOM.
 *
 * <p>Two supported spellings, because they solve different problems:
 * <ul>
 *   <li>{@code DIFY_WORKFLOW_KEYS=patch-tuesday=app-abc,offboarding=app-def} —
 *       one variable, so Compose and ECS task definitions need no edit when a
 *       workflow is added.</li>
 *   <li>{@code DIFY_WF_PATCH_TUESDAY=app-abc} — one variable per workflow, for
 *       secret managers that inject individually. The suffix lowercases and
 *       un-underscores into the slug.</li>
 * </ul>
 * Both feed one map. An empty map is a legitimate state, not an error: the
 * catalog is then honestly empty and says what to set.
 */
@Component
public class DifyAppRegistry {

    private static final Logger log = LoggerFactory.getLogger(DifyAppRegistry.class);

    /** One variable per workflow. Suffix becomes the slug. */
    private static final String PER_WORKFLOW_PREFIX = "DIFY_WF_";

    /** One variable for all of them, comma-separated {@code slug=key} pairs. */
    private static final String COMBINED_VAR = "DIFY_WORKFLOW_KEYS";

    private final ConfigurableEnvironment environment;
    private final Map<String, String> keysBySlug = new LinkedHashMap<>();

    public DifyAppRegistry(ConfigurableEnvironment environment) {
        this.environment = environment;
    }

    @PostConstruct
    void load() {
        keysBySlug.clear();
        // Combined first so an individually-injected key wins on a clash — a
        // secret manager's value is the more deliberate of the two.
        parseCombined(environment.getProperty(COMBINED_VAR));
        scanPerWorkflowVars();
        if (keysBySlug.isEmpty()) {
            log.info("No Dify workflow keys configured — set {} or {}<SLUG> to make "
                    + "workflows runnable", COMBINED_VAR, PER_WORKFLOW_PREFIX);
        } else {
            // Slugs only. Logging a key, even truncated, puts it in log storage.
            log.info("Dify workflow keys loaded for {}", keysBySlug.keySet());
        }
    }

    private void parseCombined(String raw) {
        if (raw == null || raw.isBlank()) {
            return;
        }
        for (String pair : raw.split(",")) {
            int eq = pair.indexOf('=');
            if (eq <= 0) {
                log.warn("Ignoring malformed entry in {} — expected slug=app-key", COMBINED_VAR);
                continue;
            }
            put(pair.substring(0, eq), pair.substring(eq + 1));
        }
    }

    /**
     * Arbitrary variable names cannot be bound to a @ConfigurationProperties
     * map, so the system-environment property source is walked directly. Only
     * that source is read: scanning every source would pick up unrelated
     * properties that merely start with the same letters.
     */
    private void scanPerWorkflowVars() {
        for (PropertySource<?> source : environment.getPropertySources()) {
            if (!(source instanceof EnumerablePropertySource<?> enumerable)) {
                continue;
            }
            if (!source.getName().contains("systemEnvironment")) {
                continue;
            }
            for (String name : enumerable.getPropertyNames()) {
                if (!name.toUpperCase(Locale.ROOT).startsWith(PER_WORKFLOW_PREFIX)) {
                    continue;
                }
                Object value = enumerable.getProperty(name);
                put(slugOf(name.substring(PER_WORKFLOW_PREFIX.length())),
                        value == null ? null : value.toString());
            }
        }
    }

    private void put(String slug, String key) {
        String cleanSlug = slugOf(slug);
        String cleanKey = key == null ? "" : key.trim();
        if (cleanSlug.isEmpty() || cleanKey.isEmpty()) {
            return;
        }
        keysBySlug.put(cleanSlug, cleanKey);
    }

    /** {@code PATCH_TUESDAY} and {@code Patch Tuesday} both become patch-tuesday. */
    static String slugOf(String raw) {
        if (raw == null) {
            return "";
        }
        return raw.trim().toLowerCase(Locale.ROOT)
                .replaceAll("[^a-z0-9]+", "-")
                .replaceAll("^-|-$", "");
    }

    public boolean isEmpty() {
        return keysBySlug.isEmpty();
    }

    public Set<String> slugs() {
        return Collections.unmodifiableSet(keysBySlug.keySet());
    }

    /** Empty when the slug is unknown — callers decide whether that is a 404. */
    public Optional<String> keyFor(String slug) {
        return Optional.ofNullable(keysBySlug.get(slugOf(slug)));
    }
}
