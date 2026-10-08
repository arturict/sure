class Provider::Anthropic < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Anthropic::Error
  Error = Class.new(Provider::Error)

  # Supported Anthropic model prefixes
  DEFAULT_ANTHROPIC_MODEL_PREFIXES = %w[claude].freeze
  DEFAULT_MODEL = "claude-sonnet-4-6"

  # All Claude 3.5+ and 4.x models accept native document content blocks.
  VISION_CAPABLE_MODEL_PREFIXES = %w[claude].freeze

  # Offered in the chat composer next to the install's default model whenever
  # an Anthropic key is configured. Exact ids, no date suffix.
  CHAT_MODELS = %w[claude-haiku-5-5 claude-sonnet-5-5].freeze

  # The Claude 5 generation takes `output_config.effort` (low through max) and
  # thinks adaptively by default. Older Claude models either reject effort
  # (Haiku 4.5, Sonnet 4.5) or support a smaller set, so they get nothing.
  EFFORT_CAPABLE_MODEL_PATTERN = /\Aclaude-(?:haiku|sonnet|opus|fable)-5(?:-|\z)/

  # Sure's thinking-depth levels mapped onto Claude's effort levels. Thinking
  # cannot be switched off on Sonnet 5.5 (`disabled` is a 400) and is worse off
  # than on at low effort anyway, so "none" asks for the least thinking Claude
  # offers instead of being dropped.
  EFFORT_FOR_REASONING_LEVEL = {
    "none" => "low",
    "low" => "low",
    "medium" => "medium",
    "high" => "high",
    "xhigh" => "xhigh",
    "max" => "max"
  }.freeze

  # Room for adaptive thinking plus the answer. Chat always streams, so a large
  # ceiling cannot run into the SDK's request timeout, and only generated
  # tokens are billed. Haiku 5.5 at max effort used about 8K output tokens on
  # one round of a two-step finance question (observed 2026-10-08).
  DEFAULT_CHAT_MAX_TOKENS = 64_000

  # The SDK refuses a non-streaming request whose max_tokens could take longer
  # than its 10-minute timeout (about 21K tokens), so calls without a streamer,
  # such as title generation, get a ceiling below that.
  NONSTREAMING_MAX_TOKENS = 16_000

  def self.effective_model
    # Use ENV[].presence rather than ENV.fetch(KEY, default) so the Setting
    # lookup is only performed when the ENV var is actually absent — otherwise
    # the default arg is evaluated eagerly on every call.
    configured_model = ENV["ANTHROPIC_MODEL"].presence || Setting.anthropic_model
    configured_model.presence || DEFAULT_MODEL
  end

  def self.configured?
    ENV["ANTHROPIC_ACCESS_TOKEN"].present? ||
      ENV["ANTHROPIC_API_KEY"].present? ||
      Setting.anthropic_access_token.present?
  end

  # Claude models the composer may offer. A custom Anthropic-compatible
  # endpoint (Bedrock, Vertex, a proxy) uses its own model ids, so the
  # first-party ids are only offered against Anthropic itself.
  def self.chat_models
    return [] unless configured?
    return [] if (ENV["ANTHROPIC_BASE_URL"].presence || Setting.anthropic_base_url).present?

    CHAT_MODELS
  end

  def self.supports_effort?(model)
    model.to_s.match?(EFFORT_CAPABLE_MODEL_PATTERN)
  end

  # Translates the user's thinking-depth choice into an effort level, or nil
  # to leave the model on its own default (Haiku 5.5: medium, Sonnet 5.5: high).
  def self.effort_for(model, reasoning_effort)
    return nil unless supports_effort?(model)

    EFFORT_FOR_REASONING_LEVEL[reasoning_effort.to_s]
  end

  def initialize(access_token, base_url: nil, model: nil)
    client_options = { api_key: access_token }
    client_options[:base_url] = base_url if base_url.present?
    client_options[:timeout] = ENV.fetch("ANTHROPIC_REQUEST_TIMEOUT", 600).to_i

    @client = ::Anthropic::Client.new(**client_options)
    @base_url = base_url

    if custom_endpoint? && model.blank?
      raise Error, "Model is required when using a custom Anthropic-compatible endpoint"
    end

    @default_model = model.presence || DEFAULT_MODEL
    @tool_rounds = {}
  end

  def supports_model?(model)
    # Custom endpoints (Bedrock, Vertex, or other Anthropic-compatible proxies)
    # use their own model-ID conventions — e.g. Bedrock IDs look like
    # `anthropic.claude-sonnet-4-5-20250929-v1:0`. Mirror the OpenAI provider
    # and bypass the prefix gate when the caller has wired a custom base_url.
    return true if custom_endpoint?

    DEFAULT_ANTHROPIC_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def provider_name
    custom_endpoint? ? "Custom Anthropic-compatible (#{@base_url})" : "Anthropic"
  end

  def supported_models_description
    if custom_endpoint?
      "configured model: #{@default_model}"
    else
      "models starting with: #{DEFAULT_ANTHROPIC_MODEL_PREFIXES.join(', ')}"
    end
  end

  def custom_endpoint?
    @base_url.present?
  end

  def auto_categorize(transactions: [], user_categories: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error, "Too many transactions to auto-categorize. Max is 25 per request." if transactions.size > 25
      if user_categories.blank?
        family_id = family&.id || "unknown"
        Rails.logger.error("Cannot auto-categorize transactions for family #{family_id}: no categories available")
        raise Error, "No categories available for auto-categorization"
      end

      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "anthropic.auto_categorize",
        input: { transactions: transactions, user_categories: user_categories }
      )

      result = AutoCategorizer.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_categories: user_categories,
        langfuse_trace: trace,
        family: family
      ).auto_categorize

      upsert_langfuse_trace(trace: trace, output: result.map(&:to_h))

      result
    end
  end

  def auto_detect_merchants(transactions: [], user_merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error, "Too many transactions to auto-detect merchants. Max is 25 per request." if transactions.size > 25

      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "anthropic.auto_detect_merchants",
        input: { transactions: transactions, user_merchants: user_merchants }
      )

      result = AutoMerchantDetector.new(
        client,
        model: effective_model,
        transactions: transactions,
        user_merchants: user_merchants,
        langfuse_trace: trace,
        family: family
      ).auto_detect_merchants

      upsert_langfuse_trace(trace: trace, output: result.map(&:to_h))

      result
    end
  end

  def enhance_provider_merchants(merchants: [], model: "", family: nil, json_mode: nil)
    with_provider_response do
      raise Error, "Too many merchants to enhance. Max is 25 per request." if merchants.size > 25

      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "anthropic.enhance_provider_merchants",
        input: { merchants: merchants }
      )

      result = ProviderMerchantEnhancer.new(
        client,
        model: effective_model,
        merchants: merchants,
        langfuse_trace: trace,
        family: family
      ).enhance_merchants

      upsert_langfuse_trace(trace: trace, output: result.map(&:to_h))

      result
    end
  end

  def supports_pdf_processing?(model: @default_model)
    return true if custom_endpoint?

    VISION_CAPABLE_MODEL_PREFIXES.any? { |prefix| model.to_s.start_with?(prefix) }
  end

  def process_pdf(pdf_content:, model: "", family: nil)
    with_provider_response do
      effective_model = model.presence || @default_model
      raise Error, "Model does not support PDF processing: #{effective_model}" unless supports_pdf_processing?(model: effective_model)

      trace = create_langfuse_trace(
        name: "anthropic.process_pdf",
        input: { pdf_size: pdf_content&.bytesize }
      )

      result = PdfProcessor.new(
        client,
        model: effective_model,
        pdf_content: pdf_content,
        langfuse_trace: trace,
        family: family
      ).process

      upsert_langfuse_trace(trace: trace, output: result.to_h)

      result
    end
  end

  def extract_bank_statement(pdf_content:, model: "", family: nil)
    with_provider_response do
      effective_model = model.presence || @default_model

      trace = create_langfuse_trace(
        name: "anthropic.extract_bank_statement",
        input: { pdf_size: pdf_content&.bytesize }
      )

      result = BankStatementExtractor.new(
        client: client,
        pdf_content: pdf_content,
        model: effective_model,
        langfuse_trace: trace,
        family: family
      ).extract

      upsert_langfuse_trace(trace: trace, output: { transaction_count: result[:transactions].size })

      result
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil,
    family: nil,
    reasoning_effort: nil
  )
    with_provider_response do
      chat_config = ChatConfig.new(
        prompt: prompt,
        instructions: instructions,
        functions: functions,
        function_results: function_results,
        tool_choice: tool_choice,
        conversation_history: conversation_history,
        messages: tool_round_messages(previous_response_id, function_results),
        effort: self.class.effort_for(model, reasoning_effort),
        default_max_tokens: streamer.present? ? default_max_tokens : [ default_max_tokens, NONSTREAMING_MAX_TOKENS ].min
      )

      request_params = chat_config.build_request(model: model)

      trace = create_langfuse_trace(
        name: "anthropic.chat_response",
        input: { messages: request_params[:messages], system: request_params[:system_] },
        session_id: session_id,
        user_identifier: user_identifier
      )

      partial_usage_recorded = false

      begin
        raw, parsed, usage =
          if streamer.present?
            stream_chat_response(
              streamer: streamer,
              request_params: request_params,
              on_partial: ->(partial_usage) {
                record_llm_usage(family: family, model: model, operation: "chat", usage: partial_usage)
                partial_usage_recorded = true
              }
            )
          else
            sync_chat_response(request_params: request_params)
          end

        remember_tool_round(request_params[:messages], raw, parsed)

        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: request_params[:messages],
          output: parsed.messages.map(&:output_text).join("\n"),
          usage: usage,
          trace: trace
        )
        # Record once. On a normal stream `on_partial` never fires (it only runs
        # from stream_chat_response's rescue on a mid-stream error, which
        # re-raises past here), so today this is the sole recorder. Guard it
        # anyway so a future change that emits partial usage on success can't
        # silently double-bill — the symptom we chased in the #1984 review.
        record_llm_usage(family: family, model: model, operation: "chat", usage: usage) unless partial_usage_recorded

        parsed
      rescue => e
        log_langfuse_generation(
          name: "chat_response",
          model: model,
          input: request_params[:messages],
          error: e,
          trace: trace
        )
        record_llm_usage(family: family, model: model, operation: "chat", error: e) unless partial_usage_recorded
        raise
      end
    end
  end

  private
    attr_reader :client

    def default_max_tokens
      ENV.fetch("ANTHROPIC_MAX_TOKENS", DEFAULT_CHAT_MAX_TOKENS).to_i
    end

    # One assistant turn can take several tool rounds. With thinking on, every
    # round's request has to be the previous request's messages, unchanged,
    # plus that round's complete assistant content (thinking blocks and their
    # signatures included) and one user message carrying all of its tool
    # results. Rebuilding the transcript from stored records instead would
    # drop the thinking blocks and merge the rounds, which Claude 5.5 rejects
    # as an edited conversation.
    #
    # The transcript sent for each tool-using response is kept here, keyed by
    # the response id the responder hands back as previous_response_id. The
    # responder holds one provider instance for one assistant turn, so this
    # lives exactly as long as the turn's tool loop. Earlier turns are rebuilt
    # from records without their thinking, which drops a leading run of
    # thinking blocks and is allowed.
    def tool_round_messages(previous_response_id, function_results)
      return nil if previous_response_id.blank? || function_results.blank?

      transcript = @tool_rounds[previous_response_id]
      return nil unless transcript

      tool_use_ids = Array(transcript.last[:content]).filter_map { |block| block[:id] if block[:type] == "tool_use" }
      # The responder passes every result gathered so far in this turn; only
      # the ones answering the last round belong in the new user message, and
      # in the order the model asked for them.
      results = tool_use_ids.filter_map do |id|
        function_results.find { |result| result[:call_id] == id }
      end

      transcript + [ { role: "user", content: results.map { |result| MessageFormatter.tool_result_block(result) } } ]
    end

    def remember_tool_round(sent_messages, raw, parsed)
      return if parsed.function_requests.empty?

      @tool_rounds[parsed.id] = sent_messages + [ { role: "assistant", content: replay_content(raw) } ]
    end

    # The assistant content exactly as the model produced it, in request shape.
    # Thinking blocks go back verbatim, even with an empty `thinking` string
    # (the default display omits the text but the signature still counts).
    # A streamed tool_use carries its input as accumulated JSON text, which is
    # parsed here because the API wants an object.
    def replay_content(raw)
      Array(raw.content).filter_map do |block|
        case block_attr(block, :type).to_s
        when "thinking"
          { type: "thinking", thinking: block_attr(block, :thinking).to_s, signature: block_attr(block, :signature) }
        when "redacted_thinking"
          { type: "redacted_thinking", data: block_attr(block, :data) }
        when "text"
          text = block_attr(block, :text).to_s
          { type: "text", text: text } if text.present?
        when "tool_use"
          {
            type: "tool_use",
            id: block_attr(block, :id),
            name: block_attr(block, :name),
            input: MessageFormatter.parse_tool_input(block_attr(block, :input))
          }
        end
      end
    end

    def block_attr(block, key)
      if block.respond_to?(key)
        block.public_send(key)
      elsif block.is_a?(Hash)
        block[key] || block[key.to_s]
      end
    end

    def sync_chat_response(request_params:)
      raw = client.messages.create(**request_params)
      parsed = ChatParser.new(raw).parsed
      usage = build_usage_hash(raw.usage)
      [ raw, parsed, usage ]
    end

    def stream_chat_response(streamer:, request_params:, on_partial: nil)
      final_message = nil
      streamed_text = false
      stream = client.messages.stream(**request_params)

      # If `stream.each` raises mid-iteration (network drop, client abort),
      # we still want to surface whatever tokens accumulated so the cost
      # ledger doesn't lose partial-output billing.
      begin
        stream.each do |event|
          case event
          when ::Anthropic::Streaming::TextEvent
            streamed_text ||= event.text.present?
            streamer.call(
              Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: event.text, usage: nil)
            )
          when ::Anthropic::Streaming::MessageStopEvent
            final_message = event.message
          end
        end
      rescue => mid_stream_error
        partial = safe_accumulated_message(stream)
        on_partial&.call(build_usage_hash(partial&.usage)) if partial
        raise mid_stream_error
      end

      final_message ||= safe_accumulated_message(stream)
      parsed = ChatParser.new(final_message).parsed
      usage = build_usage_hash(final_message.usage)

      # The chat only keeps text that arrives as a stream chunk, so a notice
      # the parser adds (a refusal, a cut-off answer) has to be streamed too.
      if (notice = ChatParser.stop_notice(final_message))
        streamer.call(
          Provider::LlmConcept::ChatStreamChunk.new(type: "output_text", data: streamed_text ? "\n\n#{notice}" : notice, usage: nil)
        )
      end

      streamer.call(
        Provider::LlmConcept::ChatStreamChunk.new(type: "response", data: parsed, usage: usage)
      )

      [ final_message, parsed, usage ]
    end

    def safe_accumulated_message(stream)
      stream.accumulated_message
    rescue StandardError
      nil
    end

    def build_usage_hash(raw_usage)
      return {} unless raw_usage

      input = raw_usage.input_tokens.to_i
      output = raw_usage.output_tokens.to_i
      hash = {
        "input_tokens" => input,
        "output_tokens" => output,
        "total_tokens" => input + output
      }

      if raw_usage.respond_to?(:cache_creation_input_tokens) && raw_usage.cache_creation_input_tokens
        hash["cache_creation_input_tokens"] = raw_usage.cache_creation_input_tokens
      end
      if raw_usage.respond_to?(:cache_read_input_tokens) && raw_usage.cache_read_input_tokens
        hash["cache_read_input_tokens"] = raw_usage.cache_read_input_tokens
      end

      hash
    end

    def langfuse_client
      return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

      @langfuse_client ||= Langfuse.new
    end

    def create_langfuse_trace(name:, input:, session_id: nil, user_identifier: nil)
      return unless langfuse_client

      langfuse_client.trace(
        name: name,
        input: input,
        session_id: session_id,
        user_id: user_identifier,
        environment: Rails.env
      )
    rescue => e
      # Sanitized log (class + message only) — `e.full_message` bundles the
      # backtrace + cause chain, which on some SDK error types includes the
      # serialized request/response payload (model output, user prompt).
      Rails.logger.warn("Langfuse trace creation failed: #{e.class}: #{e.message}")
      nil
    end

    def log_langfuse_generation(name:, model:, input:, trace:, output: nil, usage: nil, error: nil)
      return unless langfuse_client

      generation = trace&.generation(
        name: name,
        model: model,
        input: input
      )

      if error
        generation&.end(
          output: { error: error.message, details: error.respond_to?(:details) ? error.details : nil },
          level: "ERROR"
        )
        upsert_langfuse_trace(trace: trace, output: { error: error.message }, level: "ERROR")
      else
        generation&.end(output: output, usage: usage)
        upsert_langfuse_trace(trace: trace, output: output)
      end
    rescue => e
      Rails.logger.warn("Langfuse logging failed: #{e.class}: #{e.message}")
    end

    def upsert_langfuse_trace(trace:, output:, level: nil)
      return unless langfuse_client && trace&.id

      payload = { id: trace.id, output: output }
      payload[:level] = level if level.present?

      langfuse_client.trace(**payload)
    rescue => e
      Rails.logger.warn("Langfuse trace upsert failed for trace_id=#{trace&.id}: #{e.class}: #{e.message}")
      nil
    end

    def record_llm_usage(family:, model:, operation:, usage: nil, error: nil)
      return unless family

      if error.present?
        http_status_code = extract_http_status_code(error)

        family.llm_usages.create!(
          provider: "anthropic",
          model: model,
          operation: operation,
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          estimated_cost: nil,
          metadata: {
            error: safe_error_message(error),
            http_status_code: http_status_code
          }
        )
        return
      end

      return unless usage

      prompt_tokens = usage["input_tokens"] || 0
      completion_tokens = usage["output_tokens"] || 0
      total_tokens = usage["total_tokens"] || (prompt_tokens + completion_tokens)

      estimated_cost = LlmUsage.calculate_cost(
        model: model,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        cache_creation_tokens: usage["cache_creation_input_tokens"],
        cache_read_tokens: usage["cache_read_input_tokens"]
      )

      family.llm_usages.create!(
        provider: "anthropic",
        model: model,
        operation: operation,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        cache_creation_tokens: usage["cache_creation_input_tokens"],
        cache_read_tokens: usage["cache_read_input_tokens"],
        estimated_cost: estimated_cost,
        metadata: {}
      )
    rescue => e
      Rails.logger.error("Failed to record LLM usage: #{e.message}")
    end

    def extract_http_status_code(error)
      if error.respond_to?(:status)
        error.status
      elsif error.respond_to?(:http_status)
        error.http_status
      elsif safe_error_message(error) =~ /(\d{3})/
        $1.to_i
      end
    end

    def safe_error_message(error)
      error&.message
    rescue => e
      "(message unavailable: #{e.class})"
    end
end
