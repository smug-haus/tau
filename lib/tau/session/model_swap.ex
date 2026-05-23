defmodule Tau.Session.ModelSwap do
  @moduledoc """
  Model swap and session reconfiguration helpers for `Tau.Session`.

  Provides the single `data.model` mutation site (`swap_model/2`) and the
  higher-level `apply_model_swap/2` that wires telemetry, persistence, and
  broadcast. Also handles the `:reconfigure` cast FSM clause and the
  `/model` slash-command path.

  ## Invariants

  - `data.model` has exactly one mutation site: `swap_model/2`.
  - A nil, empty, or whitespace-only model id is rejected with `{:error, :invalid_model}`.
  - Idempotent: swapping to the current model is a valid no-op (no rejection).
  - Busy-state rejection: `{:swap_model, _}` calls outside `:awaiting_user`
    (or with a command task in flight) return `{:error, :busy}`.
  """

  alias Tau.Session.Events

  @doc """
  Validate and apply a model swap to session data.

  Returns `{:ok, updated_data, old_model}` when `model` is a non-blank string,
  or `{:error, :invalid_model}` otherwise. Pure function — no side effects.
  """
  @spec swap_model(Tau.Session.Data.t(), String.t() | nil) ::
          {:ok, Tau.Session.Data.t(), String.t()} | {:error, :invalid_model}
  def swap_model(data, model) do
    if is_binary(model) and String.trim(model) != "" do
      {:ok, %{data | model: model}, data.model}
    else
      {:error, :invalid_model}
    end
  end

  @doc """
  Apply a model swap with telemetry, persistence, and broadcast.

  Used by both the `{:swap_model}` FSM call handler and the `/model`
  slash-command path (D-041). Returns `{:ok, updated_data, %{from:, to:}}`
  or `{:error, :invalid_model}`.
  """
  @spec apply_model_swap(Tau.Session.Data.t(), String.t() | nil) ::
          {:ok, Tau.Session.Data.t(), %{from: String.t(), to: String.t()}}
          | {:error, :invalid_model}
  def apply_model_swap(data, model) do
    case swap_model(data, model) do
      {:error, :invalid_model} ->
        {:error, :invalid_model}

      {:ok, data2, from_model} ->
        :telemetry.execute(
          [:tau, :session, :model_swapped],
          %{system_time: System.system_time()},
          %{session_id: data2.id, from: from_model, to: model, provider: data2.provider}
        )

        data2 =
          Tau.Session.Journal.persist(data2, "model_swap", %{"from" => from_model, "to" => model})

        Tau.Session.broadcast(data2.id, %Events.ModelSwapped{
          session_id: data2.id,
          from: from_model,
          to: model
        })

        {:ok, data2, %{from: from_model, to: model}}
    end
  end

  @doc """
  Route a `:reconfigure` model opt through `swap_model/2`.

  Returns data unchanged when `model` is `nil` — a provider-only reconfigure
  must not touch `data.model`.
  """
  @spec reconfigure_model(Tau.Session.Data.t(), String.t() | nil) :: Tau.Session.Data.t()
  def reconfigure_model(data, nil), do: data

  def reconfigure_model(data, model) do
    case swap_model(data, model) do
      {:ok, data2, _from} -> data2
      {:error, :invalid_model} -> data
    end
  end

  @doc """
  Replace `key` in `data` with `value`, or return `data` unchanged if `value`
  is `nil`. Helper for `{:reconfigure, opts}` processing.
  """
  @spec maybe_replace(Tau.Session.Data.t(), atom(), term()) :: Tau.Session.Data.t()
  def maybe_replace(data, _key, nil), do: data
  def maybe_replace(data, key, value), do: Map.put(data, key, value)

  @doc """
  Merge `ctx` map into `data.provider_ctx`, or return `data` unchanged if `ctx`
  is `nil`.
  """
  @spec merge_provider_ctx(Tau.Session.Data.t(), map() | nil) :: Tau.Session.Data.t()
  def merge_provider_ctx(data, nil), do: data

  def merge_provider_ctx(data, ctx) when is_map(ctx) do
    %{data | provider_ctx: Map.merge(data.provider_ctx || %{}, ctx)}
  end

  @doc """
  Handle the `/model <id>` slash-command inline.

  Runs `apply_model_swap/2` and broadcasts a `%SystemNotice{}` with the result.
  Returns an FSM action tuple.
  """
  @spec handle_slash_model_swap(Tau.Session.Data.t(), String.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_slash_model_swap(data, new_model) do
    case apply_model_swap(data, new_model) do
      {:ok, data2, %{from: from, to: to}} ->
        notice = "Model changed: #{from} → #{to}"
        Tau.Session.broadcast(data2.id, %Events.SystemNotice{session_id: data2.id, text: notice})
        {:keep_state, data2}

      {:error, :invalid_model} ->
        notice = "Error: '#{new_model}' is not a valid model id (empty or whitespace)."
        Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        {:keep_state, data}
    end
  end

  # --- FSM clause handlers ---------------------------------------------------

  @doc """
  Handle `{:swap_model, model}` call in `:awaiting_user` with no command task.
  """
  @spec handle_swap_model_idle(term(), String.t(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_swap_model_idle(from, model, data) do
    case apply_model_swap(data, model) do
      {:error, :invalid_model} ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_model}}]}

      {:ok, data2, result} ->
        {:keep_state, data2, [{:reply, from, {:ok, result}}]}
    end
  end

  @doc """
  Handle `{:swap_model, _}` call while the session is busy (any non-idle state,
  or `:awaiting_user` with a command task in flight).
  """
  @spec handle_swap_model_busy(term()) :: Tau.Session.Data.fsm_result()
  def handle_swap_model_busy(from) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  @doc """
  Handle `{:reconfigure, opts}` cast in any state.

  Applies provider, model, provider_ctx, and coding_agent_ctx opts.
  ADR-0012: `original_provider` is kept in lockstep with `provider` so the
  fallback chain for the next turn uses the new primary.
  """
  @spec handle_reconfigure(keyword(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_reconfigure(opts, data) do
    data =
      data
      |> maybe_replace(:provider, opts[:provider])
      # ADR-0012: keep original_provider in lockstep with the user-configured
      # provider. Reconfigure replaces both — fallback chains are looked up
      # keyed by the *new* primary on the next turn.
      |> maybe_replace(:original_provider, opts[:provider])
      |> reconfigure_model(opts[:model])
      |> merge_provider_ctx(opts[:provider_ctx])
      # SPEC-CODING-AGENT: reconfigure may also adjust the coding-agent ctx.
      |> maybe_replace(:coding_agent_ctx, opts[:coding_agent_ctx])

    :telemetry.execute(
      [:tau, :session, :reconfigure],
      %{system_time: System.system_time()},
      %{session_id: data.id, provider: data.provider, model: data.model}
    )

    data =
      Tau.Session.Journal.persist(data, "reconfigure", %{
        provider: inspect(data.provider),
        model: data.model
      })

    {:keep_state, data}
  end
end
