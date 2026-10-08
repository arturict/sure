class Provider::Anthropic::ChatParser
  Error = Class.new(StandardError)

  # Text to show when the model stopped for a reason the user should know
  # about: a safety refusal (HTTP 200 with stop_reason "refusal") or an answer
  # cut off at max_tokens. nil for a normal stop.
  def self.stop_notice(message)
    case message.respond_to?(:stop_reason) ? message.stop_reason.to_s : ""
    when "refusal" then I18n.t("chat.notices.refusal")
    when "max_tokens" then I18n.t("chat.notices.max_tokens")
    end
  end

  def initialize(message)
    @message = message
  end

  def parsed
    ChatResponse.new(
      id: response_id,
      model: response_model,
      messages: messages,
      function_requests: function_requests
    )
  end

  private
    ChatResponse = Provider::LlmConcept::ChatResponse
    ChatMessage = Provider::LlmConcept::ChatMessage
    ChatFunctionRequest = Provider::LlmConcept::ChatFunctionRequest

    attr_reader :message

    def response_id
      message.id
    end

    def response_model
      message.model.to_s
    end

    def messages
      texts = content_blocks.select { |block| block_type(block) == :text }.map { |b| block_value(b, :text) }.compact
      texts << self.class.stop_notice(message) if self.class.stop_notice(message)
      return [] if texts.empty?

      [
        ChatMessage.new(
          id: response_id,
          output_text: texts.join("\n")
        )
      ]
    end

    def function_requests
      # A response that stopped early never finished its tool calls: a refusal
      # is not a request for data, and a tool_use cut off at max_tokens has
      # partial input. Running either would act on something the model did
      # not finish asking for.
      return [] if self.class.stop_notice(message)

      content_blocks
        .select { |block| block_type(block) == :tool_use }
        .map do |block|
          input = block_value(block, :input)
          ChatFunctionRequest.new(
            id: block_value(block, :id),
            call_id: block_value(block, :id),
            function_name: block_value(block, :name),
            # A tool_use block with no arguments streams in as an empty string.
            # Normalize it to an empty JSON object so downstream JSON.parse succeeds.
            function_args: input.is_a?(String) ? input.presence || "{}" : (input || {}).to_json
          )
        end
    end

    def content_blocks
      Array(message.content)
    end

    def block_type(block)
      raw = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
      raw.to_s.to_sym
    end

    def block_value(block, key)
      if block.respond_to?(key)
        block.public_send(key)
      elsif block.is_a?(Hash)
        block[key] || block[key.to_s]
      end
    end
end
