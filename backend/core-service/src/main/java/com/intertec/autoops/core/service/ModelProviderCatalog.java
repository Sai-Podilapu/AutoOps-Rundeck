package com.intertec.autoops.core.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.intertec.autoops.core.domain.ModelProvider.Kind;
import com.intertec.autoops.core.exception.CoreException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * What each AI vendor calls a credential, and what a working one looks like.
 *
 * <p>These vendors do not agree on any of it: most take a bearer token, Google
 * wants the key as a query parameter, Azure needs an endpoint and a deployment
 * name beside the key, Bedrock and Huawei want an access-key/secret-key pair
 * plus a region and sign every request, and Ollama has no secret at all — just
 * a URL. This class is the single place that difference is written down; the
 * probe and the console both read their behaviour from here rather than
 * re-deriving it.
 *
 * <p>Model lists are deliberately SHORT and marked fallback-only: enough to
 * fill the console's model picker before anything has been tested. Nothing in
 * them is invented — a vendor whose model names are chosen by the tenant
 * (Azure deployments, ModelArts deployments) gets a {@code modelHint} instead
 * of a made-up list. The live
 * list comes from the vendor at probe time ({@code ModelProviderProbe}), which
 * is the same call that proves the credential — so a catalog that goes stale
 * costs a hint, never correctness.
 */
public final class ModelProviderCatalog {

    private ModelProviderCatalog() {
    }

    /**
     * One input on the "add provider" form.
     *
     * @param secret  true = write-only; never echoed back to a client
     * @param options the closed list of valid values, for fields whose vendor
     *                publishes one (regions). Empty means a free-text box —
     *                the console renders a dropdown only when this is filled,
     *                so nobody has to remember a region code.
     */
    public record Field(String key, String label, boolean secret, boolean required,
                        String placeholder, List<Option> options) {

        /** One entry in that dropdown: the value stored, and what to show. */
        public record Option(String value, String label) {
        }

        static Field secret(String key, String label, String placeholder) {
            return new Field(key, label, true, true, placeholder, List.of());
        }

        static Field text(String key, String label, String placeholder) {
            return new Field(key, label, false, true, placeholder, List.of());
        }

        static Field optional(String key, String label, String placeholder) {
            return new Field(key, label, false, false, placeholder, List.of());
        }

        /** Required and picked from a list rather than typed. */
        static Field choice(String key, String label, String placeholder,
                            List<Option> options) {
            return new Field(key, label, false, true, placeholder, options);
        }
    }

    /**
     * One way of authenticating to a vendor.
     *
     * <p>Most vendors have exactly one, and for those this is a formality —
     * the spec carries a single method holding the same fields it always did.
     * Azure is the reason it exists: the same resource is reachable with an
     * API key or with an Entra ID service principal, and the two need entirely
     * different fields. Modelling that as "one field set with everything
     * optional" would mean neither combination could be required, so a
     * half-filled form would validate and fail later at the vendor.
     *
     * @param code   stored on the row, so a saved credential still knows how
     *               it is meant to be read
     * @param fields required-ness applies WITHIN this method only
     */
    public record AuthMethod(String code, String label, List<Field> fields) {
    }

    /**
     * @param defaultModel    the one this vendor is pre-selected on
     * @param fallbackModels  offered in the console before a probe has run; the
     *                        vendor's own list replaces it after the first Test
     * @param modelHint       one line explaining where the real names come from,
     *                        for the three vendors whose "models" are names the
     *                        tenant chose (Azure deployments, ModelArts
     *                        deployments, whatever Ollama has pulled)
     * @param fields          the DEFAULT method's fields, kept as its own
     *                        component so every existing caller and the whole
     *                        console form keep working unchanged
     * @param authMethods     every method including the default, first = default
     * @param declaresModels  true when this vendor's models are things the
     *                        TENANT named, so no probe can discover them and
     *                        the console must let an operator declare one
     */
    public record Spec(Kind kind, String displayName, String docsUrl, List<Field> fields,
                       String defaultModel, List<String> fallbackModels, String modelHint,
                       Map<String, List<String>> fallbackModelsByPurpose,
                       List<AuthMethod> authMethods, boolean declaresModels) {

        /**
         * Splits the suggestions by purpose on the way out, with the SAME
         * classifier the live list goes through. The console filters its
         * pickers before a Test has run and after one, and both must agree —
         * a second implementation in JavaScript would drift.
         *
         * <p>Also synthesises the single-method case, so the eleven vendors
         * that authenticate exactly one way say so in the same shape as the
         * one that does not, and the console needs no special case.
         */
        Spec(Kind kind, String displayName, String docsUrl, List<Field> fields,
             String defaultModel, List<String> fallbackModels, String modelHint) {
            this(kind, displayName, docsUrl, fields, defaultModel, fallbackModels, modelHint,
                    ModelPurposeClassifier.groupByPurpose(kind, fallbackModels),
                    List.of(new AuthMethod(DEFAULT_AUTH, "API key", fields)),
                    TENANT_NAMED_MODELS.contains(kind));
        }

        Spec(Kind kind, String displayName, String docsUrl, List<Field> fields,
             String defaultModel, List<String> fallbackModels) {
            this(kind, displayName, docsUrl, fields, defaultModel, fallbackModels, null);
        }

        /** The multi-method case: {@code fields} mirrors the first method. */
        Spec(Kind kind, String displayName, String docsUrl, String defaultModel,
             List<String> fallbackModels, String modelHint, List<AuthMethod> authMethods) {
            this(kind, displayName, docsUrl, authMethods.get(0).fields(), defaultModel,
                    fallbackModels, modelHint,
                    ModelPurposeClassifier.groupByPurpose(kind, fallbackModels),
                    List.copyOf(authMethods), TENANT_NAMED_MODELS.contains(kind));
        }

        /** The named method, or the default one when the row predates the choice. */
        public AuthMethod authMethod(String code) {
            if (code == null || code.isBlank()) {
                return authMethods.get(0);
            }
            return authMethods.stream()
                    .filter(m -> m.code().equalsIgnoreCase(code))
                    .findFirst()
                    .orElseThrow(() -> CoreException.badRequest("unknown_auth_method",
                            displayName + " has no authentication method \"" + code + "\""));
        }
    }

    /** Every vendor authenticates this way unless it says otherwise. */
    public static final String DEFAULT_AUTH = "API_KEY";

    /**
     * Vendors whose "models" are things the tenant created and named, so no
     * probe can discover them in a usable form. These are the ones where
     * declaring a model by hand is the only honest option — everywhere else
     * the vendor's own list is authoritative and typing an id is a mistake
     * waiting to happen.
     */
    private static final java.util.Set<Kind> TENANT_NAMED_MODELS =
            java.util.EnumSet.of(Kind.AZURE_OPENAI, Kind.HUAWEI, Kind.SAGEMAKER, Kind.OLLAMA);

    private static Field.Option region(String code, String name) {
        return new Field.Option(code, code + " — " + name);
    }

    /**
     * AWS commercial regions plus GovCloud. Deliberately the WHOLE partition
     * rather than a hand-kept "where Bedrock lives" subset: that subset moves
     * every few weeks, and a stale one silently hides a region the tenant is
     * entitled to. A region without Bedrock fails the Test with the vendor's
     * own answer, which is the honest outcome.
     */
    private static final List<Field.Option> AWS_REGIONS = List.of(
            region("us-east-1", "US East (N. Virginia)"),
            region("us-east-2", "US East (Ohio)"),
            region("us-west-1", "US West (N. California)"),
            region("us-west-2", "US West (Oregon)"),
            region("af-south-1", "Africa (Cape Town)"),
            region("ap-east-1", "Asia Pacific (Hong Kong)"),
            region("ap-south-1", "Asia Pacific (Mumbai)"),
            region("ap-south-2", "Asia Pacific (Hyderabad)"),
            region("ap-northeast-1", "Asia Pacific (Tokyo)"),
            region("ap-northeast-2", "Asia Pacific (Seoul)"),
            region("ap-northeast-3", "Asia Pacific (Osaka)"),
            region("ap-southeast-1", "Asia Pacific (Singapore)"),
            region("ap-southeast-2", "Asia Pacific (Sydney)"),
            region("ap-southeast-3", "Asia Pacific (Jakarta)"),
            region("ap-southeast-4", "Asia Pacific (Melbourne)"),
            region("ap-southeast-5", "Asia Pacific (Malaysia)"),
            region("ap-southeast-7", "Asia Pacific (Thailand)"),
            region("ca-central-1", "Canada (Central)"),
            region("ca-west-1", "Canada West (Calgary)"),
            region("eu-central-1", "Europe (Frankfurt)"),
            region("eu-central-2", "Europe (Zurich)"),
            region("eu-west-1", "Europe (Ireland)"),
            region("eu-west-2", "Europe (London)"),
            region("eu-west-3", "Europe (Paris)"),
            region("eu-north-1", "Europe (Stockholm)"),
            region("eu-south-1", "Europe (Milan)"),
            region("eu-south-2", "Europe (Spain)"),
            region("il-central-1", "Israel (Tel Aviv)"),
            region("me-south-1", "Middle East (Bahrain)"),
            region("me-central-1", "Middle East (UAE)"),
            region("mx-central-1", "Mexico (Central)"),
            region("sa-east-1", "South America (São Paulo)"),
            region("us-gov-west-1", "AWS GovCloud (US-West)"),
            region("us-gov-east-1", "AWS GovCloud (US-East)"));

    /** Huawei Cloud regions that host a ModelArts endpoint. */
    private static final List<Field.Option> HUAWEI_REGIONS = List.of(
            region("cn-north-4", "CN North (Beijing 4)"),
            region("cn-north-9", "CN North (Ulanqab)"),
            region("cn-east-3", "CN East (Shanghai 1)"),
            region("cn-east-2", "CN East (Shanghai 2)"),
            region("cn-south-1", "CN South (Guangzhou)"),
            region("cn-southwest-2", "CN Southwest (Guiyang 1)"),
            region("ap-southeast-1", "AP (Hong Kong)"),
            region("ap-southeast-2", "AP (Bangkok)"),
            region("ap-southeast-3", "AP (Singapore)"),
            region("ap-southeast-4", "AP (Jakarta)"),
            region("af-south-1", "AF (Johannesburg)"),
            region("af-north-1", "AF (Cairo)"),
            region("tr-west-1", "TR (Istanbul)"),
            region("me-east-1", "ME (Riyadh)"),
            region("la-south-2", "LA (Santiago)"),
            region("na-mexico-1", "LA (Mexico City)"),
            region("sa-brazil-1", "LA (Sao Paulo)"),
            region("eu-west-101", "EU (Dublin)"),
            region("ru-northwest-2", "RU (Moscow)"));

    private static final Map<Kind, Spec> SPECS = build();

    private static Map<Kind, Spec> build() {
        Map<Kind, Spec> specs = new LinkedHashMap<>();

        specs.put(Kind.OPENAI, new Spec(Kind.OPENAI, "OpenAI",
                "https://platform.openai.com/api-keys",
                List.of(Field.secret("apiKey", "API key", "sk-...")),
                "gpt-4o",
                List.of("gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4.1-mini",
                        "gpt-4o", "gpt-4o-mini", "o3", "o4-mini",
                        "text-embedding-3-large", "text-embedding-3-small")));

        specs.put(Kind.ANTHROPIC, new Spec(Kind.ANTHROPIC, "Anthropic",
                "https://console.anthropic.com/settings/keys",
                List.of(Field.secret("apiKey", "API key", "sk-ant-...")),
                "claude-opus-5",
                // Authoritative at time of writing; the live list still wins.
                List.of("claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
                        "claude-opus-4-8", "claude-fable-5")));

        specs.put(Kind.GOOGLE, new Spec(Kind.GOOGLE, "Google Gemini",
                "https://aistudio.google.com/apikey",
                List.of(Field.secret("apiKey", "API key", "AIza...")),
                "gemini-2.5-flash",
                List.of("gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
                        "gemini-2.0-flash", "gemini-2.0-flash-lite",
                        "gemini-embedding-001", "text-embedding-004")));

        specs.put(Kind.AZURE_OPENAI, new Spec(Kind.AZURE_OPENAI, "Azure OpenAI",
                "https://portal.azure.com",
                // Azure serves DEPLOYMENTS, whose names the tenant chose. The
                // base models below are only the usual naming; the real list
                // arrives from the probe.
                null,
                List.of("gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o3-mini",
                        "text-embedding-3-large"),
                "Azure routes on your deployment name, which may differ from the "
                        + "base model. Add your deployments below, or Test to load them.",
                // Two genuinely different credentials for the same resource.
                // Plenty of enterprise tenants disable key auth outright, so
                // key-only support locks those out of Azure entirely.
                List.of(new AuthMethod(DEFAULT_AUTH, "API key",
                                List.of(Field.text("endpoint", "Endpoint",
                                                "https://my-resource.openai.azure.com"),
                                        Field.secret("apiKey", "API key", "..."),
                                        Field.optional("apiVersion", "API version",
                                                "2024-10-21"))),
                        new AuthMethod("ENTRA_ID", "Microsoft Entra ID (service principal)",
                                List.of(Field.text("endpoint", "Endpoint",
                                                "https://my-resource.openai.azure.com"),
                                        Field.text("azureTenantId", "Directory (tenant) ID",
                                                "00000000-0000-0000-0000-000000000000"),
                                        Field.text("clientId", "Application (client) ID",
                                                "00000000-0000-0000-0000-000000000000"),
                                        Field.secret("clientSecret", "Client secret", "..."),
                                        Field.optional("apiVersion", "API version",
                                                "2024-10-21"))))));

        specs.put(Kind.BEDROCK, new Spec(Kind.BEDROCK, "AWS Bedrock",
                "https://console.aws.amazon.com/bedrock",
                List.of(Field.choice("region", "Region", "us-east-1", AWS_REGIONS),
                        Field.secret("accessKeyId", "Access key ID", "AKIA..."),
                        Field.secret("secretAccessKey", "Secret access key", "...")),
                "anthropic.claude-3-5-sonnet-20241022-v2:0",
                // Newer Bedrock models are only reachable through a regional
                // inference profile, hence the "us." prefix on some ids.
                List.of("us.anthropic.claude-sonnet-4-20250514-v1:0",
                        "anthropic.claude-3-5-sonnet-20241022-v2:0",
                        "anthropic.claude-3-5-haiku-20241022-v1:0",
                        "amazon.nova-pro-v1:0", "amazon.nova-lite-v1:0",
                        "meta.llama3-3-70b-instruct-v1:0",
                        "mistral.mistral-large-2407-v1:0",
                        "amazon.titan-embed-text-v2:0", "cohere.embed-english-v3"),
                "Bedrock ids are region-specific, and a model must be enabled "
                        + "for your account before it appears."));

        specs.put(Kind.HUAWEI, new Spec(Kind.HUAWEI, "Huawei Cloud (Pangu / ModelArts)",
                "https://console.huaweicloud.com/modelarts",
                List.of(Field.choice("region", "Region", "cn-north-4", HUAWEI_REGIONS),
                        Field.text("projectId", "Project ID", "..."),
                        Field.secret("accessKey", "Access key (AK)", "..."),
                        Field.secret("secretKey", "Secret key (SK)", "...")),
                // MaaS serves these open models under fixed names; Pangu itself
                // is addressed by the deployment id you created, so it cannot
                // be listed here honestly.
                null,
                List.of("DeepSeek-V3", "DeepSeek-R1", "Qwen2.5-72B-Instruct",
                        "Qwen2.5-32B-Instruct", "GLM-4-9B"),
                "Pangu models are addressed by the ModelArts deployment id you "
                        + "created — paste yours. Test the key to load the real list."));

        specs.put(Kind.MISTRAL, new Spec(Kind.MISTRAL, "Mistral AI",
                "https://console.mistral.ai/api-keys",
                List.of(Field.secret("apiKey", "API key", "...")),
                "mistral-large-latest",
                List.of("mistral-large-latest", "mistral-medium-latest",
                        "mistral-small-latest", "ministral-8b-latest",
                        "open-mistral-nemo", "codestral-latest", "mistral-embed")));

        specs.put(Kind.GROQ, new Spec(Kind.GROQ, "Groq",
                "https://console.groq.com/keys",
                List.of(Field.secret("apiKey", "API key", "gsk_...")),
                "llama-3.3-70b-versatile",
                List.of("llama-3.3-70b-versatile", "llama-3.1-8b-instant",
                        "deepseek-r1-distill-llama-70b", "gemma2-9b-it")));

        specs.put(Kind.DEEPSEEK, new Spec(Kind.DEEPSEEK, "DeepSeek",
                "https://platform.deepseek.com/api_keys",
                List.of(Field.secret("apiKey", "API key", "sk-...")),
                "deepseek-chat",
                List.of("deepseek-chat", "deepseek-reasoner")));

        specs.put(Kind.XAI, new Spec(Kind.XAI, "xAI (Grok)",
                "https://console.x.ai",
                List.of(Field.secret("apiKey", "API key", "xai-...")),
                "grok-4",
                List.of("grok-4", "grok-3", "grok-3-mini", "grok-2-1212")));

        specs.put(Kind.OPENROUTER, new Spec(Kind.OPENROUTER, "OpenRouter",
                "https://openrouter.ai/keys",
                List.of(Field.secret("apiKey", "API key", "sk-or-v1-...")),
                "openai/gpt-4o",
                List.of("openai/gpt-4o", "openai/gpt-4o-mini",
                        "anthropic/claude-sonnet-4", "google/gemini-2.0-flash-001",
                        "meta-llama/llama-3.3-70b-instruct", "mistralai/mistral-large"),
                "OpenRouter ids are vendor/model. Test the key to load exactly what "
                        + "this account can route to."));

        specs.put(Kind.HUGGINGFACE, new Spec(Kind.HUGGINGFACE, "Hugging Face",
                "https://huggingface.co/settings/tokens",
                List.of(Field.secret("apiKey", "Access token", "hf_...")),
                "meta-llama/Llama-3.3-70B-Instruct",
                List.of("meta-llama/Llama-3.3-70B-Instruct",
                        "mistralai/Mistral-7B-Instruct-v0.3",
                        "Qwen/Qwen2.5-72B-Instruct",
                        "sentence-transformers/all-MiniLM-L6-v2",
                        "BAAI/bge-m3"),
                "Any repo id your token can reach works — the Hub holds far more "
                        + "models than could be listed here."));

        specs.put(Kind.ELEVENLABS, new Spec(Kind.ELEVENLABS, "ElevenLabs",
                "https://elevenlabs.io/app/settings/api-keys",
                List.of(Field.secret("apiKey", "API key", "sk_...")),
                "eleven_multilingual_v2",
                List.of("eleven_multilingual_v2", "eleven_turbo_v2_5",
                        "eleven_flash_v2_5", "eleven_english_sts_v2", "scribe_v1"),
                "ElevenLabs is speech: synthesis and transcription. There is nothing "
                        + "here for an agent to hold a conversation with."));

        specs.put(Kind.SAGEMAKER, new Spec(Kind.SAGEMAKER, "Amazon SageMaker",
                "https://console.aws.amazon.com/sagemaker",
                List.of(Field.choice("region", "Region", "us-east-1", AWS_REGIONS),
                        Field.secret("accessKeyId", "Access key ID", "AKIA..."),
                        Field.secret("secretAccessKey", "Secret access key", "...")),
                // SageMaker serves ENDPOINTS the tenant deployed and named. There
                // is no published catalogue to fall back on, and inventing one
                // would be worse than an empty list with an explanation.
                null,
                List.of(),
                "SageMaker serves endpoints YOU deployed, so the model here is an "
                        + "endpoint name. Test the key to load the ones in this account."));

        specs.put(Kind.OLLAMA, new Spec(Kind.OLLAMA, "Ollama / self-hosted",
                "https://ollama.com",
                // No secret: whoever can reach the URL can use the models.
                List.of(Field.text("baseUrl", "Base URL", "http://localhost:11434"),
                        Field.optional("apiKey", "API key (if your gateway needs one)", "")),
                // Only what has actually been pulled onto that host will run;
                // these are the common tags, not a promise.
                "llama3.2",
                List.of("llama3.2", "llama3.1", "qwen2.5", "mistral", "gemma3",
                        "phi4", "deepseek-r1", "nomic-embed-text", "mxbai-embed-large"),
                "Only models already pulled on that host will run — `ollama list` "
                        + "shows yours."));

        return Map.copyOf(specs);
    }

    public static Spec spec(Kind kind) {
        Spec spec = SPECS.get(kind);
        if (spec == null) {
            throw CoreException.badRequest("unknown_provider",
                    "No such model provider: " + kind);
        }
        return spec;
    }

    /** Ordered for the console's provider picker. */
    public static List<Spec> all() {
        return List.copyOf(SPECS.values());
    }

    public static Kind parseKind(String code) {
        if (code == null || code.isBlank()) {
            throw CoreException.badRequest("unknown_provider", "Provider is required");
        }
        try {
            return Kind.valueOf(code.trim().toUpperCase(java.util.Locale.ROOT).replace("-", "_"));
        } catch (IllegalArgumentException ex) {
            throw CoreException.badRequest("unknown_provider",
                    "Provider must be one of " + SPECS.keySet());
        }
    }

    /**
     * Every required field present and non-blank. Deliberately shape-only —
     * whether the credential actually WORKS is settled by a real call in
     * {@code ModelProviderProbe}, never by inspecting the string here.
     */
    public static void validateConfig(Kind kind, JsonNode config) {
        validateConfig(kind, null, config);
    }

    /**
     * As above, against ONE authentication method's fields.
     *
     * <p>Checking against the union of every method's fields would require the
     * client secret of a key-authenticated connection, so each method is
     * validated on its own terms.
     *
     * @param authMethod null for the vendor's default method
     */
    public static void validateConfig(Kind kind, String authMethod, JsonNode config) {
        Spec spec = spec(kind);
        for (Field field : spec.authMethod(authMethod).fields()) {
            if (!field.required()) {
                continue;
            }
            String value = config.path(field.key()).asText("");
            if (value.isBlank()) {
                throw CoreException.badRequest("invalid_provider_config",
                        spec.displayName() + " needs \"" + field.key() + "\" ("
                                + field.label() + ")");
            }
        }
        if (kind == Kind.OLLAMA || kind == Kind.AZURE_OPENAI) {
            String urlKey = kind == Kind.OLLAMA ? "baseUrl" : "endpoint";
            String url = config.path(urlKey).asText("");
            if (!url.startsWith("http://") && !url.startsWith("https://")) {
                throw CoreException.badRequest("invalid_provider_config",
                        spec.displayName() + " needs an http:// or https:// " + urlKey);
            }
        }
    }
}
