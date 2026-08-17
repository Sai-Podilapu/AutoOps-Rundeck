/**
 * The Dify node catalog — one entry per node type Dify 1.16 supports.
 *
 * This is the single source of truth for the whole Dify designer: the palette
 * reads `CATALOG`, the canvas reads `handlesFor()` to draw ports, the config
 * panel renders `fields` generically, and the variable picker reads
 * `outputsFor()` to know what an upstream node exposes. Adding a node type to
 * this file is the only change needed to make it appear everywhere.
 *
 * `type` strings and `data` shapes mirror Dify's own DSL (app version 0.6.0)
 * so the generator can emit importable YAML without a translation layer —
 * anything renamed here has to be renamed in the generator too.
 */

// ---------------------------------------------------------------------------
// Field descriptor vocabulary consumed by the config-panel renderer.
//
//   text | textarea | number | switch | select | code | json  — primitives
//   model            model picker (provider + name + completion params)
//   prompt           role/message prompt-template editor
//   var              one variable reference ({{#node.field#}})
//   vars             an ordered list of variable references
//   varlist          declared input variables (start node's user form)
//   conditions       if-else / list-filter condition builder
//   classes          question-classifier branch list
//   params           parameter-extractor parameter list
//   keyvalue         header/query-param rows
//   outputs          declared output schema (code, end)
//   tool             tool provider + action picker
//   datasets         knowledge-base multi-picker
//   assignments      variable-assigner operation rows
//
// Every field may carry `when: (data) => boolean` to render conditionally.
// ---------------------------------------------------------------------------

/** Variable types Dify allows a value to carry. */
export const VAR_TYPES = [
  "string",
  "number",
  "boolean",
  "object",
  "array[string]",
  "array[number]",
  "array[object]",
  "file",
  "array[file]",
];

/** Operators the if-else builder offers, keyed by the operand's type. */
export const COMPARISON_OPERATORS = {
  string: [
    "contains",
    "not contains",
    "start with",
    "end with",
    "is",
    "is not",
    "empty",
    "not empty",
    "in",
    "not in",
  ],
  number: ["=", "≠", ">", "<", "≥", "≤", "empty", "not empty", "in", "not in"],
  boolean: ["is", "is not", "empty", "not empty"],
  object: ["empty", "not empty", "exists", "not exists"],
  file: ["exists", "not exists", "empty", "not empty"],
  array: ["contains", "not contains", "empty", "not empty", "all of"],
};

/** Retry block — Dify offers it on every node that performs I/O. */
const RETRY_FIELDS = [
  {
    key: "retry_config.retry_enabled",
    type: "switch",
    label: "Retry on failure",
    default: false,
    group: "Error handling",
  },
  {
    key: "retry_config.max_retries",
    type: "number",
    label: "Max retries",
    default: 3,
    min: 1,
    max: 10,
    group: "Error handling",
    when: (d) => d?.retry_config?.retry_enabled,
  },
  {
    key: "retry_config.retry_interval",
    type: "number",
    label: "Retry interval (ms)",
    default: 1000,
    min: 100,
    max: 60000,
    group: "Error handling",
    when: (d) => d?.retry_config?.retry_enabled,
  },
];

/**
 * Error strategy. `fail-branch` adds a second source handle to the node, which
 * is why `handlesFor()` has to consult the node's data and not just its type.
 */
const ERROR_STRATEGY_FIELDS = [
  {
    key: "error_strategy",
    type: "select",
    label: "On error",
    default: "none",
    group: "Error handling",
    options: [
      { value: "none", label: "Fail the workflow" },
      { value: "default-value", label: "Continue with a default value" },
      { value: "fail-branch", label: "Continue on the fail branch" },
    ],
  },
  {
    key: "default_value",
    type: "json",
    label: "Default value",
    group: "Error handling",
    when: (d) => d?.error_strategy === "default-value",
  },
];

const FAILABLE = [...RETRY_FIELDS, ...ERROR_STRATEGY_FIELDS];

/** Shared defaults every node carries. */
const failableDefaults = () => ({
  retry_config: { retry_enabled: false, max_retries: 3, retry_interval: 1000 },
  error_strategy: "none",
});

/** Standard single-in / single-out port set. */
const IN = [{ id: "target", type: "target" }];
const OUT = [{ id: "source", type: "source" }];

// ---------------------------------------------------------------------------
// The catalog.
// ---------------------------------------------------------------------------

export const CATALOG = [
  // ---- entry / exit -------------------------------------------------------
  {
    type: "start",
    label: "Start",
    category: "entry",
    icon: "play",
    color: "#22c55e",
    description: "Workflow entry point and the user-input form it collects.",
    unique: true, // exactly one per workflow
    inputs: [],
    outputs: OUT,
    defaults: () => ({ variables: [] }),
    fields: [
      {
        key: "variables",
        type: "varlist",
        label: "Input fields",
        help: "Rendered as the run form and exposed to every downstream node.",
      },
    ],
    // System variables Dify injects regardless of the declared form.
    systemOutputs: [
      { name: "sys.files", type: "array[file]" },
      { name: "sys.user_id", type: "string" },
      { name: "sys.app_id", type: "string" },
      { name: "sys.workflow_id", type: "string" },
      { name: "sys.workflow_run_id", type: "string" },
    ],
    outputs_vars: (data) =>
      (data.variables || []).map((v) => ({
        name: v.variable,
        type: v.type === "number" ? "number" : "string",
      })),
  },
  {
    type: "end",
    label: "End",
    category: "entry",
    icon: "stop",
    color: "#64748b",
    description: "Terminates the run and declares the workflow's output.",
    inputs: IN,
    outputs: [],
    defaults: () => ({ outputs: [] }),
    fields: [{ key: "outputs", type: "vars", label: "Output variables" }],
    outputs_vars: () => [],
  },
  {
    type: "answer",
    label: "Answer",
    category: "entry",
    icon: "chat",
    color: "#0ea5e9",
    description: "Streams a reply to the user. Chatflow apps only.",
    chatOnly: true,
    inputs: IN,
    outputs: OUT,
    defaults: () => ({ answer: "" }),
    fields: [
      {
        key: "answer",
        type: "textarea",
        label: "Answer template",
        help: "Interpolate upstream values with {{#node_id.field#}}.",
        rows: 6,
      },
    ],
    outputs_vars: () => [],
  },

  // ---- AI -----------------------------------------------------------------
  {
    type: "llm",
    label: "LLM",
    category: "ai",
    icon: "sparkles",
    color: "#6366f1",
    description: "Calls a language model with a prompt template.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      model: {
        provider: "",
        name: "",
        mode: "chat",
        completion_params: { temperature: 0.7 },
      },
      prompt_template: [{ role: "system", text: "" }],
      context: { enabled: false, variable_selector: [] },
      vision: { enabled: false, configs: { detail: "high" } },
      memory: { enabled: false, window: { enabled: false, size: 10 } },
      structured_output_enabled: false,
      structured_output: null,
      ...failableDefaults(),
    }),
    fields: [
      { key: "model", type: "model", label: "Model", required: true },
      { key: "prompt_template", type: "prompt", label: "Prompt" },
      {
        key: "context.enabled",
        type: "switch",
        label: "Use retrieved context",
        default: false,
        group: "Context",
      },
      {
        key: "context.variable_selector",
        type: "var",
        label: "Context variable",
        group: "Context",
        when: (d) => d?.context?.enabled,
      },
      {
        key: "memory.enabled",
        type: "switch",
        label: "Conversation memory",
        default: false,
        group: "Memory",
        chatOnly: true,
      },
      {
        key: "memory.window.size",
        type: "number",
        label: "Memory window (turns)",
        default: 10,
        min: 1,
        max: 100,
        group: "Memory",
        when: (d) => d?.memory?.enabled,
      },
      {
        key: "vision.enabled",
        type: "switch",
        label: "Vision",
        default: false,
        group: "Vision",
      },
      {
        key: "vision.configs.detail",
        type: "select",
        label: "Image detail",
        default: "high",
        options: [
          { value: "high", label: "High" },
          { value: "low", label: "Low" },
        ],
        group: "Vision",
        when: (d) => d?.vision?.enabled,
      },
      {
        key: "structured_output_enabled",
        type: "switch",
        label: "Structured output",
        default: false,
        group: "Output",
      },
      {
        key: "structured_output",
        type: "json",
        label: "Output JSON schema",
        group: "Output",
        when: (d) => d?.structured_output_enabled,
      },
      ...FAILABLE,
    ],
    outputs_vars: () => [
      { name: "text", type: "string" },
      { name: "usage", type: "object" },
      { name: "finish_reason", type: "string" },
    ],
  },
  {
    type: "agent",
    label: "Agent",
    category: "ai",
    icon: "robot",
    color: "#8b5cf6",
    description: "Autonomous tool-using agent with an iteration budget.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      agent_strategy_provider_name: "",
      agent_strategy_name: "function_calling",
      agent_parameters: {
        model: { provider: "", name: "", completion_params: {} },
        tools: [],
        instruction: "",
        query: [],
        maximum_iterations: 5,
      },
      ...failableDefaults(),
    }),
    fields: [
      {
        key: "agent_strategy_name",
        type: "select",
        label: "Strategy",
        default: "function_calling",
        options: [
          { value: "function_calling", label: "Function calling" },
          { value: "ReAct", label: "ReAct" },
        ],
      },
      { key: "agent_parameters.model", type: "model", label: "Model", required: true },
      { key: "agent_parameters.tools", type: "tool", label: "Tools", multiple: true },
      { key: "agent_parameters.query", type: "var", label: "Query" },
      {
        key: "agent_parameters.instruction",
        type: "textarea",
        label: "Instruction",
        rows: 5,
      },
      {
        key: "agent_parameters.maximum_iterations",
        type: "number",
        label: "Max iterations",
        default: 5,
        min: 1,
        max: 30,
      },
      ...FAILABLE,
    ],
    outputs_vars: () => [
      { name: "text", type: "string" },
      { name: "files", type: "array[file]" },
      { name: "json", type: "array[object]" },
    ],
  },
  {
    type: "knowledge-retrieval",
    label: "Knowledge Retrieval",
    category: "ai",
    icon: "book",
    color: "#0891b2",
    description: "Retrieves chunks from one or more knowledge bases.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      query_variable_selector: [],
      dataset_ids: [],
      retrieval_mode: "multiple",
      multiple_retrieval_config: {
        top_k: 4,
        score_threshold: 0.5,
        score_threshold_enabled: false,
        reranking_enable: false,
        reranking_mode: "reranking_model",
      },
    }),
    fields: [
      { key: "query_variable_selector", type: "var", label: "Query variable", required: true },
      { key: "dataset_ids", type: "datasets", label: "Knowledge bases", required: true },
      {
        key: "retrieval_mode",
        type: "select",
        label: "Retrieval mode",
        default: "multiple",
        options: [
          { value: "multiple", label: "Multi-path (rerank)" },
          { value: "single", label: "N-to-1 (model routes)" },
        ],
      },
      {
        key: "multiple_retrieval_config.top_k",
        type: "number",
        label: "Top K",
        default: 4,
        min: 1,
        max: 50,
        when: (d) => d?.retrieval_mode === "multiple",
      },
      {
        key: "multiple_retrieval_config.score_threshold_enabled",
        type: "switch",
        label: "Score threshold",
        default: false,
        when: (d) => d?.retrieval_mode === "multiple",
      },
      {
        key: "multiple_retrieval_config.score_threshold",
        type: "number",
        label: "Threshold",
        default: 0.5,
        min: 0,
        max: 1,
        step: 0.01,
        when: (d) =>
          d?.retrieval_mode === "multiple" &&
          d?.multiple_retrieval_config?.score_threshold_enabled,
      },
      {
        key: "multiple_retrieval_config.reranking_enable",
        type: "switch",
        label: "Rerank",
        default: false,
        when: (d) => d?.retrieval_mode === "multiple",
      },
      {
        key: "multiple_retrieval_config.reranking_model",
        type: "model",
        label: "Rerank model",
        modelType: "rerank",
        when: (d) => d?.multiple_retrieval_config?.reranking_enable,
      },
      { key: "single_retrieval_config.model", type: "model", label: "Routing model", when: (d) => d?.retrieval_mode === "single" },
    ],
    outputs_vars: () => [{ name: "result", type: "array[object]" }],
  },
  {
    type: "question-classifier",
    label: "Question Classifier",
    category: "ai",
    icon: "branch",
    color: "#f59e0b",
    description: "Routes to one branch per class using a model.",
    branching: true,
    inputs: IN,
    // One source handle per declared class — see handlesFor().
    outputs: null,
    defaults: () => ({
      model: { provider: "", name: "", mode: "chat", completion_params: { temperature: 0 } },
      query_variable_selector: [],
      classes: [
        { id: "1", name: "" },
        { id: "2", name: "" },
      ],
      instruction: "",
      ...failableDefaults(),
    }),
    fields: [
      { key: "model", type: "model", label: "Model", required: true },
      { key: "query_variable_selector", type: "var", label: "Input variable", required: true },
      { key: "classes", type: "classes", label: "Classes", required: true },
      {
        key: "instruction",
        type: "textarea",
        label: "Extra instruction",
        rows: 4,
      },
      ...FAILABLE,
    ],
    outputs_vars: () => [
      { name: "class_name", type: "string" },
      { name: "usage", type: "object" },
    ],
  },
  {
    type: "parameter-extractor",
    label: "Parameter Extractor",
    category: "ai",
    icon: "filter",
    color: "#ec4899",
    description: "Pulls typed, structured parameters out of free text.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      model: { provider: "", name: "", mode: "chat", completion_params: { temperature: 0 } },
      query: [],
      parameters: [],
      reasoning_mode: "function_call",
      instruction: "",
      ...failableDefaults(),
    }),
    fields: [
      { key: "model", type: "model", label: "Model", required: true },
      { key: "query", type: "var", label: "Input variable", required: true },
      { key: "parameters", type: "params", label: "Parameters to extract", required: true },
      {
        key: "reasoning_mode",
        type: "select",
        label: "Reasoning mode",
        default: "function_call",
        options: [
          { value: "function_call", label: "Function calling" },
          { value: "prompt", label: "Prompt" },
        ],
      },
      { key: "instruction", type: "textarea", label: "Instruction", rows: 4 },
      ...FAILABLE,
    ],
    // Declared parameters become variables, plus Dify's two status fields.
    outputs_vars: (data) => [
      ...(data.parameters || []).map((p) => ({ name: p.name, type: p.type || "string" })),
      { name: "__is_success", type: "number" },
      { name: "__reason", type: "string" },
    ],
  },

  // ---- logic --------------------------------------------------------------
  {
    type: "if-else",
    label: "IF / ELSE",
    category: "logic",
    icon: "split",
    color: "#f97316",
    description: "Branches on one or more conditions.",
    branching: true,
    inputs: IN,
    outputs: null, // one handle per case + ELSE — see handlesFor()
    defaults: () => ({
      cases: [
        {
          case_id: "true",
          logical_operator: "and",
          conditions: [],
        },
      ],
    }),
    fields: [{ key: "cases", type: "conditions", label: "Conditions" }],
    outputs_vars: () => [],
  },
  {
    type: "iteration",
    label: "Iteration",
    category: "logic",
    icon: "repeat",
    color: "#14b8a6",
    description: "Runs the nested sub-flow once per item of an array.",
    container: true,
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      iterator_selector: [],
      output_selector: [],
      output_type: "array[string]",
      is_parallel: false,
      parallel_nums: 10,
      error_handle_mode: "terminated",
    }),
    fields: [
      { key: "iterator_selector", type: "var", label: "Input array", required: true },
      { key: "output_selector", type: "var", label: "Output variable", required: true },
      {
        key: "output_type",
        type: "select",
        label: "Output type",
        default: "array[string]",
        options: ["array[string]", "array[number]", "array[object]"].map((v) => ({
          value: v,
          label: v,
        })),
      },
      { key: "is_parallel", type: "switch", label: "Run in parallel", default: false },
      {
        key: "parallel_nums",
        type: "number",
        label: "Max parallelism",
        default: 10,
        min: 1,
        max: 50,
        when: (d) => d?.is_parallel,
      },
      {
        key: "error_handle_mode",
        type: "select",
        label: "On item error",
        default: "terminated",
        options: [
          { value: "terminated", label: "Stop the iteration" },
          { value: "continue-on-error", label: "Continue" },
          { value: "remove-abnormal-output", label: "Drop the failed item" },
        ],
      },
    ],
    outputs_vars: (data) => [{ name: "output", type: data.output_type || "array[string]" }],
  },
  {
    type: "loop",
    label: "Loop",
    category: "logic",
    icon: "refresh",
    color: "#14b8a6",
    description: "Repeats the nested sub-flow until a break condition holds.",
    container: true,
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      loop_count: 10,
      logical_operator: "and",
      break_conditions: [],
      loop_variables: [],
    }),
    fields: [
      { key: "loop_count", type: "number", label: "Max iterations", default: 10, min: 1, max: 200 },
      { key: "loop_variables", type: "assignments", label: "Loop variables" },
      { key: "break_conditions", type: "conditions", label: "Break when", single: true },
    ],
    outputs_vars: () => [{ name: "loop_round", type: "number" }],
  },

  // ---- transform ----------------------------------------------------------
  {
    type: "code",
    label: "Code",
    category: "transform",
    icon: "terminal",
    color: "#3b82f6",
    description: "Runs a sandboxed Python or JavaScript function.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      code_language: "python3",
      variables: [],
      code: "def main(arg1: str) -> dict:\n    return {\n        \"result\": arg1,\n    }\n",
      outputs: { result: { type: "string" } },
      ...failableDefaults(),
    }),
    fields: [
      {
        key: "code_language",
        type: "select",
        label: "Language",
        default: "python3",
        options: [
          { value: "python3", label: "Python 3" },
          { value: "javascript", label: "JavaScript" },
        ],
      },
      { key: "variables", type: "vars", label: "Input variables", named: true },
      { key: "code", type: "code", label: "Code", languageKey: "code_language", rows: 16 },
      { key: "outputs", type: "outputs", label: "Output schema" },
      ...FAILABLE,
    ],
    outputs_vars: (data) =>
      Object.entries(data.outputs || {}).map(([name, v]) => ({
        name,
        type: v?.type || "string",
      })),
  },
  {
    type: "template-transform",
    label: "Template",
    category: "transform",
    icon: "code",
    color: "#3b82f6",
    description: "Renders a Jinja2 template into a single string.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      variables: [],
      template: "{{ arg1 }}",
    }),
    fields: [
      { key: "variables", type: "vars", label: "Input variables", named: true },
      { key: "template", type: "code", label: "Template", language: "jinja2", rows: 12 },
    ],
    outputs_vars: () => [{ name: "output", type: "string" }],
  },
  {
    type: "variable-aggregator",
    label: "Variable Aggregator",
    category: "transform",
    icon: "merge",
    color: "#a855f7",
    description: "Collapses parallel branches into one variable.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      output_type: "string",
      variables: [],
      advanced_settings: { group_enabled: false, groups: [] },
    }),
    fields: [
      {
        key: "output_type",
        type: "select",
        label: "Output type",
        default: "string",
        options: VAR_TYPES.map((v) => ({ value: v, label: v })),
      },
      { key: "variables", type: "vars", label: "Variables to aggregate" },
      {
        key: "advanced_settings.group_enabled",
        type: "switch",
        label: "Group into named sets",
        default: false,
      },
    ],
    outputs_vars: (data) => [{ name: "output", type: data.output_type || "string" }],
  },
  {
    type: "variable-assigner",
    label: "Variable Assigner",
    category: "transform",
    icon: "edit",
    color: "#a855f7",
    description: "Writes to conversation or loop variables.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({ version: "2", items: [] }),
    fields: [{ key: "items", type: "assignments", label: "Assignments" }],
    outputs_vars: () => [],
  },
  {
    type: "document-extractor",
    label: "Doc Extractor",
    category: "transform",
    icon: "file",
    color: "#0d9488",
    description: "Reads uploaded files into plain text.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({ variable_selector: [], is_array_file: false }),
    fields: [{ key: "variable_selector", type: "var", label: "File variable", required: true }],
    outputs_vars: () => [{ name: "text", type: "array[string]" }],
  },
  {
    type: "list-operator",
    label: "List Operator",
    category: "transform",
    icon: "list",
    color: "#0d9488",
    description: "Filters, sorts and slices an array.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      variable: [],
      filter_by: { enabled: false, conditions: [] },
      order_by: { enabled: false, key: "", value: "asc" },
      limit: { enabled: false, size: 10 },
    }),
    fields: [
      { key: "variable", type: "var", label: "Input array", required: true },
      { key: "filter_by.enabled", type: "switch", label: "Filter", default: false },
      {
        key: "filter_by.conditions",
        type: "conditions",
        label: "Keep items where",
        single: true,
        when: (d) => d?.filter_by?.enabled,
      },
      { key: "order_by.enabled", type: "switch", label: "Sort", default: false },
      {
        key: "order_by.value",
        type: "select",
        label: "Order",
        default: "asc",
        options: [
          { value: "asc", label: "Ascending" },
          { value: "desc", label: "Descending" },
        ],
        when: (d) => d?.order_by?.enabled,
      },
      { key: "limit.enabled", type: "switch", label: "Limit", default: false },
      {
        key: "limit.size",
        type: "number",
        label: "Max items",
        default: 10,
        min: 1,
        when: (d) => d?.limit?.enabled,
      },
    ],
    outputs_vars: () => [
      { name: "result", type: "array[object]" },
      { name: "first_record", type: "object" },
      { name: "last_record", type: "object" },
    ],
  },

  // ---- I/O ----------------------------------------------------------------
  {
    type: "http-request",
    label: "HTTP Request",
    category: "io",
    icon: "api",
    color: "#eab308",
    description: "Calls an external HTTP endpoint.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      method: "get",
      url: "",
      headers: "",
      params: "",
      body: { type: "none", data: [] },
      authorization: { type: "no-auth", config: null },
      timeout: { max_connect_timeout: 10, max_read_timeout: 60, max_write_timeout: 20 },
      ssl_verify: true,
      ...failableDefaults(),
    }),
    fields: [
      {
        key: "method",
        type: "select",
        label: "Method",
        default: "get",
        options: ["get", "post", "put", "patch", "delete", "head"].map((v) => ({
          value: v,
          label: v.toUpperCase(),
        })),
      },
      { key: "url", type: "text", label: "URL", required: true, placeholder: "https://…" },
      { key: "headers", type: "keyvalue", label: "Headers" },
      { key: "params", type: "keyvalue", label: "Query params" },
      {
        key: "body.type",
        type: "select",
        label: "Body",
        default: "none",
        options: ["none", "form-data", "x-www-form-urlencoded", "raw-text", "json", "binary"].map(
          (v) => ({ value: v, label: v }),
        ),
      },
      {
        key: "body.data",
        type: "code",
        label: "Body content",
        language: "json",
        rows: 8,
        when: (d) => d?.body?.type && d.body.type !== "none",
      },
      {
        key: "authorization.type",
        type: "select",
        label: "Auth",
        default: "no-auth",
        group: "Authorization",
        options: [
          { value: "no-auth", label: "None" },
          { value: "api-key", label: "API key" },
        ],
      },
      {
        key: "authorization.config.type",
        type: "select",
        label: "Key type",
        default: "bearer",
        group: "Authorization",
        options: [
          { value: "bearer", label: "Bearer" },
          { value: "basic", label: "Basic" },
          { value: "custom", label: "Custom header" },
        ],
        when: (d) => d?.authorization?.type === "api-key",
      },
      {
        key: "authorization.config.header",
        type: "text",
        label: "Header name",
        group: "Authorization",
        when: (d) =>
          d?.authorization?.type === "api-key" && d?.authorization?.config?.type === "custom",
      },
      {
        key: "authorization.config.api_key",
        type: "text",
        label: "API key",
        secret: true,
        group: "Authorization",
        when: (d) => d?.authorization?.type === "api-key",
      },
      { key: "ssl_verify", type: "switch", label: "Verify TLS", default: true, group: "Advanced" },
      {
        key: "timeout.max_read_timeout",
        type: "number",
        label: "Read timeout (s)",
        default: 60,
        min: 1,
        max: 300,
        group: "Advanced",
      },
      ...FAILABLE,
    ],
    outputs_vars: () => [
      { name: "body", type: "string" },
      { name: "status_code", type: "number" },
      { name: "headers", type: "object" },
      { name: "files", type: "array[file]" },
    ],
  },
  {
    type: "tool",
    label: "Tool",
    category: "io",
    icon: "wrench",
    color: "#eab308",
    description: "Invokes a builtin, custom or workflow-as-tool action.",
    inputs: IN,
    outputs: OUT,
    defaults: () => ({
      provider_id: "",
      provider_type: "builtin",
      provider_name: "",
      tool_name: "",
      tool_label: "",
      tool_configurations: {},
      tool_parameters: {},
      ...failableDefaults(),
    }),
    fields: [
      { key: "__tool", type: "tool", label: "Tool", required: true },
      ...FAILABLE,
    ],
    outputs_vars: () => [
      { name: "text", type: "string" },
      { name: "files", type: "array[file]" },
      { name: "json", type: "array[object]" },
    ],
  },
];

// ---------------------------------------------------------------------------
// Lookups + derived helpers.
// ---------------------------------------------------------------------------

export const NODE_TYPES = Object.fromEntries(CATALOG.map((n) => [n.type, n]));

export const CATEGORIES = [
  { key: "entry", label: "Entry & Exit" },
  { key: "ai", label: "AI" },
  { key: "logic", label: "Logic" },
  { key: "transform", label: "Transform" },
  { key: "io", label: "Tools & I/O" },
];

/** Palette groups, respecting `chatOnly` for workflow-mode apps. */
export function paletteFor(appMode = "workflow") {
  return CATEGORIES.map((c) => ({
    ...c,
    nodes: CATALOG.filter(
      (n) => n.category === c.key && !n.unique && (appMode === "chat" || !n.chatOnly),
    ),
  })).filter((c) => c.nodes.length > 0);
}

export const defaultDataFor = (type, title) => ({
  title: title || NODE_TYPES[type]?.label || type,
  desc: "",
  type,
  ...(NODE_TYPES[type]?.defaults?.() || {}),
});

/**
 * Port list for a node instance. Branching nodes derive their source handles
 * from data (one per if-else case, one per classifier class), and any node set
 * to `fail-branch` grows an extra red handle — so this needs the instance, not
 * just the type.
 */
export function handlesFor(node) {
  const def = NODE_TYPES[node?.type];
  if (!def) return { inputs: IN, outputs: OUT };
  const inputs = def.inputs || [];
  let outputs = def.outputs;

  if (outputs === null) {
    if (node.type === "if-else") {
      const cases = node.data?.cases || [];
      outputs = [
        ...cases.map((c, i) => ({
          id: c.case_id,
          type: "source",
          label: i === 0 ? "IF" : `ELIF ${i}`,
        })),
        { id: "false", type: "source", label: "ELSE" },
      ];
    } else if (node.type === "question-classifier") {
      outputs = (node.data?.classes || []).map((c, i) => ({
        id: c.id,
        type: "source",
        label: c.name || `Class ${i + 1}`,
      }));
    } else {
      outputs = OUT;
    }
  }

  if (node.data?.error_strategy === "fail-branch") {
    outputs = [...outputs, { id: "fail-branch", type: "source", label: "FAIL", tone: "error" }];
  }
  return { inputs, outputs };
}

/** The variables a node exposes to everything downstream of it. */
export function outputsFor(node) {
  const def = NODE_TYPES[node?.type];
  if (!def?.outputs_vars) return [];
  try {
    return def.outputs_vars(node.data || {});
  } catch {
    return []; // a half-configured node must not break the variable picker
  }
}

/** Flattens the catalog's dotted field keys — `get(data, "memory.window.size")`. */
export const getPath = (obj, path) =>
  path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);

/** Immutable dotted-path set, used by every config field's onChange. */
export function setPath(obj, path, value) {
  const keys = path.split(".");
  const next = Array.isArray(obj) ? [...obj] : { ...obj };
  let cursor = next;
  for (let i = 0; i < keys.length - 1; i++) {
    const k = keys[i];
    const child = cursor[k];
    cursor[k] = child == null ? {} : Array.isArray(child) ? [...child] : { ...child };
    cursor = cursor[k];
  }
  cursor[keys[keys.length - 1]] = value;
  return next;
}
