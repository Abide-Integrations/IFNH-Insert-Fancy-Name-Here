# ADR-0005: Profiles, model aliases with routing and fallbacks, per-model provider options

- **Status:** Accepted (2026-11-01, tasks D-03/D-04/D-05)
- **Context:** Configuration could name exactly one provider/model pair. Every
  other role — the child agents a parent spawns, a cheaper model for research,
  an offline endpoint for one session — had no way to be expressed without
  editing `model` by hand. DECISIONS 44–49 already settled the shape on paper:
  aliases (44), a routing table that names aliases (45), fail fast on a missing
  capability (46), retries for 429/5xx/network only (47), Retry-After (48),
  per-alias fallback chains that are off by default (49). Nothing read the keys.
  DESIGN §4 also carried `provider_options` as a bag; DECISION 41 left it
  unimplemented, so `thinking` budgets and reasoning effort could not be
  requested at all.
- **Decision:**
  1. **Profiles (D-03).** `profiles.<name>` is a config subtree merged as the
     `.cli` layer when the global flag `--profile <name>` is given (before the
     subcommand, for the REPL and `ifnh ask`). `Store.applyProfile` deep-merges a
     copy of the subtree minus `prompt`, records the origin as `--profile <name>`,
     then re-validates, so a profile that introduces a broken alias or route
     fails at startup like a hand-written config. An unknown name is a hard
     startup error naming the known profiles, exit code 2:
     `unknown profile 'x'; known profiles: a, b`. `profiles.<name>.prompt` is
     appended to the assembled system prompt after the stable prefix
     (`instructions.appendFragment`), so the cacheable prefix does not move. The
     drivers apply the profile (not `config.load`), and
     `SessionRuntime.InitOptions.profile` re-applies it after a config re-read;
     session overrides (`/model`) go on last and still win.
  2. **Aliases and routing (D-04).** New pure module
     `src/core/config/resolve.zig`: `resolveAlias(store, arena, name)` returns a
     `ResolvedModel` (provider instance, provider name, model, base_url,
     api_key_env, temperature, max_output_tokens, provider_options, alias label,
     flat fallback chain); `resolveRole(store, arena, role)` maps
     `routing.<role>` (`parent`, `research`, `implement`, `review`) to an alias,
     `"default"` meaning the plain `model` block. An alias inherits
     `base_url`/`api_key_env`/`temperature`/`max_output_tokens` from `model` only
     when it keeps the same provider: switching provider switches the endpoint,
     the key variable and the model together (D46). Validation runs from
     `Store.validate`, so unknown aliases, non-string routing entries, aliases
     without a `model`, unknown sub-keys and fallback cycles/self-references are
     startup errors or warnings naming the offending path.
  3. **Fallbacks.** `models.fallbacks.<alias>` is a chain, pre-resolved and
     deduplicated into a flat slice (`Cycle` on a repeat inside one path, depth
     capped). `ProviderConfig.fallbacks` carries it; the engine switches models
     only when the attempt failed with a retryable class, no text was streamed,
     and the retry budget is spent, and it resets the attempt counter so the
     next model gets its own retries. The switch is announced through
     `on_notice` as `fallback: <from> -> <to>`; a non-retryable failure never
     falls back (D49, D47).
  4. **Child routing.** A spawned child picks its model from
     `routing.<role>` unless the tool call passes an explicit `model`. The table
     is built once per turn on the parent thread (`submitTurn` fills
     `subagent.ChildModels`) and passed as `Host.routing`; the child only reads
     it, so no child thread touches `Store` and its warning list. `ChildModel`
     carries provider, model, base_url, api_key, options, temperature and token
     cap as one bundle, so a role can never mix one provider's endpoint with
     another's key.
  5. **Provider options (D-05).** `provider_options` may be set at
     `model.provider_options` (new key), `models.provider_options.<model id>`
     and on an alias; they merge shallowly per key with precedence
     alias > per-model > model-wide. New pure module `src/providers/options.zig`
     (`compile(arena, provider, raw_json)`) keeps only the keys the adapter
     implements — `reasoning_effort` (`minimal|low|medium|high`) and `reasoning`
     for openai, `thinking` (object) and `top_k` (integer) for anthropic — and
     reports every dropped key or wrong type as a config warning (deduplicated
     by `Store.warn`, since resolution runs once per turn). Both adapters splice
     the compiled members into the request body through `options.splice`, which
     replaces the earlier `trimEnd(..., "{}")` that silently ate trailing
     braces. The result travels on the existing `provider_options` field of
     `ModelRequest`, `RunParams` and the compaction call.
- **Consequences:**
  - Configuration is still data: no model, endpoint or role policy is compiled
    into the binary, and zero-config still resolves to the `model` block.
  - `resolve.zig` and `config.zig` import each other. Zig 0.16 allows it because
    only function bodies reference across the cycle, and `Store.validate` is the
    single entry point that calls back. The alternative — a validation pass in
    `main` — was rejected because a library caller could skip it.
  - Free-form sections (`models.aliases`, `models.fallbacks`,
    `models.provider_options`, `model.provider_options`, `profiles`) skip the
    generic unknown-key walk and are validated by `resolve.zig` instead, which
    knows the legal keys; `routing.<role>` values are validated normally.
  - Options are filtered per adapter, so the same config can be moved between
    openai and anthropic without sending `thinking` to OpenAI. Keys are dropped
    rather than forwarded with a warning: silently sending an unimplemented
    field is how a request starts failing with a 400 the user cannot explain.
  - Fallbacks are per alias and off by default; there is no global chain. A
    fallback may itself fall back (the chain is flat, so every member is tried
    at most once).
  - Not done: `provider_options` for MCP servers or custom tools; reasoning
    stream parsing (A-01 note); per-role permission sets (`routing` only picks a
    model).
  - Tests: 11 in `resolve.zig` (resolution, inheritance, provider switch,
    routing, chain order, cycles, option precedence, validation paths), 5 in
    `options.zig`, 4 in `config.zig` (profile merge, unknown profile message,
    re-validation, free-form sections), 2 in `engine.zig` (fallback after
    exhausted retries, no fallback on a non-retryable failure), 1 in
    `subagent.zig` (role table, inheritance, explicit model), 2 golden-body
    tests (one per adapter) and 3 in `args.zig`/`instructions.zig`.
