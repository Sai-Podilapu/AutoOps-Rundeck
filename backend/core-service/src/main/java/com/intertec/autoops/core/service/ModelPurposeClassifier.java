package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.ModelProvider.Kind;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Sorts a vendor's model ids into what each one is for.
 *
 * <p>The classification is by NAMING CONVENTION, because that is the only
 * signal every vendor gives us: OpenAI's {@code /v1/models} and Ollama's
 * {@code /api/tags} return bare ids and nothing else. The conventions are
 * strong and stable — a model that embeds says {@code embed} in its name at
 * every vendor we support — but they are still conventions, so this errs
 * toward {@link ModelPurpose#CHAT}: an unrecognised id keeps appearing in the
 * picker it appears in today, and only ids that clearly announce another
 * purpose are moved out of it.
 *
 * <p>AWS is the one vendor that could be authoritative here — its
 * {@code ListFoundationModels} reply carries {@code outputModalities} per
 * model — but the probe caches ids only. Capturing modalities would mean
 * changing that cache's shape for one vendor out of eleven; worth doing when a
 * second vendor makes it worthwhile, not before.
 */
public final class ModelPurposeClassifier {

    private ModelPurposeClassifier() {
    }

    /**
     * Ordered: the first match wins, so the narrow signals are checked before
     * the broad ones. {@code rerank} precedes {@code embed} because a reranker
     * is often described as an embedding-family model, and
     * {@code multimodal-embeddings} must land on EMBEDDING rather than IMAGE.
     */
    private static final List<Rule> RULES = List.of(
            new Rule(ModelPurpose.RERANK, "rerank"),
            // "sentence-transformers/…" and "BAAI/bge-…" are the two embedding
            // families on the Hub whose names never say "embed".
            new Rule(ModelPurpose.EMBEDDING, "embed", "sentence-transformers", "bge-"),
            // Narrow on purpose: a bare "audio" or "voice" would swallow
            // gpt-4o-audio-preview, which is a CHAT model that hears.
            new Rule(ModelPurpose.AUDIO, "whisper", "tts-", "-tts", "transcribe",
                    "text-to-speech", "speech-to-text"),
            new Rule(ModelPurpose.VIDEO, "video", "reel", "veo-", "-veo", "sora", "ray-"),
            new Rule(ModelPurpose.IMAGE, "image", "stable-diffusion", "stability.",
                    "canvas", "dall-e", "imagen", "flux", "upscale", "background"));

    private record Rule(ModelPurpose purpose, String... fragments) {
    }

    public static ModelPurpose classify(String modelId) {
        return classify(null, modelId);
    }

    /**
     * With the vendor known, some ids need no reading at all: everything
     * ElevenLabs publishes is speech, and its names ({@code eleven_turbo_v2_5},
     * {@code scribe_v1}) announce nothing. Naming rules alone would file them
     * under CHAT and offer a text-to-speech model as an agent's brain.
     *
     * @param kind the vendor, or null when it is not known
     */
    public static ModelPurpose classify(Kind kind, String modelId) {
        if (kind == Kind.ELEVENLABS) {
            return ModelPurpose.AUDIO;
        }
        if (modelId == null || modelId.isBlank()) {
            return ModelPurpose.CHAT;
        }
        String id = modelId.toLowerCase(Locale.ROOT);
        for (Rule rule : RULES) {
            for (String fragment : rule.fragments()) {
                if (id.contains(fragment)) {
                    return rule.purpose();
                }
            }
        }
        return ModelPurpose.CHAT;
    }

    /**
     * The same list, split by purpose and keyed by name so it crosses the wire
     * as plain JSON. Vendor order is preserved inside each bucket, and a
     * purpose with no models is simply absent — the console needs to say
     * "this vendor has none", and an empty array says that honestly.
     */
    public static Map<String, List<String>> groupByPurpose(List<String> modelIds) {
        return groupByPurpose(null, modelIds);
    }

    public static Map<String, List<String>> groupByPurpose(Kind kind, List<String> modelIds) {
        Map<String, List<String>> grouped = new LinkedHashMap<>();
        if (modelIds == null) {
            return grouped;
        }
        for (String id : modelIds) {
            if (id == null || id.isBlank()) {
                continue;
            }
            grouped.computeIfAbsent(classify(kind, id).name(), k -> new ArrayList<>()).add(id);
        }
        grouped.replaceAll((purpose, ids) -> List.copyOf(ids));
        return Map.copyOf(grouped);
    }

    /** Just one bucket — what the console's per-purpose pickers ask for. */
    public static List<String> of(List<String> modelIds, ModelPurpose purpose) {
        return of(null, modelIds, purpose);
    }

    public static List<String> of(Kind kind, List<String> modelIds, ModelPurpose purpose) {
        if (modelIds == null) {
            return List.of();
        }
        return modelIds.stream()
                .filter(id -> id != null && !id.isBlank())
                .filter(id -> classify(kind, id) == purpose)
                .toList();
    }
}
