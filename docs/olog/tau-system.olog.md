# Tau System Olog

This file is the canonical ontology log (Spivak) of the Tau project: every
object (type/concept) and morphism (functional relationship) of the running
system, synthesised from four subsystem inventories and cross-checked against
`lib/tau/` at HEAD `a9a5de7`. The file is **LLM-optimised** — terse, dense,
machine-parseable. **No human-friendly rendering, diagrams, or expository
narrative is produced here**: that is a deferred separate artifact.

## Legend (notation)

- Object: `O<n> := "<noun phrase>" @<artifact>` — `@artifact` is the
  Elixir module/struct/process/behaviour; `@-` denotes a purely abstract
  concept with no single artifact.
- Morphism: `m<n> : O<a> -> O<b> "<verb-phrase>"` — one per line.
  Suffix ` [partial]` if the aspect can be absent/nil (partial function
  `A ⇀ B`, equivalently `A → B + 1`).
- Constraint: a numbered fact. Forms:
  - Path equivalence (commuting diagram): `m<i> . m<j> = m<k>`
    (`.` = composition, right-to-left).
  - Categorical fact: `m<n> : mono|epi|iso`,
    `(m<i>,m<j>) : pullback|product|coproduct|equaliser|coequaliser`,
    `O<n> : terminal|initial`, `O<n> = O<a> + O<b> + ...` (coproduct
    decomposition), `O<n> = O<a> × O<b> × ...` (product), partial-order
    facts (`m<i> <= m<j>`), idempotence (`m<i> . m<i> = m<i>`).
  - Bare predicate when no diagram applies.
  Each constraint is tagged with the originating invariant
  (`D-NNN`, `[Cn-Bm]`, `ADR-NNNN`, or "(code)") and a ≤12-word gloss.
- IDs are **global and stable** across the whole olog (single numbering);
  section headers are navigational only.

# Objects

## section: A — Session, Message, Persistence

O1 := "the session FSM" @Tau.Session
O2 := "a session id" @-
O3 := "a session FSM state" @-
O4 := "a session data record" @Tau.Session.data
O5 := "a session snapshot" @Tau.Session.snapshot
O6 := "a session metadata record" @Tau.Session.Meta
O7 := "a user metadata map" @-
O8 := "a message" @Tau.Message
O9 := "a user message" @Tau.Message.User
O10 := "an assistant message" @Tau.Message.Assistant
O11 := "a tool result message" @Tau.Message.ToolResult
O12 := "a message role" @-
O13 := "a content block" @-
O14 := "a text block" @-
O15 := "an image block" @-
O16 := "a thinking block" @-
O17 := "a tool-call block" @-
O18 := "a stop reason" @-
O19 := "a usage record" @-
O20 := "the message assembler" @Tau.Message.Assembler
O21 := "an assembler block-stage map" @Tau.Message.Assembler.blocks
O22 := "a session lifecycle event" @Tau.Session.Events
O23 := "a session-start event" @Tau.Session.Events.SessionStart
O24 := "a message-start event" @Tau.Session.Events.MessageStart
O25 := "a message-update event" @Tau.Session.Events.MessageUpdate
O26 := "a message-end event" @Tau.Session.Events.MessageEnd
O27 := "a tool-start event" @Tau.Session.Events.ToolStart
O28 := "a tool-update event" @Tau.Session.Events.ToolUpdate
O29 := "a tool-end event" @Tau.Session.Events.ToolEnd
O30 := "a cancelled event" @Tau.Session.Events.Cancelled
O31 := "a skill-activated event" @Tau.Session.Events.SkillActivated
O32 := "a system-notice event" @Tau.Session.Events.SystemNotice
O33 := "a session-end event" @Tau.Session.Events.SessionEnd
O34 := "a provider-fallback event" @Tau.Session.Events.ProviderFallback
O35 := "the persistence behaviour" @Tau.Persistence
O36 := "a persistence handle" @-
O37 := "a persisted event record" @-
O38 := "a session header record" @-
O39 := "a transcript" @-
O40 := "a transcript path" @-
O41 := "a fork point" @-
O42 := "an active skill" @-
O43 := "a persona lifetime" @-
O44 := "a tools whitelist" @-
O45 := "a child-session set" @Tau.Session.data.child_session_ids
O46 := "a stream run token" @Tau.Session.data.stream_ref
O47 := "a provider span ref" @Tau.Session.data.provider_span_ref
O48 := "a cancel flag" @Tau.Session.data.cancel_flag
O49 := "a fallback chain" @Tau.Session.data.fallback_chain_remaining
O50 := "a tool-in-flight map" @Tau.Session.data.tools_in_flight
O51 := "a tool-iteration count" @Tau.Session.data.tool_iterations
O52 := "a compaction-failure count" @Tau.Session.data.compaction_failures
O53 := "a builtin-command outcome" @Tau.Commands.Builtin.outcome
O54 := "a slash-command classification" @-
O55 := "a coding-agent adapter-state" @Tau.Session.data.coding_agent_state
O56 := "a JSONL persistence backend" @Tau.Persistence.Jsonl
O57 := "an event id" @-
O58 := "a parent event id" @-
O59 := "an event kind" @-
O60 := "a session conversation history" @Tau.Session.data.messages

## section: B — Providers & Reliability

O70 := "a provider" @Tau.Provider
O71 := "a stream-opts map" @Tau.Provider.stream_opts
O72 := "a provider ctx" @Tau.Provider.ctx
O73 := "a capabilities map" @Tau.Provider.capabilities
O74 := "a provider event" @Tau.Provider.Event
O75 := "a Start event" @Tau.Provider.Event.Start
O76 := "a TextStart event" @Tau.Provider.Event.TextStart
O77 := "a TextDelta event" @Tau.Provider.Event.TextDelta
O78 := "a TextEnd event" @Tau.Provider.Event.TextEnd
O79 := "a ThinkingStart event" @Tau.Provider.Event.ThinkingStart
O80 := "a ThinkingDelta event" @Tau.Provider.Event.ThinkingDelta
O81 := "a ThinkingEnd event" @Tau.Provider.Event.ThinkingEnd
O82 := "a ToolCallStart event" @Tau.Provider.Event.ToolCallStart
O83 := "a ToolCallDelta event" @Tau.Provider.Event.ToolCallDelta
O84 := "a ToolCallEnd event" @Tau.Provider.Event.ToolCallEnd
O85 := "a Done event" @Tau.Provider.Event.Done
O86 := "an Error event" @Tau.Provider.Event.Error
O87 := "the Anthropic adapter" @Tau.Providers.Anthropic
O88 := "the OpenAI Responses adapter" @Tau.Providers.OpenAI.Responses
O89 := "the OpenAI Chat adapter" @Tau.Providers.OpenAI.Chat
O90 := "the Gemini adapter" @Tau.Providers.Gemini
O91 := "the Bedrock adapter" @Tau.Providers.Bedrock
O92 := "the Azure OpenAI adapter" @Tau.Providers.AzureOpenAI
O93 := "the DeepSeek adapter" @Tau.Providers.DeepSeek
O94 := "the Groq adapter" @Tau.Providers.Groq
O95 := "the Mistral adapter" @Tau.Providers.Mistral
O96 := "the Custom adapter" @Tau.Providers.Custom
O97 := "the Replay adapter" @Tau.Providers.Replay
O98 := "a replay fixture" @-
O99 := "the streaming engine" @Tau.Providers.Shared.FinchStream
O100 := "a parsing mode" @-
O101 := "the SSE parser" @Tau.Providers.Shared.SSE
O102 := "an SSE event" @Tau.Providers.Shared.SSE.event
O103 := "the AWS event-stream parser" @Tau.Providers.Shared.AwsEventStream
O104 := "an AWS frame" @Tau.Providers.Shared.AwsEventStream.frame
O105 := "the OpenAI-Chat wire helper" @Tau.Providers.Shared.OpenAIChatWire
O106 := "the tool-spec normaliser" @Tau.Providers.Shared.ToolSpec
O107 := "the Gemini schema down-shifter" @Tau.Providers.Shared.ToolSpec.GeminiSubset
O108 := "the content transform" @Tau.Providers.Shared.ContentTransform
O109 := "the id sanitiser" @Tau.Providers.Shared.IdSanitizer
O110 := "the token estimator" @Tau.Providers.Shared.TokenEstimate
O111 := "the SigV4 signer" @Tau.Providers.Shared.SigV4
O112 := "an Anthropic auth result" @Tau.Providers.Anthropic.Auth
O113 := "an API-key tuple" @-
O114 := "an Anthropic OAuth credential" @-
O115 := "an auth error" @Tau.Providers.Anthropic.Auth.error
O116 := "the Copilot auth resolver" @Tau.Providers.Copilot.Auth
O117 := "a Copilot OAuth token" @Tau.Providers.Copilot.Auth.oauth_token
O118 := "a Copilot API token" @Tau.Providers.Copilot.Auth.api_token_info
O119 := "the Copilot token store" @Tau.Providers.Copilot.TokenStore
O120 := "the rate limiter" @Tau.Providers.RateLimiter
O121 := "a token bucket" @Tau.Providers.RateLimiter.TokenBucket
O122 := "the rate-limiter supervisor" @Tau.Providers.RateLimiter.Supervisor
O123 := "the rate-limiter reconciler" @Tau.Providers.RateLimiter.Supervisor.Reconciler
O124 := "an acquire outcome" @-
O125 := "the circuit breaker facade" @Tau.CircuitBreaker
O126 := "a breaker state" @Tau.CircuitBreaker.State
O127 := "a breaker state atom" @-
O128 := "the breaker store" @Tau.CircuitBreaker.Store
O129 := "a breaker ETS row" @-
O130 := "a call thunk" @-
O131 := "a usage map" @Tau.Provider.Event.Done.usage

## section: C — Tools, Sub-agents, Coding-agents, Hooks

O140 := "a tool" @Tau.Tool
O141 := "a tool name" @-
O142 := "a tool parameter schema" @-
O143 := "an execution mode" @-
O144 := "a tool call" @-
O145 := "a validated argument set" @Tau.Tool.Validator
O146 := "a tool context" @Tau.Tool.Context
O147 := "a tool result" @Tau.Tool.Result
O148 := "an operations backend" @Tau.Tools.Operations.Local
O149 := "the tools registry" @Tau.Tools.Registry
O150 := "the tool task supervisor" @Tau.Tools.TaskSupervisor
O151 := "the parallel tool dispatcher" @-
O152 := "the Read tool" @Tau.Tools.Builtin.Read
O153 := "the Write tool" @Tau.Tools.Builtin.Write
O154 := "the Edit tool" @Tau.Tools.Builtin.Edit
O155 := "the Bash tool" @Tau.Tools.Builtin.Bash
O156 := "the Agent tool" @Tau.Tools.Builtin.Agent
O157 := "the Delegate tool" @Tau.Tools.Builtin.Delegate
O158 := "a sub-agent" @-
O159 := "a parent session" @-
O160 := "a brief" @-
O161 := "a persona" @Tau.Skill
O162 := "a permissions mode" @-
O163 := "a child-parent registration" @-
O164 := "the coding agent behaviour" @Tau.CodingAgent
O165 := "the ClaudeCode adapter" @Tau.CodingAgents.ClaudeCode
O166 := "the CodingAgent Replay adapter" @Tau.CodingAgents.Replay
O167 := "the ClaudeCode argv builder" @Tau.CodingAgents.ClaudeCode.Argv
O168 := "the ClaudeCode stream-json parser" @Tau.CodingAgents.ClaudeCode.StreamJson
O169 := "a coding-agent task" @Tau.CodingAgent.task
O170 := "a coding-agent ctx" @Tau.CodingAgent.ctx
O171 := "a coding-agent event" @Tau.CodingAgent.Event
O172 := "a CodingAgent Done event" @Tau.CodingAgent.Event.Done
O173 := "a CodingAgent Cost event" @Tau.CodingAgent.Event.Cost
O174 := "a CodingAgent AssistantText event" @Tau.CodingAgent.Event.AssistantText
O175 := "a CodingAgent ToolUse event" @Tau.CodingAgent.Event.ToolUse
O176 := "a CodingAgent ToolResult event" @Tau.CodingAgent.Event.ToolResult
O177 := "a CodingAgent FileEdit event" @Tau.CodingAgent.Event.FileEdit
O178 := "a CodingAgent Start event" @Tau.CodingAgent.Event.Start
O179 := "a CodingAgent Error event" @Tau.CodingAgent.Event.Error
O180 := "the coding-agent dispatcher" @Tau.CodingAgent.Dispatcher
O181 := "the dispatcher drainer" @-
O182 := "the coding-agent supervisor" @Tau.CodingAgent.Supervisor
O183 := "a tagged cost record" @Tau.CodingAgent.Cost
O184 := "a workspace" @Tau.CodingAgent.Workspace
O185 := "the workspace behaviour" @Tau.CodingAgent.Workspace
O186 := "the git workspace backend" @Tau.CodingAgent.Workspace.Git
O187 := "the cwd workspace backend" @Tau.CodingAgent.Workspace.Cwd
O188 := "the tau-context MCP server" @Tau.CodingAgent.TauContext
O189 := "a tau-context token" @Tau.CodingAgent.TauContext.Auth
O190 := "a tau-context tool" @Tau.CodingAgent.TauContext.Tools
O191 := "the tau-context router" @Tau.CodingAgent.TauContext.Router
O192 := "a hook" @Tau.Hook
O193 := "a hook event" @Tau.Hook.event
O194 := "a hook payload" @-
O195 := "a hook result" @-
O196 := "a shell hook" @Tau.Hooks.Shell
O197 := "the hook dispatcher" @Tau.Hooks.Dispatcher
O198 := "the hooks registry" @Tau.Hooks.Registry
O199 := "a hook priority source" @-

## section: D — Runtime, Configuration, Telemetry, Delivery

O210 := "the application" @Tau.Application
O211 := "the root supervisor" @Tau.Supervisor
O212 := "a supervisor" @-
O213 := "a worker process" @-
O214 := "a restart strategy" @-
O215 := "the telemetry supervisor" @Tau.Telemetry.Supervisor
O216 := "the telemetry handlers worker" @Tau.Telemetry.Handlers
O217 := "the cost tracker" @Tau.Cost.Tracker
O218 := "the cost read API" @Tau.Cost
O219 := "a cost bucket key" @Tau.Cost.bucket_key
O220 := "a cost line item" @-
O221 := "a cost counters map" @Tau.Cost.counters
O222 := "the OTel reporter" @Tau.OtelReporter
O223 := "the OTel handler" @Tau.OtelReporter.Handler
O224 := "an OTel config" @Tau.OtelReporter.Config
O225 := "an open span" @-
O226 := "the PubSub" @Tau.PubSub
O227 := "a PubSub topic" @-
O228 := "the registries container" @Tau.Registries
O229 := "a registry" @-
O230 := "the sessions registry" @Tau.Sessions.Registry
O231 := "the commands registry" @Tau.Commands.Registry
O232 := "the skills registry" @Tau.Skills.Registry
O233 := "the MCP registry" @Tau.MCP.Registry
O234 := "the rate-limiter registry" @Tau.Providers.RateLimiter.Registry
O235 := "a registry keys mode" @-
O236 := "the settings cache" @Tau.Settings.Cache
O237 := "the settings watcher" @Tau.Settings.Watcher
O238 := "the settings loader" @Tau.Settings.Loader
O239 := "the settings accessor" @Tau.Settings
O240 := "a settings layer" @-
O241 := "the merged settings" @-
O242 := "the settings schema" @Tau.Settings.Schema
O243 := "a setting" @-
O244 := "the vault behaviour" @Tau.Settings.Vault
O245 := "a vault backend" @-
O246 := "the vault env backend" @Tau.Settings.Vault.Env
O247 := "the macOS keychain backend" @Tau.Settings.Vault.Keychain.Mac
O248 := "the Linux keychain backend" @Tau.Settings.Vault.Keychain.Linux
O249 := "the Windows keychain backend" @Tau.Settings.Vault.Keychain.Windows
O250 := "the memory supervisor" @Tau.Memory.Supervisor
O251 := "the memory store behaviour" @Tau.Memory.Store
O252 := "the SQLite memory store" @Tau.Memory.Store.SQLite
O253 := "a memory entry" @-
O254 := "an embedding status" @-
O255 := "the migrations module" @Tau.Memory.Migrations
O256 := "a migration" @-
O257 := "the memory loader" @Tau.Memory.Loader
O258 := "the embedder behaviour" @Tau.Memory.Embedder
O259 := "the embedding worker" @Tau.Memory.EmbeddingWorker
O260 := "the skills loader" @Tau.Skills.Loader
O261 := "the frontmatter parser" @Tau.Skills.Frontmatter
O262 := "the command behaviour" @Tau.Command
O263 := "the command context" @Tau.Command.Context
O264 := "the command spec binder" @Tau.Command.Spec
O265 := "a command spec entry" @Tau.Command.Spec.entry
O266 := "the builtin-command behaviour" @Tau.Commands.Builtin
O267 := "the command parser" @Tau.Commands.Parser
O268 := "the extensions loader" @Tau.Extensions.Loader
O269 := "the extension behaviour" @Tau.Extension
O270 := "the permission evaluator" @Tau.Permissions.Evaluator
O271 := "the permission rule-set" @Tau.Permissions.RuleSet
O272 := "the permission parser" @Tau.Permissions.Parser
O273 := "a permission rule" @-
O274 := "a permission decision" @-
O275 := "the mode lattice helper" @Tau.Permissions.Mode
O276 := "a lattice rank" @-
O277 := "the permission matcher behaviour" @Tau.Permissions.Matcher
O278 := "a matcher implementation" @Tau.Permissions.Matchers
O279 := "the always matcher" @Tau.Permissions.Matchers.Always
O280 := "the glob matcher" @Tau.Permissions.Matchers.Glob
O281 := "the path-prefix matcher" @Tau.Permissions.Matchers.PathPrefix
O282 := "the domain matcher" @Tau.Permissions.Matchers.Domain
O283 := "the regex matcher" @Tau.Permissions.Matchers.Regex
O284 := "the bash heuristics" @Tau.Permissions.Heuristics
O285 := "the CLI" @Tau.CLI
O286 := "a CLI subcommand" @-
O287 := "the CLI parser spec" @-
O288 := "an exit code" @-
O289 := "the CLI config surface" @Tau.CLI.Config
O290 := "the CLI init wizard" @Tau.CLI.Init
O291 := "the CLI init IO shim" @Tau.CLI.Init.IO
O292 := "the CLI extensions surface" @Tau.CLI.Extensions
O293 := "the CLI MCP surface" @Tau.CLI.MCP
O294 := "the TUI facade" @Tau.TUI
O295 := "the TUI supervisor" @Tau.TUI.Supervisor
O296 := "the TUI app" @Tau.TUI.App
O297 := "the TUI model" @-
O298 := "the runtime opts" @Tau.TUI.RuntimeOpts
O299 := "the event bridge" @Tau.TUI.EventBridge
O300 := "the markdown renderer" @Tau.Markdown
O301 := "the build provenance" @Tau.Build
O302 := "the Burrito relink-termbox step" @Tau.BurritoSteps.RelinkTermbox
O303 := "the MCP supervisor" @Tau.MCP.Supervisor
O304 := "the MCP server-supervisor" @Tau.MCP.ServerSupervisor
O305 := "the MCP reconciler" @Tau.MCP.Reconciler
O306 := "an MCP server" @Tau.MCP.Server
O307 := "the MCP tool adapter" @Tau.MCP.ToolAdapter
O308 := "the MCP transport behaviour" @Tau.MCP.Transport
O309 := "the MCP stdio transport" @Tau.MCP.Transport.Stdio
O310 := "the MCP http transport" @Tau.MCP.Transport.Http
O311 := "the MCP sse transport" @Tau.MCP.Transport.Sse
O312 := "the compactor behaviour" @Tau.Compactor
O313 := "the summarise-tail compactor" @Tau.Compactor.SummarizeTail
O314 := "the Finch pool" @Tau.Providers.Finch
O315 := "the sessions supervisor" @Tau.Sessions.Supervisor
O316 := "the file-system log filter" @Tau.Application
O317 := "a telemetry event" @-
O318 := "a turn" @-
O319 := "a data directory" @-
O320 := "a working directory" @-
O321 := "a model id" @-
O322 := "a request id" @-
O323 := "a settings sources map" @-
O324 := "a session list entry" @-
O325 := "a json-schema map" @-
O326 := "a content payload" @-

## section: E — Headless `tau run` (D-058 / AC-10 / #252 / Closes #213)

O327 := "the headless run invocation" @Tau.CLI.run_cmd
O328 := "the headless drain loop" @Tau.CLI.drain_run_loop
O329 := "the session-end drain helper" @Tau.CLI.drain_session_end
O330 := "the system-prompt source" @-
O331 := "the system-prompt text option" @-
O332 := "the system-prompt file option" @-
O333 := "the headless system-prompt skill" @Tau.CLI.build_headless_skill
O334 := "the headless failure stop-reason set" @-
O335 := "the content-first continuation predicate" @-

## section: F — Built-in slash commands (enumerated; cf. C47-style coproduct)

O340 := "the ping built-in command" @Tau.Commands.Builtin.Ping
O341 := "the tree built-in command" @Tau.Commands.Builtin.Tree
O342 := "the copy built-in command" @Tau.Commands.Builtin.Copy
O343 := "the export built-in command" @Tau.Commands.Builtin.Export
O344 := "the fork built-in command" @Tau.Commands.Builtin.Fork
O345 := "the clone built-in command" @Tau.Commands.Builtin.Clone
O346 := "the new built-in command" @Tau.Commands.Builtin.New
O347 := "the reload built-in command" @Tau.Commands.Builtin.Reload
O348 := "the logout built-in command" @Tau.Commands.Builtin.Logout
O349 := "the compact built-in command" @Tau.Commands.Builtin.Compact

# Morphisms

## section: A — Session / Message / Persistence

m1 : O1 -> O2 "is identified by"
m2 : O1 -> O3 "is currently in"
m3 : O1 -> O4 "holds"
m4 : O1 -> O5 "exposes"
m5 : O5 -> O3 "reports state"
m6 : O1 -> O70 "started under" [partial]
m7 : O1 -> O70 "was configured with original provider" [partial]
m8 : O1 -> O321 "targets model id"
m9 : O1 -> O320 "runs in working directory"
m10 : O1 -> O7 "carries user metadata"
m11 : O1 -> O43 "holds persona lifetime"
m12 : O1 -> O44 "restricts tools to whitelist"
m13 : O1 -> O42 "has active skill" [partial]
m14 : O1 -> O60 "accumulates history"
m15 : O60 -> O8 "yields each message"
m16 : O1 -> O45 "cascades to child set"
m17 : O1 -> O36 "persists through handle"
m18 : O1 -> O39 "writes to transcript"
m19 : O1 -> O40 "addresses transcript by path"
m20 : O1 -> O51 "counts tool-iterations"
m21 : O1 -> O52 "tracks compaction failures"
m22 : O1 -> O20 "drives the assembler" [partial]
m23 : O1 -> O46 "is tagged by stream run token" [partial]
m24 : O1 -> O47 "opens provider span ref" [partial]
m25 : O1 -> O48 "allocates cancel flag" [partial]
m26 : O318 -> O49 "derives fallback chain"
m27 : O1 -> O50 "holds tools-in-flight"
m28 : O1 -> O151 "drives parallel dispatcher" [partial]
m29 : O6 -> O2 "identifies session id"
m30 : O6 -> O320 "names working directory"
m31 : O6 -> O7 "carries user metadata" [partial]
m32 : O8 -> O12 "plays role"
m33 : O9 -> O326 "carries content"
m34 : O10 -> O13 "contains ordered blocks"
m35 : O10 -> O18 "ended with stop reason" [partial]
m36 : O10 -> O19 "reports usage"
m37 : O10 -> O70 "was produced by provider" [partial]
m38 : O10 -> O321 "names model" [partial]
m39 : O10 -> O321 "names response model" [partial]
m40 : O11 -> O17 "answers tool-call id (via id)"
m41 : O11 -> O141 "names tool"
m42 : O11 -> O326 "carries content"
m43 : O11 -> O147 "wraps tool result"
m44 : O17 -> O141 "invokes tool"
m45 : O20 -> O10 "builds assistant message"
m46 : O20 -> O21 "stages partial blocks"
m47 : O74 -> O20 "steps assembler (each event)"
m48 : O75 -> O322 "carries request id"
m49 : O75 -> O321 "negotiates model id"
m50 : O85 -> O18 "carries stop reason"
m51 : O85 -> O131 "carries usage map"
m52 : O86 -> O86 "carries reason"
m53 : O10 -> O26 "becomes message-end event"
m54 : O22 -> O2 "names session id"
m55 : O24 -> O10 "announces assistant message"
m56 : O25 -> O74 "wraps provider event"
m57 : O25 -> O10 "shows in-progress message"
m58 : O26 -> O10 "delivers assistant message"
m59 : O27 -> O17 "announces tool-call id"
m60 : O29 -> O11 "delivers tool result message"
m61 : O30 -> O30 "may name cancellation reason" [partial]
m62 : O31 -> O161 "names skill"
m63 : O31 -> O17 "may reference tool-call id" [partial]
m64 : O32 -> O326 "carries notice text"
m65 : O33 -> O33 "may carry termination reason" [partial]
m66 : O34 -> O70 "names from-provider"
m67 : O34 -> O70 "names to-provider"
m68 : O23 -> O70 "reports provider"
m69 : O37 -> O57 "is identified by event id"
m70 : O37 -> O58 "may reference parent event id" [partial]
m71 : O37 -> O59 "is tagged by kind"
m72 : O39 -> O38 "begins with header"
m73 : O38 -> O70 "records provider"
m74 : O38 -> O321 "records model"
m75 : O38 -> O41 "may reference fork point" [partial]
m76 : O37 -> O8 "replays into message (per kind)" [partial]
m77 : O1 -> O41 "forked from fork point" [partial]
m78 : O35 -> O56 "is implemented by JSONL"
m79 : O35 -> O36 "opens persistence handle"
m80 : O35 -> O40 "names path"
m81 : O56 -> O39 "appends to transcript"
m82 : O1 -> O45 "registers child sessions"
m83 : O53 -> O53 "tags outcome (5 clauses)"
m84 : O171 -> O1 "dispatched by session FSM"
m85 : O172 -> O18 "determines stop reason"
m86 : O178 -> O55 "may capture adapter state" [partial]
m87 : O1 -> O54 "classifies user input as slash command"

## section: B — Provider behaviour / events / streaming / reliability

m100 : O70 -> O321 "has default model"
m101 : O70 -> O73 "advertises capabilities"
m102 : O70 -> O74 "stream(messages,opts,ctx) yields events"
m103 : O70 -> O10 "chat(messages,opts,ctx) yields assistant" [partial]
m104 : O87 -> O70 "implements provider"
m105 : O88 -> O70 "implements provider"
m106 : O89 -> O70 "implements provider"
m107 : O90 -> O70 "implements provider"
m108 : O91 -> O70 "implements provider"
m109 : O92 -> O70 "implements provider"
m110 : O93 -> O70 "implements provider"
m111 : O94 -> O70 "implements provider"
m112 : O95 -> O70 "implements provider"
m113 : O96 -> O70 "implements provider"
m114 : O97 -> O70 "implements provider"
m115 : O71 -> O140 "names tool list" [partial]
m116 : O72 -> O48 "carries cancel flag" [partial]
m117 : O72 -> O322 "carries request id" [partial]
m118 : O72 -> O2 "carries session id" [partial]
m119 : O70 -> O99 "runs stream through engine"
m120 : O99 -> O100 "selects parsing mode"
m121 : O99 -> O101 "feeds SSE parser (in :sse mode)"
m122 : O101 -> O102 "parses chunk to SSE events"
m123 : O103 -> O104 "parses chunk to AWS frames"
m124 : O91 -> O104 "decodes frame to events"
m125 : O99 -> O86 "60s silence -> retryable timeout"
m126 : O99 -> O86 "non-2xx status -> Error"
m127 : O99 -> O120 "on 429 notifies rate limiter" [partial]
m128 : O99 -> O86 "on cancel-flag set emits :cancelled"
m129 : O89 -> O105 "builds body via wire helper"
m130 : O94 -> O105 "builds body via wire helper"
m131 : O93 -> O105 "builds body via wire helper"
m132 : O95 -> O105 "builds body via wire helper"
m133 : O92 -> O105 "builds body via wire helper"
m134 : O96 -> O105 "builds body via wire helper"
m135 : O105 -> O74 "decodes chunk to provider events"
m136 : O106 -> O140 "shapes tool for a provider"
m137 : O106 -> O107 "for Gemini down-shifts schema"
m138 : O107 -> O325 "drops oneOf/anyOf"
m139 : O108 -> O8 "transforms message list (from,to)"
m140 : O108 -> O16 "strips thinking blocks cross-provider"
m141 : O108 -> O15 "downgrades image to placeholder (non-vision)"
m142 : O108 -> O109 "delegates id rewriting"
m143 : O109 -> O17 "rewrites tool-call id for provider"
m144 : O110 -> O8 "estimates message list to token count"
m145 : O70 -> O120 "stream/3 acquires permit"
m146 : O120 -> O121 "holds RPM bucket"
m147 : O120 -> O121 "holds TPM bucket"
m148 : O121 -> O121 "take(n) -> {ok,b}|{wait,ms,b}"
m149 : O121 -> O121 "refill -> fuller bucket"
m150 : O121 -> O121 "halve -> smaller bucket (floor 1)"
m151 : O120 -> O121 "on 429 halves both buckets"
m152 : O120 -> O241 "reads sizes from settings"
m153 : O122 -> O120 "ensures one limiter per provider"
m154 : O123 -> O120 "reconciler reconciles to settings"
m155 : O125 -> O130 "wraps thunk for a provider"
m156 : O125 -> O127 "dispatches on breaker state atom"
m157 : O125 -> O124 ":open short-circuits to {error,:circuit_open}"
m158 : O125 -> O126 "records outcome via state transition"
m159 : O128 -> O129 "owns ETS table"
m160 : O128 -> O129 "ensures default :closed row per provider"
m161 : O128 -> O127 "reads provider state atom"
m162 : O128 -> O129 "bumps failure/success counter"
m163 : O128 -> O129 "CAS-transitions row to new state"
m164 : O128 -> O129 "CAS-admits exactly one half-open probe"
m165 : O126 -> O127 "check(now_ms) -> state atom"
m166 : O126 -> O126 "record_failure -> new state"
m167 : O126 -> O126 "record_success -> new state"
m168 : O129 -> O126 "projects to breaker state struct"
m169 : O87 -> O112 "resolves auth"
m170 : O112 -> O113 "may be api-key tuple" [partial]
m171 : O112 -> O114 "may be OAuth credential" [partial]
m172 : O112 -> O115 "may be auth error" [partial]
m173 : O116 -> O117 "resolves to OAuth token"
m174 : O116 -> O118 "exchanges OAuth for API token"
m175 : O116 -> O119 "delegates token issuance"
m176 : O119 -> O118 "holds API token" [partial]
m177 : O119 -> O119 "decides refresh-needed (<5min)"
m178 : O217 -> O220 "folds telemetry stop into line item"
m179 : O220 -> O219 "keyed by bucket key"
m180 : O218 -> O220 "aggregates a date to summary"
m181 : O218 -> O221 "aggregates a session to counters"
m182 : O100 -> O100 ":sse|:raw"
m183 : O90 -> O74 "decode_chunk yields events"
m184 : O87 -> O74 "decode yields events"
m185 : O88 -> O74 "decode yields events"
m186 : O170 -> O170 "carries cancel/request-id/timeout"
m187 : O98 -> O74 "is a recorded event list"

## section: C — Tools / Agents / Coding-agents / Hooks

m200 : O152 -> O140 "implements tool"
m201 : O153 -> O140 "implements tool"
m202 : O154 -> O140 "implements tool"
m203 : O155 -> O140 "implements tool"
m204 : O156 -> O140 "implements tool"
m205 : O157 -> O140 "implements tool"
m206 : O140 -> O141 "has public name"
m207 : O140 -> O142 "has parameter schema"
m208 : O142 -> O325 "is a JSON-Schema map"
m209 : O140 -> O143 "has execution mode"
m210 : O143 -> O143 ":sequential|:parallel"
m211 : O140 -> O140 "declares streams_updates?"
m212 : O141 -> O140 "looked up via Tool.lookup" [partial]
m213 : O140 -> O141 "registered under name"
m214 : O144 -> O141 "names tool"
m215 : O144 -> O144 "carries raw arguments"
m216 : O144 -> O145 "validated against schema"
m217 : O140 -> O325 "schema cached in persistent_term"
m218 : O144 -> O146 "dispatch builds context"
m219 : O145 -> O147 "execute(args,ctx) yields result-or-error"
m220 : O147 -> O326 "has model-facing content"
m221 : O147 -> O147 "has structured details"
m222 : O147 -> O147 "flags is_error"
m223 : O147 -> O147 "hints terminate"
m224 : O147 -> O11 "folded into tool-result message"
m225 : O146 -> O17 "names tool-call id"
m226 : O146 -> O2 "names session id"
m227 : O146 -> O48 "carries cancel ref" [partial]
m228 : O146 -> O148 "supplies operations backend"
m229 : O146 -> O146 "supplies emit closure"
m230 : O140 -> O148 "file tool delegates IO"
m231 : O151 -> O150 "runs under task supervisor"
m232 : O151 -> O151 "fans out via async_stream_nolink"
m233 : O144 -> O195 "pre-gated by :pre_tool_use"
m234 : O147 -> O195 "post-notifies :post_tool_use"
m235 : O156 -> O158 "spawns sub-agent"
m236 : O158 -> O159 "has parent session"
m237 : O158 -> O17 "spawned by tool-call id"
m238 : O156 -> O161 "resolves persona for type"
m239 : O161 -> O44 "supplies tools whitelist"
m240 : O161 -> O160 "supplies system-prompt addendum"
m241 : O162 -> O162 "(requested,parent) clamp -> mode"
m242 : O156 -> O160 "carries brief (description)"
m243 : O158 -> O147 "first :end_turn yields tool result"
m244 : O158 -> O147 "crash becomes is_error tool result"
m245 : O156 -> O159 "task monitors parent pid" [partial]
m246 : O156 -> O163 "registers child-parent link"
m247 : O157 -> O164 "resolves to coding agent" [partial]
m248 : O165 -> O164 "implements coding agent"
m249 : O166 -> O164 "implements coding agent"
m250 : O164 -> O73 "declares capabilities snapshot"
m251 : O164 -> O171 "start(task,ctx) yields event stream-or-error"
m252 : O157 -> O169 "builds task"
m253 : O157 -> O180 "starts dispatcher"
m254 : O180 -> O182 "runs under coding-agent supervisor"
m255 : O180 -> O181 "drains via linked drainer"
m256 : O180 -> O164 "invokes start/2"
m257 : O171 -> O171 "forwarded to subscriber pid"
m258 : O171 -> O172 "run terminates with Done"
m259 : O172 -> O172 "carries exit_status (-1 unexpected,-2 cancel)"
m260 : O173 -> O183 "tagged into cost record"
m261 : O183 -> O183 "has source tag (coding_agent.<agent>)"
m262 : O157 -> O184 "prepares workspace" [partial]
m263 : O184 -> O185 "prepared by backend"
m264 : O186 -> O185 "implements workspace"
m265 : O187 -> O185 "implements workspace"
m266 : O320 -> O185 "resolves default backend from cwd"
m267 : O184 -> O184 "has absolute path"
m268 : O180 -> O188 "may start tau-context MCP server" [partial]
m269 : O188 -> O189 "mints token"
m270 : O188 -> O180 "monitors owner dispatcher" [partial]
m271 : O188 -> O190 "exposes tau-context tools"
m272 : O188 -> O191 "routes JSON-RPC via Router"
m273 : O192 -> O193 "declares set of events"
m274 : O192 -> O195 "handle(event,payload) yields result"
m275 : O196 -> O243 "shell hook built from settings entry"
m276 : O196 -> O192 "is a hook"
m277 : O193 -> O197 "dispatched via dispatcher"
m278 : O197 -> O198 "looks up via hooks registry"
m279 : O192 -> O193 "registered under event"
m280 : O192 -> O199 "ordered by priority source"
m281 : O195 -> O151 "halt/deny aborts the action"
m282 : O156 -> O195 "pre-gated by :subagent_start"
m283 : O190 -> O190 "is exclusively MCP-surface (not Tau.Tool)"
m284 : O167 -> O169 "builds claude argv from task"
m285 : O168 -> O171 "decodes stream-json line to events"
m286 : O150 -> O212 "is a Task.Supervisor"

## section: D — Runtime / Supervision / Config / Telemetry / Delivery

m300 : O210 -> O211 "starts root supervisor"
m301 : O211 -> O214 "uses :rest_for_one"
m302 : O211 -> O215 "supervises telemetry supervisor"
m303 : O211 -> O222 "supervises OTel reporter" [partial]
m304 : O211 -> O226 "supervises PubSub"
m305 : O211 -> O228 "supervises registries container"
m306 : O211 -> O236 "supervises settings cache"
m307 : O211 -> O237 "supervises settings watcher"
m308 : O211 -> O250 "supervises memory supervisor"
m309 : O211 -> O271 "supervises permission rule-set"
m310 : O211 -> O314 "supervises Finch pool"
m311 : O211 -> O122 "supervises rate-limiter supervisor"
m312 : O211 -> O128 "supervises circuit-breaker store"
m313 : O211 -> O119 "supervises Copilot token store"
m314 : O211 -> O150 "supervises tools task supervisor"
m315 : O211 -> O268 "supervises extensions loader"
m316 : O211 -> O303 "supervises MCP supervisor"
m317 : O211 -> O182 "supervises coding-agent supervisor"
m318 : O211 -> O295 "supervises TUI supervisor"
m319 : O211 -> O315 "supervises sessions supervisor"
m320 : O215 -> O216 "supervises telemetry handlers worker"
m321 : O215 -> O217 "supervises cost tracker"
m322 : O228 -> O229 "supervises 7 registries"
m323 : O228 -> O149 "supervises tools registry"
m324 : O228 -> O198 "supervises hooks registry"
m325 : O228 -> O231 "supervises commands registry"
m326 : O228 -> O232 "supervises skills registry"
m327 : O228 -> O230 "supervises sessions registry"
m328 : O228 -> O233 "supervises MCP registry"
m329 : O228 -> O234 "supervises rate-limiter registry"
m330 : O250 -> O252 "supervises SQLite memory store"
m331 : O295 -> O296 "hosts TUI app (Ratatouille runtime)" [partial]
m332 : O212 -> O213 "has child (OTP relation)"
m333 : O229 -> O235 "has keys mode (:unique|:duplicate)"
m334 : O210 -> O316 "installs file-system log filter"
m335 : O210 -> O285 "may dispatch CLI" [partial]
m336 : O210 -> O317 "emits [:tau,:app,:ready]"
m337 : O285 -> O287 "parses with CLI parser spec"
m338 : O285 -> O286 "dispatches to subcommand"
m339 : O286 -> O288 "returns exit code"
m340 : O285 -> O70 "resolves provider module"
m341 : O285 -> O164 "resolves coding-agent module"
m342 : O285 -> O294 "launches TUI facade"
m343 : O294 -> O298 "sets runtime opts"
m344 : O294 -> O296 "runs TUI app"
m345 : O296 -> O298 "reads runtime opts"
m346 : O296 -> O299 "starts event bridge"
m347 : O296 -> O297 "has model"
m348 : O296 -> O297 "updates model (MVU)"
m349 : O299 -> O227 "subscribes to session topic"
m350 : O299 -> O230 "registers in sessions registry"
m351 : O296 -> O299 "drains on :tick"
m352 : O236 -> O238 "loads via settings loader"
m353 : O238 -> O240 "reads settings layer" [partial]
m354 : O238 -> O241 "produces merged settings"
m355 : O236 -> O241 "publishes to persistent_term"
m356 : O236 -> O227 "broadcasts on 'settings' topic"
m357 : O236 -> O317 "emits [:tau,:settings,:reloaded]"
m358 : O237 -> O236 "notifies cache on file change"
m359 : O239 -> O241 "reads merged settings (persistent_term)"
m360 : O239 -> O319 "resolves data directory"
m361 : O242 -> O243 "enumerates a setting (key)"
m362 : O242 -> O49 "resolves provider fallback chain" [partial]
m363 : O241 -> O245 "names vault backend"
m364 : O244 -> O245 "selects an implementation"
m365 : O246 -> O244 "implements vault"
m366 : O247 -> O244 "implements vault"
m367 : O248 -> O244 "implements vault"
m368 : O249 -> O244 "implements vault"
m369 : O271 -> O227 "subscribes to 'settings' topic"
m370 : O271 -> O272 "compiles via parser"
m371 : O272 -> O273 "maps pattern to rule" [partial]
m372 : O271 -> O273 "publishes rule-set tuple"
m373 : O270 -> O273 "reads rule-set tuple (caller-passed)"
m374 : O270 -> O274 "yields permission decision"
m375 : O273 -> O278 "names matcher implementation"
m376 : O278 -> O277 "implements matcher"
m377 : O279 -> O277 "implements matcher"
m378 : O280 -> O277 "implements matcher"
m379 : O281 -> O277 "implements matcher"
m380 : O282 -> O277 "implements matcher"
m381 : O283 -> O277 "implements matcher"
m382 : O278 -> O144 "tests call -> boolean"
m383 : O270 -> O162 "defaults via mode"
m384 : O284 -> O144 "classifies Bash arg -> boolean"
m385 : O275 -> O162 "ranks mode -> lattice rank"
m386 : O275 -> O162 "clamp(requested,parent) -> mode"
m387 : O162 -> O276 "has lattice rank"
m388 : O252 -> O251 "implements memory store"
m389 : O251 -> O252 "selects implementation"
m390 : O252 -> O255 "runs migrations in init"
m391 : O255 -> O256 "orders migrations"
m392 : O253 -> O254 "has embedding status"
m393 : O252 -> O258 "dispatches embedder"
m394 : O259 -> O258 "implements embedder"
m395 : O259 -> O252 "calls back store_embedding"
m396 : O252 -> O317 "emits [:tau,:memory,:*]"
m397 : O257 -> O257 "resolves TAU.md cascade"
m398 : O260 -> O161 "discovers a skill"
m399 : O260 -> O161 "parses SKILL.md to skill" [partial]
m400 : O260 -> O261 "uses frontmatter parser"
m401 : O161 -> O141 "whitelists tool names"
m402 : O267 -> O54 "parses user input to classification"
m403 : O267 -> O266 "looks up built-in command" [partial]
m404 : O267 -> O262 "looks up command (registry)" [partial]
m405 : O267 -> O161 "looks up skill" [partial]
m406 : O266 -> O53 "yields outcome"
m407 : O266 -> O141 "named by slash-command name"
m408 : O262 -> O263 "command context"
m409 : O262 -> O264 "binds spec entries"
m410 : O264 -> O265 "binds entries"
m411 : O268 -> O140 "registers tool"
m412 : O268 -> O192 "registers hook"
m413 : O268 -> O262 "registers command"
m414 : O268 -> O161 "registers skill"
m415 : O268 -> O269 "reads extension module"
m416 : O268 -> O317 "emits [:tau,:extensions,:reloaded]"
m417 : O222 -> O224 "loads OTel config"
m418 : O222 -> O317 "attaches telemetry events"
m419 : O223 -> O222 "casts to reporter"
m420 : O317 -> O225 "maps to open span" [partial]
m421 : O222 -> O225 "evicts oldest open span"
m422 : O222 -> O225 "sweeps stale open span"
m423 : O217 -> O220 "owns :tau_cost_counters ETS table"
m424 : O217 -> O317 "subscribes to [:tau,:provider,:request,:stop]"
m425 : O217 -> O317 "subscribes to [:tau,:coding_agent,:cost]"
m426 : O216 -> O317 "attaches telemetry events"
m427 : O217 -> O183 "folds CodingAgent.Cost via tagged record"
m428 : O222 -> O225 "is supervised; mutations only in reporter"
m429 : O296 -> O300 "renders markdown via Tau.Markdown"
m430 : O300 -> O326 "renders CommonMark to ASCII lines"
m431 : O318 -> O312 "may compact through compactor"
m432 : O313 -> O312 "implements compactor behaviour"
m433 : O312 -> O318 "should_compact?(usage,messages) -> bool"
m434 : O312 -> O60 "compact(messages,opts) -> rewritten history"
m435 : O301 -> O301 "stamps release version with git short-hash"
m436 : O302 -> O302 "relinks termbox via zig cc musl (Burrito post-patch)"
m437 : O303 -> O305 "supervises reconciler"
m438 : O303 -> O304 "supervises MCP server-supervisor"
m439 : O304 -> O306 "supervises each MCP server"
m440 : O305 -> O306 "starts/stops MCP servers from settings"
m441 : O306 -> O308 "uses transport"
m442 : O306 -> O307 "generates per-tool adapter module"
m443 : O307 -> O140 "is a Tau.Tool"
m444 : O307 -> O149 "registers in tools registry"
m445 : O309 -> O308 "implements stdio transport"
m446 : O310 -> O308 "implements http transport"
m447 : O311 -> O308 "implements sse transport"
m448 : O308 -> O308 "connect/send/recv/close"
m449 : O290 -> O291 "uses IO shim"
m450 : O289 -> O286 "is the config CLI surface"
m451 : O290 -> O286 "is the init wizard CLI surface"
m452 : O292 -> O286 "is the extensions CLI surface"
m453 : O293 -> O286 "is the MCP CLI surface"
m454 : O263 -> O146 "command context mirrors tool context"
m455 : O324 -> O6 "is a session metadata record"
m456 : O298 -> O298 "carries provider ctx (ADR-0002)"
m457 : O227 -> O22 "carries session lifecycle events"
m458 : O211 -> O217 "supervises cost tracker (indirect via O215)"
m459 : O22 -> O227 "broadcast on PubSub topic session:<id>"
m460 : O323 -> O241 "names source layer per setting"
m461 : O296 -> O8 "renders a message"
m462 : O296 -> O1 "sends user input to session"
m463 : O296 -> O1 "cancels session"
m464 : O299 -> O22 "forwards session event"

# Cross-slice boundary morphisms

(These were "boundary morphisms" in slice inventories; targets are now home
objects in some section. Every morphism is grounded.)

m500 : O318 -> O125 "turn consults circuit breaker"  ; D-043
m501 : O318 -> O108 "turn applies content transform on fallback"  ; ADR-0012
m502 : O17 -> O140 "tool-call block is executed by a tool"
m503 : O17 -> O270 "tool call is gated by permissions evaluator"
m504 : O17 -> O145 "tool call is validated by validator"
m505 : O151 -> O146 "execution runs a tool context"
m506 : O318 -> O312 "turn may compact through compactor"
m507 : O1 -> O257 "session injects context from memory cascade"
m508 : O1 -> O197 "session dispatches lifecycle hooks"
m509 : O318 -> O217 "stop telemetry feeds cost tracker"
m510 : O1 -> O35 "session persists through persistence behaviour"
m511 : O1 -> O180 "session routes turn to coding-agent dispatcher"
m512 : O180 -> O184 "coding-agent dispatcher runs in workspace"
m513 : O173 -> O183 "coding-agent Cost folds into tagged cost record"
m514 : O2 -> O2 "session id generated via Uniq.UUID.uuid7 (fallback random)"
m515 : O230 -> O1 "maps id to session FSM"
m516 : O299 -> O25 "forwards a message-update event"
m517 : O236 -> O120 "settings cache drives rate limiter sizes"
m518 : O236 -> O271 "settings cache drives permission rule-set"
m519 : O236 -> O305 "settings cache drives MCP reconciler"
m520 : O236 -> O268 "settings cache drives extensions loader"
m521 : O156 -> O158 "Agent tool spawns child = a Session (ADR-0014)"
m522 : O161 -> O42 "active skill is a Skill"
m523 : O55 -> O55 "coding-agent state preserves session_id across resume"

# section: E morphisms — headless run (D-058 / AC-10)

m524 : O285 -> O327 "CLI dispatches run subcommand to run_cmd/1"
m525 : O327 -> O287 "parses argv via CLI parser spec (Optimus)"
m526 : O327 -> O330 "resolves system-prompt source from options" [partial]
m527 : O331 -> O330 "--system-prompt text contributes a source" [partial]
m528 : O332 -> O330 "--system-prompt-file path contributes a source" [partial]
m529 : O330 -> O333 "build_headless_skill/2 lifts text to %Tau.Skill{}" [partial]
m530 : O333 -> O161 "is a %Tau.Skill{} (persona_lifetime :session)"
m531 : O327 -> O226 "subscribes to session:<id> BEFORE start_session (D-004)"
m532 : O327 -> O1 "Tau.start_session(opts) starts FSM"
m533 : O327 -> O1 "Tau.send(session_id, prompt) enqueues user_message"
m534 : O327 -> O328 "enters drain_run_loop/1"
m535 : O328 -> O26 "receives MessageEnd events from PubSub"
m536 : O328 -> O335 "decides continuation via content-first predicate"
m537 : O335 -> O17 "predicate true iff msg.content has any tool_call block"
m538 : O335 -> O328 "continuation true -> recurse (FSM dispatches tool)"
m539 : O328 -> O334 "tests msg.stop_reason against failure set"
m540 : O334 -> O18 "is a 4-element subset of stop_reason"
m541 : O328 -> O1 "calls Tau.stop(session_id) on every exit path (incl. timeout)"
m542 : O328 -> O329 "awaits drain_session_end (bounded 10s) after stop"
m543 : O329 -> O33 "receives SessionEnd to confirm JSONL flush"
m544 : O329 -> O288 "returns the exit code passed in"
m545 : O327 -> O288 "returns exit code (0 success / 1 failure)"
m546 : O328 -> O288 "yields exit code per decision rule"
m547 : O328 -> O326 "extract_assistant_text folds text blocks to stdout content"
m548 : O328 -> O326 "extract_error_text folds error_message or text blocks to stderr content"
m549 : O327 -> O333 "passes built skill as :active_skill opt to start_session" [partial]
m550 : O1 -> O42 "Session.init/1 folds opts[:active_skill] into data.skills before prepend_skill_messages/2"
m551 : O1 -> O56 "Tau.stop(session_id) triggers JSONL flush via SessionEnd"

# section: F morphisms — built-in slash command enumeration

m552 : O340 -> O266 "is a built-in command"
m553 : O341 -> O266 "is a built-in command"
m554 : O342 -> O266 "is a built-in command"
m555 : O343 -> O266 "is a built-in command"
m556 : O344 -> O266 "is a built-in command"
m557 : O345 -> O266 "is a built-in command"
m558 : O346 -> O266 "is a built-in command"
m559 : O347 -> O266 "is a built-in command"
m560 : O348 -> O266 "is a built-in command"
m561 : O349 -> O266 "is a built-in command (the sole :async_compact-producing one)"

# Constraints

C1. (FSM) O3 = `:awaiting_user + :provider_streaming + :tool_executing + :coding_agent_streaming + :compacting + :stopped`  ; D-019 SPEC-USER-TURN §6 — FSM coproduct (gen_statem :handle_event_function).

C2. (Registry) m1 : mono ; m515 : partial mono  ; [C2-B4] — session id is unique within the BEAM; cross-BEAM no exclusivity.

C3. m8 : total after init  ; D-002 — model = preload || opts || provider.default_model.

C4. (Single mutation site for model) every swap path equals do_swap_model(data,m)  ; D-041 [C54-B4] — swap_model gated to :awaiting_user with command_task==nil; else {:error,:busy}.

C5. (Visible-content guarantee) finalize_provider . assistant_assembler = finalize_coding_agent . ensure_visible_content  ; D-009 — both paths factor through Assembler.finalize; every finalized assistant has non-empty content.

C6. (Tool-iteration cap) the loop O3:provider_streaming -> O3:tool_executing -> O3:provider_streaming is bounded by O1.max_tool_iterations; overflow yields stop_reason :tool_loop_aborted and `[:tau,:session,:tool_iteration_cap]`; O51 resets to 0 on every return to :awaiting_user  ; D-027 AC-6 [C24].

C7. (Cap snapshot) max_tool_iterations is snapshotted at init; mid-session settings reloads do not change it  ; [C50] D-007.

C8. (Compaction failure counter) O52 increments on every {:error,_} from compactor across paths; >=3 -> stop_reason :compaction_failed; reset to 0 on success; NOT reset by :cancel; not path-tagged  ; D-016.

C9. (Compaction exit) every :compacting exit lands in :awaiting_user with compaction_task==nil ∧ compaction_monitor==nil (5 terminal clauses); clause 2a is the sole non-transition; clause ordering load-bearing  ; D-048 D-049 [C67-B4].

C10. (Built-in slash command does not drive a provider turn) {:notice,_} | {:mutate,_,_} | {:error,_} branches MUST NOT call process_user_message/2; only :passthrough proceeds; {:async_compact,_} is the sole state-changing built-in; built-in lookup precedes extension lookup  ; D-042 [C55-B4].

C11. (Stale-event drop) provider event folded iff data.stream_ref==ref; coding-agent event folded iff data.coding_agent_dispatcher==pid; retryable-error fallback clause MUST be source-ordered before generic :provider_event  ; ADR-0012.

C12. (Per-message fallback) data.original_provider invariant for session's life; data.provider shape-shifts during fallback; restored in finalize_assistant; fallback recursion terminates because each :start_provider pops one chain element  ; ADR-0012.

C13. (Provider-request span balance) for every `[:tau,:provider,:request,:start]` exactly one `*.stop|*.cancelled|*.brutal_kill`; emit_provider_request_terminal is idempotent when ref is nil; provider_span_ref reset to nil after terminal  ; D-057 SPEC-OTEL-REPORTER.

C14. (Role totality) m32 : total epi onto a 3-element set ; O8 = O9 + O10 + O11 — Tau.Message coproduct closed.

C15. (Tool-call ↔ tool-result bijection) within a turn each tool_call.id yields exactly one ToolResult (synthetic on {:exit,_}); :tool_executing -> :provider_streaming only when map_size(tools_in_flight)==0  ; #33.

C16. (Assembler purity) Assembler.step is a pure left fold: `step(.,e1) ; ... ; step(.,eN)` referentially transparent; ordering witnessed solely by Assembler.order; FSM (not assembler) broadcasts.

C17. (Event ordering assumption) provider events are assumed canonically ordered Start -> (Text*|Thinking*|ToolCall*) -> Done; assembler silently no-ops on unknown block ids; the SPEC asks for a warning, not implemented  ; [C9-B5].

C18. (Persistence) append-only; replay = map(event_to_message) |> reject(nil); session header is line 1 and excluded from message replay.

C19. (Resume convergence) m8 . resume = model_from_preload (last model_swap wins); coding_agent_state and costs mirror this  ; D-041.

C20. (Abnormal-exit persistence) on SIGKILL / BEAM crash a transcript may end without a terminating event; replay must tolerate truncated tail (out of scope SPEC §8)  ; [C32].

C21. (init ordering) messages = preload |> events_to_messages |> prepend_skill_messages(model_visible_skills) |> inject_memory(cwd); final order = [memory..., skills..., replayed history...]; disable_model_invocation:true skills filtered at two sites.

C22. (User-message ordering) {:user_message,_} cast received while command_task!=nil or FSM outside :awaiting_user is :postpone, re-delivered on next transition  ; ADR-0008 ADR-0009.

C23. O74 = O75 + O76 + O77 + O78 + O79 + O80 + O81 + O82 + O83 + O84 + O85 + O86  ; coproduct — provider event union (12 structs).

C24. O129 = provider × O127 × failure_count × success_count × opened_at_ms × probe_slot  ; product — breaker ETS row layout.

C25. O220 = O219 × {input,output,cache_read,cache_write}; O219 = date × O70 × O321 × O2  ; product.

C26. m165 : total deterministic  ; D-029 — `State.check/2` returns exactly one of :closed/:open/:half_open for any state and now_ms.

C27. (Probe admission exclusive) in :half_open at most one concurrent caller admitted as probe via :ets.select_replace probe_slot 0->1  ; D-030.

C28. (All-open chain) N providers all :open terminates in exactly N call/3 invocations each returning {:error,:circuit_open}; chain MUST NOT retry on :circuit_open  ; D-043.

C29. (ETS row layout immutable within schema version) positional 6-field layout MUST NOT be reordered without bumping @schema_version (currently 1); update_counter/select_replace hardcode positions 3 and 4  ; D-044.

C30. (Cost cohabitation) coding-agent Cost folds into :tau_cost_counters with provider slot = adapter module; :by_provider split without schema change  ; D-038.

C31. (Cost-fold errors degrade gracefully) mis-shaped cost measurement MUST NOT crash session; rescue wrapper emits `[:tau,:cost,:tracker,:handler_failed]`  ; D-035.

C32. (Copilot refresh) refresh when `expires_at - now < 5 min` (@refresh_threshold_ms = 5*60*1000)  ; D-056.

C33. (Anthropic auth) api_key uses x-api-key; OAuth uses Authorization Bearer + oauth-2025-04-20 beta header  ; D-017.

C34. (No Anthropic OAuth refresh) Tau does NOT refresh Anthropic OAuth tokens; an expired token surfaces an actionable error  ; D-018.

C35. (Azure auth) Azure OpenAI MUST use api-key header (not Bearer); deployment-based URL  ; C80.

C36. (Custom nil api_key) nil api_key valid for Custom (omits Authorization); sync hard error is {:error,:missing_base_url}  ; C81.

C37. (Thunk contract) circuit-breaker thunk MUST return {:ok,_}/{:error,_} and MUST NOT raise; exception bypasses breaker and propagates  ; [C65-B3].

C38. (Counter-ownership) failure/success counters mutated only by atomic update_counter bumps; Store.transition binds and writes them back unchanged via select_replace; record_outcome reconstructs pre-bump value as new_count-1  ; [C56-B1].

C39. (stream/3 contract) MUST NOT raise for user/network errors; transient failures arrive in-stream as Event.Error; only hard config errors return synchronous {:error,reason}  ; (code) Tau.Provider moduledoc.

C40. (Synchronous-error normalisation) Anthropic auth-resolver path {:error,:no_auth} -> {:error,:missing_api_key}; other adapters emit {:error,:missing_api_key|:missing_aws_credentials|:missing_base_url|:missing_endpoint|:missing_deployment|:rate_limited}.

C41. (chat/4 path equivalence) Tau.Provider.chat/4 = provider.chat/3 when exported else = drain(stream/3) through Assembler; in-stream Event.Error becomes {:error,reason} tagged tuple in chat path (vs synthetic %Assistant{stop_reason: :error} for streaming caller).

C42. (Stop-reason asymmetry) `wire stop -> Done.stop_reason` is NOT uniform: Anthropic and OpenAI-Chat map tool-ending turn to :tool_use; Gemini emits :stop even on functionCall; Bedrock and OpenAI Responses emit only :stop from terminal frames; tool-loop consumers on those three must inspect for emitted ToolCall* events  ; (code).

C43. (TextStart synthesis) OpenAI-Chat and Gemini wire formats have no TextStart/TextEnd analogue; OpenAIChatWire.decode injects synthetic TextStart before first non-empty delta and TextEnd/ThinkingEnd before Done; emitted sequence isomorphic to Anthropic block-lifecycle.

C44. (Replay opts out) Replay.stream/3 builds its own Stream.resource and never calls FinchStream or RateLimiter.acquire/3 — the one adapter factoring through neither.

C45. (Idempotence) m150 : `halve . halve = halve` and floors at size 1 (never 0); GeminiSubset.downshift idempotent; ContentTransform.transform with from==to reduces to id-sanitisation (no-op on compliant ids); Store.ensure_row idempotent (insert_new); IdSanitizer rewriting referentially transparent (stable hash).

C46. (Statelessness) processes in slice B = {O120, O122, O123, O128, O119, O217}; all other slice-B modules pure / processless.

C47. O140 = O152 + O153 + O154 + O155 + O156 + O157  ; coproduct — built-in tools all carry `@behaviour Tau.Tool` (subject to MCP adapter additions at runtime, which also implement O140 via m443).

C48. (Registry round-trip) register(mod) then lookup(name(mod)) = mod; under :duplicate keys all entries for a name hold the same module value; Tau.Tool.list/0 de-duplicates  ; [C-2] issue #250.

C49. (Validation precedes execution) tool_call -> validate -> (on :ok) execute; invalid call short-circuits to is_error ToolResult; persistent_term cache stores ONLY successful resolutions  ; [C-3] ADR-0003.

C50. (Tool dispatch pipeline) dispatch_tools/2 = __activate_skill__ . tools-whitelist . permissions . :pre_tool_use . parallel-fan-out . (per result) :post_tool_use; each earlier stage's reject branch lands directly in ToolResult preserving tool_call -> tool_result total correspondence  ; [C-4].

C51. (Parent/child not section/retraction) parent_session . child_of = id_on_subagent ; child_of . parent_session ≠ id (parent has many or zero children); relation is a forest with parent_session : subagent -> session total; fibres tracked by child_session_ids MapSet  ; [C-5] ADR-0014.

C52. (Cascade-cancel commutes) parent_terminates ⇒ child_terminates regardless of direction: Agent tool task monitors parent pid; parent :cancel/:stop cascades over child_session_ids  ; [C-6] ADR-0008 ADR-0014.

C53. (Permissions clamp monotonicity) m386 : `rank(clamp(r,p)) >= max(rank r, rank p)`; clamp idempotent; delegation cannot escalate safety posture (monotone across whole ancestor chain); a clamp that lowers requested mode emits `[:tau,:permissions,:ceiling_clamped]`  ; [C-7] ADR-0015 [C-D3].

C54. (Mode lattice) ranks 0..3; bypass(0) > auto(1) > default(2) > {accept_edits,dont_ask,plan}(3); tier-3 trio incomparable; clamp returns more-restrictive of (requested,parent); unknown requested -> parent; unknown parent -> :default (fail-safe).

C55. (Done terminal & always present) every coding-agent run yields exactly one Event.Done; dispatcher synthesises on stream-exhaustion, unrecoverable Error, drain crash, cancel, or inactivity timeout; ClaudeCode adapter terminal?/done_emitted? guard guarantees nothing emitted after  ; D-031.

C56. (Subprocess lifecycle bound to session) SIGTERM -> 250ms grace -> SIGKILL; tau-context MCP server monitors owner dispatcher (listener teardown on dispatcher death); session crash/ESC/shutdown -> subprocess termination, no exceptions  ; D-032.

C57. (Workspace path explicit & absolute) Workspace.prepare/1 validates `Path.absname(path) == path` ∧ `File.dir?(path)` before returning; dispatcher MUST NOT inherit tau's cwd silently; Delegate rejects relative paths  ; D-033.

C58. (Telemetry parity) coding-agent dispatcher emits `[:tau,:coding_agent,:start|:event|:stop|:exception]` mirroring provider span shape; hook dispatcher emits `[:tau,:hook,:run,:start|:stop|:exception]` with per-invocation span_ref  ; D-034.

C59. (Adapters and hooks never raise across boundary) adapter transport/auth/parse failures arrive in-stream as Event.Error; hard config errors return sync {:error,_} from start/2; dispatcher safe_start/3 and hook dispatcher try/rescue normalise escapes; unrecognised hook return logged and coerced to :cont  ; D-035.

C60. (Delegate depth bottoms out) check_depth/1 refuses depth >= @max_depth(2) with sync is_error ToolResult before any dispatcher starts; ceiling propagates via tau_context_max_depth = max(2 - depth, 0); Delegate calls stateless (no resume id persists across calls)  ; D-039 SPEC §7 Q5.

C61. (Cost-source tagging partition) Cost.source maps every tagged record to "coding_agent.<agent>"; provider-direct cost tagged "provider.<provider>"; the two tag families disjoint — coproduct decomposition of total spend  ; [C-14] D-038.

C62. (tau-context tools are NOT Tau.Tools) the four TauContext.Tools functions exposed exclusively over the per-run MCP listener; never enter Tau.Tools.Registry; parallel deliberately distinct tool object  ; [C-15].

C63. (Agent vs Delegate disjoint worker shapes) both spawn delegated worker and fold result into parent transcript; worker codomains differ — Agent's child is in-BEAM Tau.Session consuming tau provider credits; Delegate's child is an OS subprocess on its own subscription surface; share tool -> ToolResult codomain but not worker codomain  ; [C-16].

C64. (Supervision tree) the (supervises | has child) relation is a strict partial order; Tau.Supervisor is the unique maximum; every worker has exactly one parent  ; [C-D1].

C65. (Root restart strategy) Tau.Supervisor :rest_for_one — a child crash restarts that child AND every later child; 14-entry order is a topological sort of runtime dependency DAG: Telemetry < PubSub < Registries < Settings.{Cache,Watcher} < Memory < Permissions < Finch < RateLimiter < CircuitBreaker.Store < Copilot.TokenStore < Tools.TaskSupervisor < Extensions < MCP < CodingAgent < TUI < Sessions; inner supervisors use :one_for_one  ; [C-D2] ADR-0004.

C66. (Settings cascade) m354 = fold([managed,user,project,local], merge, %{}); merge associative on this fold but NOT commutative (override is order-sensitive); list_keys() ∈ {hooks,extensions,mcp,allow,deny,ask,permissions} CONCATENATE rather than replace; other lists replace; missing layers skipped; every type:"array" key in Schema must appear in Loader.list_keys()  ; [C-D4].

C67. (Settings publication commuting square) Cache.publish ⇒ (a) :persistent_term.put({Tau,:settings},_) AND (b) PubSub.broadcast("settings",{:settings_reloaded,settings}); for any subscriber S: Settings.get() = settings payload S receives; Permissions.RuleSet consumes this and recompiles  ; [C-D5] ADR-0002 ADR-0004.

C68. (Permission evaluation order) Evaluator.evaluate/5 cond: admin deny -> skill-gate -> :bypass -> allow -> ask -> per-mode default; first match wins; rule-set walked as flat list  ; [C-D6] ADR-0013.

C69. (Registry keys-mode invariants) Tools.Registry & Hooks.Registry :duplicate; all others :unique (Commands, Skills, Sessions, MCP, RateLimiter); :duplicate for Tools is load-bearing (issue #250) — built-in tools register per session; :unique would deregister tool when first registrant terminated; all registrants for a name hold same module so lookup resolves first entry; Sessions.Registry :unique makes session_id -> pid injective partial map  ; [C-D7].

C70. (Memory single-writer / migrations) D-045 — exactly one process holds Exqlite write conn (NIF ref); never escapes heap; all writes AND reads serialise through mailbox. D-047 — Migrations.run completes inside init/1 before {:ok,state}; failure returns {:stop,{:migration_failed,_}} hard-failing boot; append-only and idempotent. D-046 — embedding_status ∈ {"pending","ready","failed"}; FTS search/2 includes all; semantic_search/2 includes only "ready"; embedding network call runs OFF the owner via Tau.Tools.TaskSupervisor async_nolink; dispatch_embedding reply-then-continue guarantees mailbox open for store_embedding callback  ; [C-D8].

C71. (OTel reporter invariants) D-050 — runs only as supervised process; no module state. D-051 — open_spans map mutated ONLY in reporter GenServer; Handler is pure and only casts. D-053 — stale-span sweep on sweep_interval_ms force-finishes spans older than sweep_age_ms. D-054 — open_spans bounded by max_open_spans with oldest-first eviction (Enum.min_by on opened_at). D-055 — all OTel SDK calls compile-time-guarded by Code.ensure_loaded?(:otel_tracer). C70 — fixed (non-pid-scoped) handler id so restarted reporter can detach crashed instance's handler. C71 — *.stop with no span_ref cannot correlate and is discarded. Reporter child started iff otel.enabled  ; [C-D9].

C72. (CLI dispatch total) m338 . m337 . parse = case branch -> halt(code); each branch ends in halt(code) so CLI.main : argv -> exit_code is total; bare [] / unmatched ParseResult routes to tui_cmd (TUI default surface); resolve_provider and resolve_coding_agent total (known names -> concrete modules, else fall through to Module.concat synthetic atom)  ; [C-D10].

C73. (TUI event-sourced through bridge) Ratatouille 0.5.1 runtime forwards only declared subscriptions (here :tick) to update/2; EventBridge (one per session, registered in Sessions.Registry under {:tui_event_bridge, id}) subscribes to "session:<id>", queues broadcasts, App.update's :tick clause drains them; bridge MUST subscribe BEFORE Tau.start_session/1 returns since Session.init synchronously broadcasts %SessionStart{}; RuntimeOpts (:persistent_term) carries CLI flags into Ratatouille's fixed-arity App.init/1; cleared on session end  ; [C-D11] D-004.

C74. (Telemetry namespace) all Tau-emitted events under `[:tau, ...]`; :telemetry.execute is a no-op when nothing attached; Telemetry.Handlers attaches debug-Logger over full catalog; Cost.Tracker attaches to `[:tau,:provider,:request,:stop]` and `[:tau,:coding_agent,:cost]`; OtelReporter attaches mandatory span set + optional families; multiple handlers per event allowed and used  ; [C-D12].

C75. (MCP supervision tree) O303 = Supervisor (:one_for_one) over {O305, O304}; O304 = DynamicSupervisor for O306; each O306 init: open transport, send `initialize`, on reply list tools, for each tool generate O307 via Module.create/3 implementing O140, register in O149 under `mcp__<server>__<tool>` key  ; (code) lib/tau/mcp/*.

C76. (MCP transport behaviour) O308 = O309 + O310 + O311; callbacks connect/send/recv/close; transports use GenServer-callback API: connect returns state; send/recv mutate; close releases  ; (code) lib/tau/mcp/transport.ex.

C77. (Compactor defaults) m431 partial — runs only when threshold met; SummarizeTail.should_compact?(usage,messages) triggers on messages > :compaction_threshold_messages (default 50) OR usage.input_tokens > :compaction_threshold_tokens (default 120_000); compact replaces oldest 60% with a single synthetic %Tau.Message.User{} carrying `<conversation summary>` block; most recent 40% preserved verbatim so tool-result pairing not broken  ; (code) lib/tau/compactor/.

C78. (Build provenance) O301 stamps release version with git short-hash at compile time so Burrito runtime extraction-cache path (<app>_erts-<erts>_<release-version>) is unique per commit (issue #200); module recompiles when HEAD or index moves; module guarded on git existence  ; (code) lib/tau/build.ex.

C79. (Burrito relink-termbox) O302 runs Burrito post-`RecompileNIFs` patch phase for Linux only; uses `zig cc -target <cpu>-linux-musl` to relink termbox_bindings.so against musl libc (avoids __snprintf_chk glibc fortified symbols which fail to load in musl-based Burrito runtime)  ; (code) lib/tau/burrito_steps/relink_termbox.ex.

C80. (Markdown renderer scope) O300 renders CommonMark (with GFM tables) assistant text into ASCII-only terminal lines for Ratatouille transcript pane; replaces prior raw-text concatenation in TUI.App.on_message_end/2; tables align as ASCII pipe-and-plus grids; headers and lists get visible treatment without leaking raw markdown  ; D-028 [C52-B5].

C81. (Extension DSL) O269 provides `use Tau.Extension` macro DSL bundling tools/hooks/commands/skills; modules registered via Extensions.Loader at boot and on settings reloads  ; (code) lib/tau/extension.ex.

C82. (CLI subcommand surfaces) O286 = O289 + O290 + O292 + O293 + (others: run, resume, sessions, tui, mcp, doctor, ...); each surface is a module implementing the subcommand group; O290 uses O291 as IO shim (tests inject Agent-backed shim returning canned input)  ; (code) lib/tau/cli/.

C83. (Command/Tool context parity) O263 mirrors O146 for the slash-command surface so commands can make per-session decisions (consult :cwd, gate on session state)  ; (code) lib/tau/command/context.ex.

C84. (Sub-agent = session) ADR-0014 — a sub-agent IS a child Tau.Session (consequence: every Session morphism is reachable from a sub-agent via inclusion O158 ↪ O1); persona resolution and tools-whitelist are session-init-time concerns  ; ADR-0014.

C85. (Persona = skill) ADR-0015 — persona is a %Tau.Skill{}; subagent_type resolved against Skills.Registry; nil/general-purpose => no persona  ; ADR-0015.

C86. (Tool registry deduplication) under :duplicate keys, Tau.Tool.list/0 de-duplicates by name; concurrent registrations of the same name with conflicting modules would be a contract violation (currently a fact, not enforced)  ; (code) Tau.Tool.list/0 + issue #250.

C87. (MCP runtime tool extension) O140's coproduct decomposition (C47) is OPEN under runtime extension: each MCP server adds one O307 (Tau.Tool) per discovered MCP tool; MCP tools are namespaced `mcp__<server>__<tool>` to avoid collisions with built-ins or other servers.

C88. (Fallback chain termination) for chain of length N, recursion terminates in at most N+1 :start_provider entries because each entry pops one element; on the final empty chain the turn finalises with the last error  ; ADR-0012 (proof rephrased).

C89. (Headless FSM-backed `tau run`) O327 MUST drive a full O1 (start_session → send → drain → stop), NOT call O70.stream/3 directly; O327 MUST `Phoenix.PubSub.subscribe(Tau.PubSub, "session:<id>")` BEFORE Tau.start_session/1 returns (D-004 mirror); O1.stop MUST be called on every exit path INCLUDING the timeout branch; the timeout branch MUST also await O329 (bounded 10s) before returning; O328's decision rule: (1) CONTENT-FIRST — if `msg.content` carries any %{type: :tool_call} block, continue regardless of stop_reason (mirror of Session FSM dispatch_tools); (2) `msg.stop_reason ∈ O334 = {:error, :tool_loop_aborted, :aborted, :compaction_failed}` → exit 1; (3) any other stop_reason (`:stop, :length, :stop_sequence, :end_turn, :content_filter`, future atoms) → exit 0  ; D-058 AC-10 SPEC-USER-TURN §4 B2.

C90. (Content-first commutative square) m538 . m536 = Tau.Session.dispatch_tools/2 . content_has_tool_call : the headless drain loop's continuation predicate (m535 -> m536 -> m538) and the Session FSM's tool-dispatch decision MUST agree on the same condition (`Enum.any?(msg.content, &match?(%{type: :tool_call}, &1))`); divergence kills Gemini/Bedrock tool-loops since those providers emit `stop_reason: :stop` on tool-call turns; the canonical site is `lib/tau/session.ex` ~line 1806  ; D-058 (f-2 fix) AC-10.

C91. (Headless skill injection point) m549 . m530 = m550 : the headless skill (O333) wrapping --system-prompt text reaches the model-visible system blob ONLY via the `:active_skill` opt being PREPENDED to `data.skills` BEFORE `prepend_skill_messages/2` runs in Session.init/1; setting `data.active_skill` alone (eval_ctx gating) is NOT sufficient; the skill carries no `disable_model_invocation` flag and `:persona_lifetime :session` so it survives multi-turn iteration; O333 is consequently a member of O161 (m530) and m522 (active skill ↪ Skill) holds  ; D-058 AC-10 (f-2 amendment).

C92. (Built-in command coproduct, closed) O266 = O340 + O341 + O342 + O343 + O344 + O345 + O346 + O347 + O348 + O349 — the 10 built-in command modules under `lib/tau/commands/builtin/` enumerated by `Tau.Commands.Builtin.table/0`; m552..m561 wire each to O266; C10 (built-in slash command does not drive a provider turn) applies to every member; O349 (the compact built-in) is the SOLE producer of `{:async_compact, _}` outcomes per [C55-B4]  ; D-042 [C55-B4].

C93. (MCP runtime coproduct, OPEN — explicit decision) the decomposition of O140 is INTENTIONALLY OPEN: O140 = O152 + O153 + O154 + O155 + O156 + O157 + ⨆ {O307 instances generated per MCP server tool at runtime via `Module.create/3`}; the MCP set is determined at boot AND on every settings reload by O305 (the MCP reconciler) reading `mcp` settings; an olog interpreter MUST treat O307 as a runtime-extensible coproduct member, NOT enumerate generated modules statically. Decision rationale: MCP tools are discovered via JSON-RPC `tools/list` against an external process; their cardinality and identity is unknowable at compile time and changes with the operator's settings file. Static enumeration would either lie (frozen list) or be vacuous (one O<n> per never-seen tool). Compare to C92 (the built-in command set is small, stable, and code-resident — closed enumeration is sound there); the asymmetry is principled, not editorial  ; C47 C75 C87.

# Coverage

## Totals

- Objects: **318** (exact, verified by `grep -cE '^O[0-9]+ := '`). Allocated across sections A..F:
  - A (session/message/persistence): O1..O60 = 60 IDs
  - B (providers/reliability): O70..O131 = 62 IDs
  - C (tools/agents/coding-agents/hooks): O140..O199 = 60 IDs (intentional sparse — see ID map)
  - D (runtime/config/telemetry/delivery): O210..O326 = 117 IDs
  - E (headless `tau run`, NEW #252): O327..O335 = 9 IDs
  - F (built-in slash command enumeration, NEW): O340..O349 = 10 IDs
  - Gap markers (intentionally unused, reserved for future-stable global IDs): O61..O69, O132..O139, O200..O209, O336..O339, O350+. Mentions of O61/O69/O132/O139/O200/O209 in this prose are gap-boundary labels only — not morphism targets and not dangling.
- Morphisms: **489** (exact, verified by `grep -cE '^m[0-9]+ : O[0-9]+ -> O[0-9]+'`). Allocated across blocks:
  - Section A: m1..m87 (87 IDs, no gaps)
  - Section B: m100..m187 (88 IDs, no gaps; m88..m99 reserved)
  - Section C: m200..m286 (87 IDs, no gaps; m188..m199 reserved)
  - Section D: m300..m464 (165 IDs, no gaps; m287..m299, m465..m499 reserved)
  - Cross-slice: m500..m523 (24 IDs, no gaps)
  - Section E (NEW): m524..m551 (28 IDs)
  - Section F (NEW): m552..m561 (10 IDs)
  - Total = 87+88+87+165+24+28+10 = 489. Every source and every target is a defined O<n> (verified by set-difference: `grep -oE '\bO[0-9]+\b' | sort -u` ∖ `grep -oE '^O[0-9]+ := '` = ∅ apart from the 6 prose-only gap labels noted above).
- Constraints: **93** (exact, C1..C93), each tagged with D-NNN / [Cn-Bm] / ADR-NNNN / `(code)` and a ≤12-word gloss. New since v1: C89 (D-058 headless run contract), C90 (content-first commutative-square fact between drain loop and `Session.dispatch_tools/2`), C91 (headless skill injection point — Session.init/1 :active_skill fold), C92 (built-in command coproduct, NOW CLOSED), C93 (MCP runtime coproduct, EXPLICITLY OPEN — decision recorded).
- Boundary objects unified into existing home objects: every "FOREIGN" target in the four inventories is now a defined O<n> in this file (no dangling cross-slice references). Specifically: a circuit breaker, a content transform, a settings cascade, a settings cache, a tool, a tool validator, a permissions evaluator, a tool context, a tool result, a hooks dispatcher, a skill, a command parser, a builtin-command module, a compactor, a memory cascade, a persistence backend, a coding-agent dispatcher, a coding-agent workspace, a coding-agent cost record, a cost tracker, a PubSub topic, a TUI / stream consumer, a UUID generator (named in m514), telemetry events, the markdown renderer, the MCP server, the supervision tree.

## Promoted from boundary references (boundary objects with no home object in any inventory)

Promoted to first-class home objects in this olog because they were referenced by boundary morphisms but had no home object in any slice:

1. O300 the markdown renderer (`Tau.Markdown`) — referenced by Slice D as a foreign target of the TUI app; the inventories did not own it. Promoted because it is the rendering boundary for transcript pane content.
2. O303..O311 the MCP subsystem — the four inventories named "an MCP server" / "the MCP supervisor" only as boundary targets (Slice C's tau-context server is a *parallel* MCP server, NOT the regular one). The actual `lib/tau/mcp/` (Supervisor, ServerSupervisor, Reconciler, Server, ToolAdapter, Transport behaviour + Stdio/Http/Sse) is a fully-fledged subsystem and is given home objects here.
3. O312 / O313 the compactor — referenced as "a compactor" boundary by Slice A; `Tau.Compactor` behaviour and `SummarizeTail` default impl now have home objects.
4. O301 the build provenance (`Tau.Build`) — not in any inventory; relevant to Burrito release builds and the "fresh build never served from stale extraction" invariant (issue #200).
5. O302 the Burrito relink-termbox step (`Tau.BurritoSteps.RelinkTermbox`) — a build-time module relinking termbox_bindings.so against musl libc; named because it is necessary for the Burrito-packaged binary to function on Linux musl runtimes.
6. O167 / O168 the ClaudeCode argv builder and stream-json parser — Slice C named these in its "files read only at header level" list as pure helper morphisms; promoted to objects so the morphisms m284 / m285 have defined targets.
7. O263 / O264 / O265 the Command context, Spec binder, and spec entry — Slice D enumerated "a command spec entry" only; promoted Context and Spec binder so the command behaviour is fully described.
8. O284 the bash heuristics — Slice D listed it; given a home object for completeness.
9. O279..O283 the five concrete matcher implementations — Slice D listed "a matcher implementation" generically; promoted so the coproduct decomposition of O277 is explicit.
10. O246..O249 the four vault backends — Slice D listed "a vault backend" generically; promoted so the coproduct decomposition of O244 is explicit.
11. O289..O293 the CLI subcommand surfaces — Slice D listed the CLI config surface and CLI init wizard; promoted extensions and MCP surfaces likewise (`Tau.CLI.Extensions`, `Tau.CLI.MCP`) plus the init IO shim (`Tau.CLI.Init.IO`).
12. O56 the JSONL persistence backend (`Tau.Persistence.Jsonl`) — Slice A deferred to Persistence slice; given a home object so m78 has a defined target.
13. O327..O335 the headless-run subsystem (`Tau.CLI.run_cmd` and friends) — added 2026-05-19 to cover PR #253 (#252); these were not in any inventory because the headless path did not exist as a Session-FSM-backed surface until PR #253 (it previously called `provider.stream/3` directly, with no FSM, tools, or persistence). Promoted because they realise D-058 / AC-10 and form the second Tau.Session entry point alongside the TUI.
14. O340..O349 the 10 built-in slash-command modules — promoted 2026-05-19 from the prior "deliberate omission" status because the set is small, stable, and code-resident. Enumeration closes the C92 coproduct decomposition of O266 and makes `Builtin.table/0`'s contents a typed fact rather than a textual aside.

## `lib/tau/` directory coverage checklist

For each immediate subdirectory and top-level module of `lib/tau/`, this olog covers (✓) or explicitly omits:

- lib/tau.ex — covered as O1 (Tau is the public API; behavioural surface captured by m462/m463 and Tau.start_session/Tau.send/Tau.cancel/Tau.snapshot/Tau.stream/Tau.stop/Tau.resume/Tau.fork/Tau.list_sessions/Tau.swap_model/Tau.update_provider/Tau.register_child/Tau.unregister_child — these are functions on O1, not separate objects; m532/m533/m541/m551 wire the headless path through this surface).
- lib/tau/application.ex — ✓ O210 + boot constraints C64/C65.
- lib/tau/build.ex — ✓ O301 + C78.
- lib/tau/burrito_steps/ — ✓ O302 + C79 (single file relink_termbox.ex).
- lib/tau/circuit_breaker.ex + lib/tau/circuit_breaker/ — ✓ O125/O126/O128/O129/O127 + C26..C29.
- lib/tau/cli.ex + lib/tau/cli/ — ✓ O285..O293 + C72/C82; headless `run` subcommand additions ✓ O327..O335 + C89..C91 (NEW #252).
- lib/tau/coding_agent.ex + lib/tau/coding_agent/ — ✓ O164/O169..O191 + C55..C61.
- lib/tau/coding_agents/ — ✓ O165 (ClaudeCode) / O166 (Replay) / O167 (Argv) / O168 (StreamJson).
- lib/tau/command.ex + lib/tau/command/ — ✓ O262/O263/O264/O265 + C83.
- lib/tau/commands/ — ✓ O266 / O267 (parser); the 10 built-in command modules under `lib/tau/commands/builtin/` are NOW ENUMERATED as O340..O349 with m552..m561 wiring each to O266, and C92 closes the coproduct decomposition. Audit decision recorded: enumerated (not folded) because the set is small (10), stable (each is a code-resident module), and the explicit objects make `Builtin.table/0`'s coproduct a fact rather than a deliberate compression.
- lib/tau/compactor.ex + lib/tau/compactor/ — ✓ O312/O313 + C77.
- lib/tau/cost.ex + lib/tau/cost/ — ✓ O217/O218/O219/O220/O221 + C30/C31.
- lib/tau/extension.ex — ✓ O269 + C81.
- lib/tau/extensions/ — ✓ O268 (Extensions.Loader).
- lib/tau/hook.ex + lib/tau/hooks/ — ✓ O192..O199.
- lib/tau/markdown.ex — ✓ O300 + C80.
- lib/tau/mcp/ — ✓ O303..O311 + C75/C76.
- lib/tau/memory/ — ✓ O250..O259 + C70.
- lib/tau/message.ex + lib/tau/message/ — ✓ O8/O9/O10/O11/O20 + C14/C16.
- lib/tau/otel_reporter.ex + lib/tau/otel_reporter/ — ✓ O222/O223/O224 + C71.
- lib/tau/permissions/ — ✓ O270..O284 + C53/C54/C68.
- lib/tau/persistence.ex + lib/tau/persistence/ — ✓ O35/O56 + C18/C20.
- lib/tau/provider.ex + lib/tau/provider/ — ✓ O70..O86.
- lib/tau/providers/ — ✓ O87..O98 (adapters), O99..O111 (shared engine & utilities), O112..O119 (auth), O120..O123 (rate limiter), O131 (usage map).
- lib/tau/registries.ex — ✓ O228..O234 + C69.
- lib/tau/session.ex + lib/tau/session/ — ✓ O1..O55 + C1..C22.
- lib/tau/sessions/ — ✓ O315 (Sessions.Supervisor).
- lib/tau/settings.ex + lib/tau/settings/ — ✓ O236..O249 + C66/C67.
- lib/tau/skill.ex + lib/tau/skills/ — ✓ O161/O260/O261 + C85.
- lib/tau/telemetry/ — ✓ O215/O216 + C74.
- lib/tau/tool.ex + lib/tau/tool/ — ✓ O140..O148 + C47/C48/C49.
- lib/tau/tools/ — ✓ O149/O150 + O152..O157 (built-in tools).
- lib/tau/tui.ex + lib/tau/tui/ — ✓ O294..O299 + C73.

## Deliberate omissions (with reason)

The following are intentionally NOT given individual O<n> entries; each is justified:

- The individual `Tau.Session.Events.*` provider-fallback / message-update / message-end body shapes beyond the named struct: captured as O23..O34, sufficient for the lifecycle-event coproduct.
- `Tau.Sessions.Supervisor` is given O315 but its single dynamic-supervisor child shape is captured by m319.
- Pure helper functions inside modules (e.g. `Tau.Provider.chat/4` default body, `Tau.Persistence.impl/0`, `Tau.CLI.put_if_not_nil/3`, `Tau.CLI.extract_assistant_text/1`, `Tau.CLI.extract_error_text/1`) — these are *functions* on already-defined objects, not new objects. The extract_* and resolve_system_prompt/1 helpers are referenced from m547/m548/m526 and re-used at run_cmd/1's call site; their behaviour is captured by those morphism labels rather than reified into objects.
- Third-party modules (`Ratatouille.Runtime.Supervisor`, `Phoenix.PubSub`, `Finch`, `Optimus`, `Exqlite`, `Uniq.UUID`) — named in artifact references but not given home objects; they belong to library-boundary morphism targets (e.g. m331, m304, m310, m531 — Phoenix.PubSub.subscribe is the subscribe-before-start morphism on O327). The olog explicitly covers `Tau.PubSub` and `Tau.Providers.Finch` (Finch *named instance*) but not the Phoenix.PubSub or Finch *modules*.
- Per-MCP-tool `ToolAdapter` instances (one module per discovered MCP tool, generated at runtime via `Module.create/3`) — captured collectively as O307; individual generated modules are runtime instances of O307, not new schema objects. C93 records this as an EXPLICIT decision (vs. C92 which closes the built-in command coproduct).
- `lib/tau.ex` itself (the `Tau` module) — its public API is morphism boundary on O1; we cover the functions as morphisms (start_session/send/cancel/snapshot/stream/stop/resume/fork/list_sessions/swap_model/update_provider/register_child/unregister_child) rather than reifying the API module as an object.
- The 10 individual built-in slash-command modules under `lib/tau/commands/builtin/` are NO LONGER omitted — they are enumerated as O340..O349 (C92). This entry is preserved as a historical note: prior versions of the olog folded them into O266.

## Audit findings (post-#252 codebase walk, 2026-05-19)

Performed `ls -R lib/tau/ | grep '\.ex$'` and `git log --since='2026-05-12' --name-status -- lib/tau/`. Findings:

- The 5-commit diff of PR #253 (`a9a5de7..2930156`) touched only `lib/tau/cli.ex`, `lib/tau/session.ex`, `docs/spec/SPEC-USER-TURN.md`, and tests. All file-level additions are accounted for: O327..O335 cover the CLI run-loop additions; m550 covers the Session.init/1 `:active_skill` fold; no other production module changed.
- The full file-by-file walk confirms every `.ex` file under `lib/tau/` has a covering O<n> or is enumerated under "Deliberate omissions". The 10 built-in command modules previously absent are now O340..O349. No newly-added module since 2026-05-12 (Burrito relink-termbox, build-provenance, Copilot auth subsystem, OTel reporter, memory subsystem, all coding-agent modules, all coding_agents/*) is missing — each was promoted into the olog v1 already and is covered as cited in the directory-coverage checklist.
- `lib/tau/persistence/jsonl.ex` (O56) is also written by the headless path through `Tau.stop/1` → `SessionEnd` flush (m551, m543); the existing m81 ("appends to transcript") covers the write semantics — no new morphism is required because the headless path uses the same persistence handle as the TUI path.
- `lib/tau/sessions/{supervisor,registry}.ex` — O315 (Sessions.Supervisor) and O230 (Sessions.Registry) cover both; m319 and m327 wire them into the supervision tree. The headless path does not introduce a new registration shape; it goes through the same `Tau.start_session/1` entry point.
- Cross-checked against the synthesis agent's promotion list: markdown (O300), MCP (O303..O311), compactor (O312/O313), build (O301), burrito_steps (O302), extension (O269), CLI subcommands (O285..O293) — every one is present and wired.

## Confidence statement

The olog covers every immediate subdirectory and top-level module of `lib/tau/` (verified by `ls -R lib/tau/ | grep '\.ex$'` cross-check, 2026-05-19). Every morphism's source and target is a defined `O<n>` (verified by `grep -oE '\bO[0-9]+\b' | sort -u` set-difference against `^O[0-9]+ := ` declarations: 6 prose-only gap-marker mentions remain, all in the Coverage prose, none in any morphism — these are not dangling). Every `m<n>` referenced in a constraint path resolves to a declared morphism (verified the same way; no dangling). Every constraint in the four prior inventories is preserved here, with duplicates merged (e.g. the `:duplicate`-registry rationale appears as C48 + C69; the stop-reason asymmetry as C42; the permissions-clamp monotonicity as C53 + C54).

Residual doubts (after the 2026-05-19 audit):

1. **Resolved (was: morphism count approximate).** The exact morphism count is 489 (verified by `grep -cE '^m[0-9]+ : O[0-9]+ -> O[0-9]+'`). The Totals section now documents the per-block ID allocation explicitly so the count can be reproduced from the file.
2. **Resolved (was: built-in slash-command modules folded).** Now enumerated as O340..O349 with C92 closing the coproduct decomposition of O266.
3. **Decision recorded (was: MCP tools as open coproduct).** C93 makes the decision explicit: O140 stays OPEN under runtime extension via `Module.create/3`; the MCP set is determined at boot and on every settings reload by O305 (the MCP reconciler). Static enumeration would be unsound (cardinality and identity are unknowable at compile time). Compare to C92 — the built-in command set is closed because it is small, stable, and code-resident. The asymmetry is principled.
4. **Open (no change).** The `Tau.Persistence.Jsonl` backend (O56) `list/1` filtering and `fork/3` write-path mechanics remain captured as implementation details of m81 / m551; these are pure-function details not invariants worth a separate morphism.

Otherwise: yes, the olog describes every structure and relationship in `lib/tau/` that the four inventories enumerate AND every additional one surfaced by direct `lib/tau/` traversal AND the headless-`tau run` additions of PR #253 (#252).

# changelog

- **2026-05-19** — Incorporate PR #253 (#252) headless FSM-backed `tau run`; audit completeness. Added objects O327..O335 (headless run, drain loop, system-prompt source, headless skill, failure stop-reason set, content-first predicate) and O340..O349 (10 built-in slash-command modules enumerated). Added morphisms m524..m551 (headless run wiring) and m552..m561 (built-in coproduct edges). Added constraints C89 (D-058 headless run contract), C90 (content-first commutative-square fact), C91 (headless skill injection point — Session.init/1 fold), C92 (built-in command coproduct CLOSED), C93 (MCP runtime coproduct OPEN — decision recorded). Updated Coverage Totals to exact counts (318 objects, 489 morphisms, 93 constraints), added per-block ID allocation map, removed "approximate ~251" claim. Updated directory-coverage checklist for `lib/tau/cli.ex` (now references O327..O335) and `lib/tau/commands/` (now enumerated). Updated Deliberate omissions and Confidence statement to reflect resolutions of the three original residual doubts. Added Audit-findings section recording the 2026-05-19 codebase walk. Re-ran the dangling-reference check; zero dangling morphism references (6 prose-only O-ID mentions in gap-marker notes are not dangling).
