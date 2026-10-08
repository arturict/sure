# Names a chat from its first exchange with a cheap model that follows the
# chat's provider: Claude Haiku 5.5 for a chat on a Claude model, GPT-6 Luna
# otherwise. When that provider has no key, the other cheap model is used;
# with neither, there is no title and the chat keeps its placeholder.
#
# A custom endpoint (OpenAI-compatible URI base, Anthropic-compatible base
# URL) is skipped, because it is unlikely to serve these first-party ids.
class Chat::TitleGenerator
  CLAUDE_MODEL = "claude-haiku-5-5".freeze
  OPENAI_MODEL = "gpt-6-luna".freeze
  MAX_LENGTH = 80
  # Enough of the first answer to tell what the conversation is about.
  ANSWER_EXCERPT = 2_000

  INSTRUCTIONS = <<~PROMPT.freeze
    You name conversations between a user and a personal finance assistant.
    Reply with a title of at most six words that says what the conversation is
    about, written in the language the user wrote in. Reply with the title
    only: no quotes, no trailing punctuation, no prefix such as "Title:".
  PROMPT

  def initialize(chat)
    @chat = chat
  end

  # [provider_name, model] in order of preference for this chat.
  def candidates
    claude = [ :anthropic, CLAUDE_MODEL ]
    openai = [ :openai, OPENAI_MODEL ]
    chat_model.to_s.start_with?("claude") ? [ claude, openai ] : [ openai, claude ]
  end

  def provider_and_model
    candidates.each do |name, model|
      provider = registry.get_provider(name)
      next if provider.nil? || custom_endpoint?(provider)

      return [ provider, model ]
    end

    nil
  end

  # Returns the cleaned title, or nil when no model is available, the call
  # fails or the model declines. Never raises.
  def generate
    provider, model = provider_and_model
    return nil unless provider && first_prompt.present?

    response = provider.chat_response(
      conversation_excerpt,
      model: model,
      instructions: INSTRUCTIONS,
      reasoning_effort: "low",
      family: chat.user&.family
    )

    unless response.success?
      Rails.logger.warn("Chat title generation failed for chat #{chat.id} on #{model}: #{response.error.class}")
      return nil
    end

    clean(response.data.messages.map(&:output_text).join(" "))
  rescue StandardError => e
    Rails.logger.warn("Chat title generation failed for chat #{chat.id}: #{e.class}")
    nil
  end

  # Keeps the first line, drops wrapping quotes, a "Title:" prefix and
  # trailing punctuation, and caps the length. A refusal or stop notice is
  # not a title; the parser marks those, so anything that matches one is
  # discarded.
  def clean(text)
    title = text.to_s.strip.lines.first.to_s.strip
    return nil if stop_notices.include?(title)

    title = title.sub(/\A(?:title|titel)\s*:\s*/i, "")
    title = title.gsub(/\A["'„“”‚‘’«»*`]+|["'„“”‚‘’«»*`]+\z/, "").strip
    title = title.sub(/[.!?:;,]+\z/, "").strip
    title = title.truncate(MAX_LENGTH, separator: " ", omission: "") if title.length > MAX_LENGTH
    title.presence
  end

  private
    attr_reader :chat

    def registry
      Provider::Registry.for_concept(:llm)
    end

    def custom_endpoint?(provider)
      (provider.respond_to?(:custom_provider?) && provider.custom_provider?) ||
        (provider.respond_to?(:custom_endpoint?) && provider.custom_endpoint?)
    end

    def conversation_messages
      @conversation_messages ||= chat.conversation_messages.ordered.to_a
    end

    def first_prompt
      conversation_messages.find { |m| m.is_a?(UserMessage) }&.content
    end

    def first_answer
      conversation_messages.find { |m| m.is_a?(AssistantMessage) && m.complete? }&.content
    end

    def chat_model
      conversation_messages.find { |m| m.is_a?(UserMessage) }&.ai_model
    end

    def conversation_excerpt
      parts = [ "User: #{first_prompt}" ]
      parts << "Assistant: #{first_answer.to_s.first(ANSWER_EXCERPT)}" if first_answer.present?
      parts.join("\n\n")
    end

    def stop_notices
      [ I18n.t("chat.notices.refusal"), I18n.t("chat.notices.max_tokens") ]
    end
end
