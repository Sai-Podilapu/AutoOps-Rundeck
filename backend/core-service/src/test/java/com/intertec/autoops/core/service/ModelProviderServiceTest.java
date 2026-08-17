package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.intertec.autoops.core.client.EntitlementClient;
import com.intertec.autoops.core.domain.ModelDeployment;
import com.intertec.autoops.core.domain.ModelProvider;
import com.intertec.autoops.core.exception.CoreException;
import com.intertec.autoops.core.repo.ModelDeploymentRepository;
import com.intertec.autoops.core.repo.ModelProviderRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Named connections and declared models, against H2 with real commit
 * semantics.
 *
 * <p>The probe is mocked at its own boundary: what is under test here is how
 * connections are keyed and how declared models merge with probed ones, none
 * of which should require a network call to a vendor.
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import({ModelProviderService.class, CredentialCrypto.class, SubscriptionGate.class})
@Transactional(propagation = Propagation.NOT_SUPPORTED)
class ModelProviderServiceTest {

    private static final String TENANT = "acme-corp-cafe0123";
    private static final String ACTOR = "admin@acme.io";
    private static final String TOKEN = "test-access-token";

    private static final EntitlementClient.Decision OK =
            new EntitlementClient.Decision(true, "ok", null, null);

    @Autowired
    private ModelProviderService service;
    @Autowired
    private ModelProviderRepository providerRepository;
    @Autowired
    private ModelDeploymentRepository deploymentRepository;
    @MockBean
    private EntitlementClient entitlementClient;
    @MockBean
    private ModelProviderProbe probe;

    @TestConfiguration
    static class TestConfig {
        @Bean
        ObjectMapper objectMapper() {
            return new ObjectMapper();
        }

        @Bean
        com.intertec.autoops.core.config.CoreProperties coreProperties() {
            return new com.intertec.autoops.core.config.CoreProperties();
        }
    }

    @BeforeEach
    void resetState() {
        deploymentRepository.deleteAll();
        providerRepository.deleteAll();
        when(entitlementClient.checkActive(any())).thenReturn(OK);
        when(entitlementClient.checkQuota(any(), any(), anyLong())).thenReturn(OK);
    }

    private ModelProvider openAi(String name) {
        return service.save(TENANT, ACTOR, TOKEN, null, "OPENAI", name, null,
                "{\"apiKey\":\"sk-test\"}", null, null, null);
    }

    // ------ preflight verify ------

    @Test
    void verifyStoresNothingWhateverTheVendorSays() {
        when(probe.probe(any(), any(), any())).thenReturn(
                new ModelProviderProbe.ProbeResult(false, "Invalid API key", List.of()));

        var rejected = service.verify(TOKEN, "OPENAI", null, "{\"apiKey\":\"sk-wrong\"}", null);

        assertThat(rejected.ok()).isFalse();
        assertThat(providerRepository.findByTenantIdOrderByCreatedAtDesc(TENANT))
                .as("a rejected key must not leave a connection behind")
                .isEmpty();

        when(probe.probe(any(), any(), any())).thenReturn(
                new ModelProviderProbe.ProbeResult(true, "12 models", List.of("gpt-4o")));

        var accepted = service.verify(TOKEN, "OPENAI", null, "{\"apiKey\":\"sk-right\"}", null);

        assertThat(accepted.ok()).isTrue();
        assertThat(accepted.models()).containsExactly("gpt-4o");
        assertThat(providerRepository.findByTenantIdOrderByCreatedAtDesc(TENANT))
                .as("accepting is still not saving — the caller saves next")
                .isEmpty();
    }

    @Test
    void verifyReportsAMissingFieldAsSuchRatherThanAskingTheVendor() {
        // Azure needs an endpoint. Sending an incomplete config to the vendor
        // would come back as a connection error and read like a bad key.
        assertThatThrownBy(() ->
                service.verify(TOKEN, "AZURE_OPENAI", null, "{\"apiKey\":\"k\"}", null))
                .isInstanceOf(CoreException.class);

        verifyNoInteractions(probe);
    }

    @Test
    void verifyChecksTheChosenAuthMethodNotTheUnionOfAllOfThem() {
        when(probe.probe(any(), any(), any())).thenReturn(
                new ModelProviderProbe.ProbeResult(true, "ok", List.of()));

        // An Entra ID connection legitimately carries no apiKey.
        var result = service.verify(TOKEN, "AZURE_OPENAI", "ENTRA_ID",
                "{\"endpoint\":\"https://r.openai.azure.com\",\"azureTenantId\":\"t\","
                        + "\"clientId\":\"c\",\"clientSecret\":\"s\"}", null);

        assertThat(result.ok()).isTrue();
    }

    // ------ named connections ------

    @Test
    void aVendorCanHoldMoreThanOneConnection() {
        // The point of the change: production and sandbox keys for the same
        // vendor, each with its own credential and its own test outcome.
        ModelProvider prod = openAi("Production");
        ModelProvider sandbox = openAi("Sandbox");

        assertThat(prod.getId()).isNotEqualTo(sandbox.getId());
        assertThat(providerRepository.findByTenantIdOrderByCreatedAtDesc(TENANT))
                .extracting(ModelProvider::getName)
                .containsExactlyInAnyOrder("Production", "Sandbox");
    }

    @Test
    void creatingWithATakenNameIsRefusedRatherThanOverwriting() {
        openAi("Production");

        // Silently replacing would destroy a working credential on what the
        // operator meant as "add a second one".
        assertThatThrownBy(() -> openAi("Production"))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("already has")
                .hasMessageContaining("Production");
    }

    @Test
    void replacingByIdKeepsTheRowAndClearsTheOldTestResult() {
        ModelProvider first = openAi("Production");
        first.setLastTestOk(true);
        first.setLastTestNote("OpenAI accepted the credential");
        providerRepository.save(first);

        ModelProvider replaced = service.save(TENANT, ACTOR, TOKEN, first.getId(), "OPENAI",
                "Production", null, "{\"apiKey\":\"sk-rotated\"}", null, null, null);

        assertThat(replaced.getId()).isEqualTo(first.getId());
        // A rotated key inherits nothing: it is unproven until tested.
        assertThat(replaced.getLastTestOk()).isNull();
        assertThat(replaced.getLastTestNote()).isNull();
    }

    @Test
    void aConnectionCannotBeRepointedAtAnotherVendor() {
        // The stored config shape belongs to the kind; changing one without
        // the other would leave a row whose credential cannot be read.
        ModelProvider openai = openAi("Production");

        assertThatThrownBy(() -> service.save(TENANT, ACTOR, TOKEN, openai.getId(), "GROQ",
                "Production", null, "{\"apiKey\":\"gsk_x\"}", null, null, null))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("OPENAI");
    }

    // ------ auth methods ------

    @Test
    void azureAcceptsEitherCredentialShapeButNotAMixture() {
        assertThatCode(() -> service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Key auth", null,
                "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null))
                .doesNotThrowAnyException();

        assertThatCode(() -> service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Entra auth", "ENTRA_ID",
                "{\"endpoint\":\"https://r.openai.azure.com\",\"azureTenantId\":\"t\","
                        + "\"clientId\":\"c\",\"clientSecret\":\"s\"}",
                null, null, null))
                .doesNotThrowAnyException();

        // An Entra connection carrying only an API key is rejected, naming the
        // first field that method actually needs — an API key is not one of
        // them, so it cannot stand in for the service principal.
        assertThatThrownBy(() -> service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Broken", "ENTRA_ID",
                "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("azureTenantId");
    }

    @Test
    void anUnknownAuthMethodIsRejectedByName() {
        assertThatThrownBy(() -> service.save(TENANT, ACTOR, TOKEN, null, "OPENAI",
                "Odd", "KERBEROS", "{\"apiKey\":\"sk-test\"}", null, null, null))
                .isInstanceOf(CoreException.class)
                .hasMessageContaining("KERBEROS");
    }

    // ------ declared models ------

    @Test
    void aDeclaredModelCarriesThePurposeItsOperatorChose() {
        // No naming rule can tell that "prod-embed-v2" embeds — the classifier
        // would file an Azure deployment name under CHAT and offer it as a
        // brain. The person who created the deployment knows, so they say.
        ModelProvider azure = service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Azure", null, "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null);

        service.saveDeployment(TENANT, ACTOR, TOKEN, azure.getId(), null, "prod-embed-v2",
                "text-embedding-3-large", "EMBEDDING", "2024-10-21", null);

        var available = service.availableModels(TENANT).stream()
                .filter(a -> a.providerId().equals(azure.getId()))
                .findFirst()
                .orElseThrow();

        assertThat(available.declaredModels()).containsExactly("prod-embed-v2");
        assertThat(available.modelsByPurpose().get("EMBEDDING")).contains("prod-embed-v2");
        assertThat(available.modelsByPurpose().getOrDefault("CHAT", List.of()))
                .doesNotContain("prod-embed-v2");
    }

    @Test
    void declaredModelsCountAsAListEvenBeforeAnyTest() {
        // A declared model is something the tenant deployed and named. The
        // console must not caption it "likely models" as though it were the
        // catalog's guess at what this vendor might serve.
        ModelProvider azure = service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Azure", null, "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null);
        service.saveDeployment(TENANT, ACTOR, TOKEN, azure.getId(), null, "gpt4o-prod",
                "gpt-4o", "CHAT", null, null);

        var available = service.availableModels(TENANT).get(0);
        assertThat(available.verified()).isTrue();
        // Declared first: the tenant's own deployments outrank catalog guesses.
        assertThat(available.models()).startsWith("gpt4o-prod");
    }

    @Test
    void redeclaringTheSameModelUpdatesItRatherThanDuplicating() {
        ModelProvider azure = service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Azure", null, "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null);

        service.saveDeployment(TENANT, ACTOR, TOKEN, azure.getId(), null, "gpt4o-prod",
                "gpt-4o", "CHAT", null, null);
        service.saveDeployment(TENANT, ACTOR, TOKEN, azure.getId(), null, "gpt4o-prod",
                "gpt-4o-mini", "CHAT", "2025-01-01", null);

        List<ModelDeployment> declared = service.deployments(TENANT, azure.getId());
        assertThat(declared).singleElement().satisfies(d -> {
            assertThat(d.getBaseModel()).isEqualTo("gpt-4o-mini");
            assertThat(d.getApiVersion()).isEqualTo("2025-01-01");
        });
    }

    @Test
    void removingAConnectionRemovesWhatWasDeclaredAgainstIt() {
        // A model with no way to authenticate is not callable by anything, so
        // leaving it behind would put a dead entry in every picker.
        ModelProvider azure = service.save(TENANT, ACTOR, TOKEN, null, "AZURE_OPENAI",
                "Azure", null, "{\"endpoint\":\"https://r.openai.azure.com\",\"apiKey\":\"k\"}",
                null, null, null);
        service.saveDeployment(TENANT, ACTOR, TOKEN, azure.getId(), null, "gpt4o-prod",
                null, "CHAT", null, null);

        service.delete(TENANT, TOKEN, azure.getId());

        assertThat(deploymentRepository.findByTenantId(TENANT)).isEmpty();
    }

    @Test
    void anotherTenantsConnectionIsNotVisibleOrWritable() {
        ModelProvider mine = openAi("Production");

        assertThatThrownBy(() -> service.deployments("rival-inc-beef4567", mine.getId()))
                .isInstanceOf(CoreException.class);
        assertThatThrownBy(() -> service.saveDeployment("rival-inc-beef4567", ACTOR, TOKEN,
                mine.getId(), null, "sneaky", null, "CHAT", null, null))
                .isInstanceOf(CoreException.class);
    }

    // ------ per-purpose defaults ------

    @Test
    void defaultsChangeWithoutRepastingTheCredential() {
        // The console never receives the secret back, so requiring it in order
        // to change which model chat points at would make the change impossible.
        ModelProvider provider = openAi("Production");
        String encrypted = provider.getConfigEnc();

        ModelProvider updated = service.setDefaults(TENANT, TOKEN, provider.getId(),
                "gpt-4o", "text-embedding-3-large", null);

        assertThat(updated.getDefaultModel()).isEqualTo("gpt-4o");
        assertThat(updated.getDefaultEmbeddingModel()).isEqualTo("text-embedding-3-large");
        assertThat(updated.getDefaultRerankModel()).isNull();
        assertThat(updated.getConfigEnc()).isEqualTo(encrypted);
    }
}
