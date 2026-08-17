package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.domain.ModelProvider.Kind;
import com.intertec.autoops.core.exception.CoreException;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * The catalog is the single place the vendors' disagreement about "what is a
 * credential" is written down, so the thing worth testing is that it stays in
 * step with the {@link Kind} enum and actually rejects incomplete input.
 *
 * <p>Deliberately Spring-free: these run without an application context.
 */
class ModelProviderCatalogTest {

    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void everyKindHasASpec() throws Exception {
        // A Kind added to the enum without a catalog entry would otherwise only
        // fail at runtime, on the request that tried to use it.
        for (Kind kind : Kind.values()) {
            assertThatCode(() -> ModelProviderCatalog.spec(kind)).doesNotThrowAnyException();
            assertThat(ModelProviderCatalog.spec(kind).displayName()).isNotBlank();
        }
        assertThat(ModelProviderCatalog.all()).hasSameSizeAs(Kind.values());
    }

    @Test
    void everyKindEitherSuggestsModelsOrSaysWhyItCannot() {
        for (Kind kind : Kind.values()) {
            var spec = ModelProviderCatalog.spec(kind);
            if (spec.fallbackModels().isEmpty()) {
                // SageMaker serves endpoints the tenant deployed and named, so
                // there is nothing honest to suggest and the picker becomes a
                // text box. Acceptable only if the form says where the name
                // comes from — otherwise it is just an unexplained blank.
                assertThat(spec.modelHint())
                        .as("%s suggests nothing and does not explain why", kind)
                        .isNotBlank();
            }
            if (spec.defaultModel() != null) {
                // A pre-selected model missing from the list would render as a
                // dropdown whose selection is not one of its options.
                assertThat(spec.fallbackModels())
                        .as("%s pre-selects a model it does not offer", kind)
                        .contains(spec.defaultModel());
            }
        }
    }

    @Test
    void tenantNamedModelsCarryAHintInsteadOfAPromise() {
        // Azure routes on deployment names and ModelArts on deployment ids —
        // both chosen by the tenant, so the suggestions cannot be pre-selected
        // as if we knew them.
        for (Kind kind : List.of(Kind.AZURE_OPENAI, Kind.HUAWEI, Kind.OLLAMA, Kind.SAGEMAKER)) {
            assertThat(ModelProviderCatalog.spec(kind).modelHint())
                    .as("%s should explain where its real model names come from", kind)
                    .isNotBlank();
        }
        assertThat(ModelProviderCatalog.spec(Kind.AZURE_OPENAI).defaultModel()).isNull();
        assertThat(ModelProviderCatalog.spec(Kind.HUAWEI).defaultModel()).isNull();
        assertThat(ModelProviderCatalog.spec(Kind.SAGEMAKER).defaultModel()).isNull();
    }

    @Test
    void regionsArePickedFromTheVendorsListNotTyped() {
        // A region code is exact and unmemorable, and getting it wrong fails
        // at probe time with a DNS error. Both signing vendors must offer the
        // list; nobody should be typing "ap-southeast-2" from memory.
        for (Kind kind : List.of(Kind.BEDROCK, Kind.HUAWEI)) {
            var region = ModelProviderCatalog.spec(kind).fields().stream()
                    .filter(f -> f.key().equals("region"))
                    .findFirst()
                    .orElseThrow();
            assertThat(region.options())
                    .as("%s should offer its regions", kind)
                    .isNotEmpty();
            assertThat(region.options()).allSatisfy(o -> {
                assertThat(o.value()).isNotBlank();
                // The label carries the human place name beside the code —
                // a bare code list is no more usable than a text box.
                assertThat(o.label()).isNotBlank().contains(o.value());
            });
            assertThat(region.options()).extracting(f -> f.value()).doesNotHaveDuplicates();
        }

        assertThat(ModelProviderCatalog.spec(Kind.BEDROCK).fields().stream()
                .filter(f -> f.key().equals("region")).findFirst().orElseThrow().options())
                .extracting(o -> o.value())
                .contains("us-east-1", "eu-west-1", "ap-southeast-2");
    }

    @Test
    void onlyClosedListFieldsCarryOptions() {
        // Options drive a dropdown. A secret or a free-form value that grew
        // one would render a picker over something unpickable.
        for (Kind kind : Kind.values()) {
            for (var field : ModelProviderCatalog.spec(kind).fields()) {
                if (!field.options().isEmpty()) {
                    assertThat(field.secret())
                            .as("%s.%s offers a list for a secret", kind, field.key())
                            .isFalse();
                    assertThat(field.key())
                            .as("%s.%s is not a closed-list field", kind, field.key())
                            .isEqualTo("region");
                }
            }
        }
    }

    @Test
    void everyRequiredFieldIsEnforced() throws Exception {
        // Empty config: each vendor must complain about its own first field.
        for (Kind kind : Kind.values()) {
            var spec = ModelProviderCatalog.spec(kind);
            boolean hasRequired = spec.fields().stream().anyMatch(f -> f.required());
            if (!hasRequired) {
                continue;
            }
            assertThatThrownBy(() ->
                    ModelProviderCatalog.validateConfig(kind, mapper.readTree("{}")))
                    .isInstanceOf(CoreException.class)
                    .hasMessageContaining(spec.displayName());
        }
    }

    @Test
    void bearerVendorAcceptsJustAnApiKey() throws Exception {
        assertThatCode(() -> ModelProviderCatalog.validateConfig(Kind.OPENAI,
                mapper.readTree("{\"apiKey\":\"sk-test\"}")))
                .doesNotThrowAnyException();
    }

    @Test
    void multiFieldVendorNeedsAllOfThem() throws Exception {
        // Huawei is the awkward one: AK/SK plus region plus project id.
        assertThatThrownBy(() -> ModelProviderCatalog.validateConfig(Kind.HUAWEI,
                mapper.readTree("{\"region\":\"cn-north-4\",\"accessKey\":\"a\"}")))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("projectId");

        assertThatCode(() -> ModelProviderCatalog.validateConfig(Kind.HUAWEI, mapper.readTree(
                "{\"region\":\"cn-north-4\",\"projectId\":\"p\",\"accessKey\":\"a\",\"secretKey\":\"s\"}")))
                .doesNotThrowAnyException();
    }

    @Test
    void selfHostedNeedsAUrlNotASecret() throws Exception {
        // Ollama's required field is a URL, and a bare host is not one — a
        // value like "localhost:11434" would fail much later, at connect time.
        assertThatThrownBy(() -> ModelProviderCatalog.validateConfig(Kind.OLLAMA,
                mapper.readTree("{\"baseUrl\":\"localhost:11434\"}")))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("http");

        assertThatCode(() -> ModelProviderCatalog.validateConfig(Kind.OLLAMA,
                mapper.readTree("{\"baseUrl\":\"http://localhost:11434\"}")))
                .doesNotThrowAnyException();
    }

    @Test
    void kindParsingAcceptsWhatTheConsoleSends() {
        assertThat(ModelProviderCatalog.parseKind("openai")).isEqualTo(Kind.OPENAI);
        assertThat(ModelProviderCatalog.parseKind("azure-openai")).isEqualTo(Kind.AZURE_OPENAI);
        assertThat(ModelProviderCatalog.parseKind(" AZURE_OPENAI ")).isEqualTo(Kind.AZURE_OPENAI);
        assertThatThrownBy(() -> ModelProviderCatalog.parseKind("not-a-vendor"))
                .isInstanceOf(CoreException.class);
        assertThatThrownBy(() -> ModelProviderCatalog.parseKind(null))
                .isInstanceOf(CoreException.class);
    }

    @Test
    void secretFieldsAreMarkedSecret() {
        // Drives type="password" in the console. A field mis-marked here would
        // render an API key in cleartext.
        assertThat(ModelProviderCatalog.spec(Kind.OPENAI).fields())
                .allSatisfy(f -> assertThat(f.secret()).isTrue());
        assertThat(ModelProviderCatalog.spec(Kind.BEDROCK).fields())
                .filteredOn(f -> f.key().equals("secretAccessKey"))
                .singleElement()
                .satisfies(f -> assertThat(f.secret()).isTrue());
        // ...but the region is not a secret and must not be masked.
        assertThat(ModelProviderCatalog.spec(Kind.BEDROCK).fields())
                .filteredOn(f -> f.key().equals("region"))
                .singleElement()
                .satisfies(f -> assertThat(f.secret()).isFalse());
    }
}
