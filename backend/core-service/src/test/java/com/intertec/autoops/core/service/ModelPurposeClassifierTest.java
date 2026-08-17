package com.intertec.autoops.core.service;

import com.intertec.autoops.core.domain.ModelProvider.Kind;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The ids here are REAL — taken from what AWS, OpenAI and Ollama actually
 * returned to a probe, not invented. That matters: this classifier reads
 * naming conventions, so a test built from imagined names would only prove the
 * conventions we imagined.
 */
class ModelPurposeClassifierTest {

    @Test
    void separatesTheFourFamiliesBedrockReturnsInOneList() {
        // Verbatim from a live ListFoundationModels reply (119 ids).
        assertThat(ModelPurposeClassifier.classify("anthropic.claude-sonnet-4-20250514-v1:0"))
                .isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify("amazon.nova-2-multimodal-embeddings-v1:0"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("twelvelabs.marengo-embed-3-0-v1:0"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("cohere.rerank-v3-5:0"))
                .isEqualTo(ModelPurpose.RERANK);
        assertThat(ModelPurposeClassifier.classify("stability.stable-image-remove-background-v1:0"))
                .isEqualTo(ModelPurpose.IMAGE);
        assertThat(ModelPurposeClassifier.classify("stability.stable-creative-upscale-v1:0"))
                .isEqualTo(ModelPurpose.IMAGE);
        assertThat(ModelPurposeClassifier.classify("amazon.nova-reel-v1:0"))
                .isEqualTo(ModelPurpose.VIDEO);
    }

    @Test
    void readsTheOtherVendorsConventionsToo() {
        assertThat(ModelPurposeClassifier.classify("text-embedding-3-large"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("gemini-embedding-001"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("mistral-embed"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("nomic-embed-text"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("dall-e-3")).isEqualTo(ModelPurpose.IMAGE);
        assertThat(ModelPurposeClassifier.classify("whisper-1")).isEqualTo(ModelPurpose.AUDIO);
        assertThat(ModelPurposeClassifier.classify("gpt-4o-mini-tts"))
                .isEqualTo(ModelPurpose.AUDIO);
    }

    @Test
    void doesNotStealChatModelsThatMerelyMentionAModality() {
        // gpt-4o-audio-preview HEARS, but it is a chat model — a rule matching
        // a bare "audio" would quietly remove it from the chat picker.
        assertThat(ModelPurposeClassifier.classify("gpt-4o-audio-preview"))
                .isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify("gpt-4o-realtime-preview"))
                .isEqualTo(ModelPurpose.CHAT);
    }

    @Test
    void treatsAnUnknownIdAsChatSoNothingDisappears() {
        // The conventions are strong but they are still conventions. An id
        // this classifier has never seen must keep showing up where it shows
        // up today, rather than vanishing from every picker.
        assertThat(ModelPurposeClassifier.classify("qwen.qwen3-coder-next"))
                .isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify("some-vendor.brand-new-thing-v9"))
                .isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify(null)).isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify("  ")).isEqualTo(ModelPurpose.CHAT);
    }

    @Test
    void groupsWhileKeepingTheVendorsOwnOrder() {
        Map<String, List<String>> grouped = ModelPurposeClassifier.groupByPurpose(List.of(
                "gpt-5", "text-embedding-3-large", "gpt-4o", "dall-e-3",
                "text-embedding-3-small"));

        assertThat(grouped.get("CHAT")).containsExactly("gpt-5", "gpt-4o");
        assertThat(grouped.get("EMBEDDING"))
                .containsExactly("text-embedding-3-large", "text-embedding-3-small");
        assertThat(grouped.get("IMAGE")).containsExactly("dall-e-3");
        // Absent, not empty: the console shows "this vendor lists none".
        assertThat(grouped).doesNotContainKey("RERANK");
    }

    @Test
    void filteringToOneBucketMatchesTheGrouping() {
        List<String> models = List.of("gpt-5", "text-embedding-3-large", "dall-e-3");
        assertThat(ModelPurposeClassifier.of(models, ModelPurpose.EMBEDDING))
                .containsExactly("text-embedding-3-large");
        assertThat(ModelPurposeClassifier.of(models, ModelPurpose.CHAT))
                .containsExactly("gpt-5");
        assertThat(ModelPurposeClassifier.of(null, ModelPurpose.CHAT)).isEmpty();
    }

    @Test
    void everyCatalogVendorOffersSomethingToChatWith() {
        // A vendor whose suggestions all classified as non-chat would render an
        // empty default-model picker — the regression this guards against.
        for (var spec : ModelProviderCatalog.all()) {
            if (spec.fallbackModels().isEmpty()) {
                continue; // SageMaker: the tenant's endpoints, nothing to suggest
            }
            if (spec.kind() == Kind.ELEVENLABS) {
                continue; // speech only, and genuinely has nothing to chat with
            }
            assertThat(spec.fallbackModelsByPurpose().get(ModelPurpose.CHAT.name()))
                    .as("%s has no chat model to suggest", spec.kind())
                    .isNotEmpty();
        }
    }

    @Test
    void aVoiceVendorsModelsAreNeverOfferedAsSomethingToChatWith() {
        // ElevenLabs ids announce nothing — "eleven_turbo_v2_5" and
        // "scribe_v1" read like any other model. Reading the name alone would
        // file them under CHAT and hand an agent a text-to-speech model as its
        // brain, so the vendor decides here.
        assertThat(ModelPurposeClassifier.classify(Kind.ELEVENLABS, "eleven_turbo_v2_5"))
                .isEqualTo(ModelPurpose.AUDIO);
        assertThat(ModelPurposeClassifier.classify(Kind.ELEVENLABS, "scribe_v1"))
                .isEqualTo(ModelPurpose.AUDIO);
        assertThat(ModelProviderCatalog.spec(Kind.ELEVENLABS).fallbackModelsByPurpose())
                .containsOnlyKeys(ModelPurpose.AUDIO.name());
    }

    @Test
    void readsTheHubsEmbeddingFamiliesThatNeverSayEmbed() {
        assertThat(ModelPurposeClassifier.classify("sentence-transformers/all-MiniLM-L6-v2"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        assertThat(ModelPurposeClassifier.classify("BAAI/bge-m3"))
                .isEqualTo(ModelPurpose.EMBEDDING);
        // A vendor-prefixed id still classifies on the model part.
        assertThat(ModelPurposeClassifier.classify("openai/gpt-4o"))
                .isEqualTo(ModelPurpose.CHAT);
        assertThat(ModelPurposeClassifier.classify("openai/text-embedding-3-large"))
                .isEqualTo(ModelPurpose.EMBEDDING);
    }
}
