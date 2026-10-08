require "test_helper"

class Chat::TitleGeneratorTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  def chat_on(model, prompt: "Wie viel habe ich im September für Lebensmittel ausgegeben?")
    chat = @user.chats.start!(prompt, model: model)
    chat.messages.create!(type: "AssistantMessage", content: "Im September waren es CHF 412.", ai_model: model, status: "complete")
    chat
  end

  def stub_providers(anthropic:, openai:)
    Provider::Registry.any_instance.stubs(:get_provider).with(:anthropic).returns(anthropic)
    Provider::Registry.any_instance.stubs(:get_provider).with(:openai).returns(openai)
  end

  def fake_provider(reply: "Lebensmittel im September", custom: false)
    provider = mock
    provider.stubs(:custom_endpoint?).returns(custom)
    provider.stubs(:custom_provider?).returns(custom)
    message = Provider::LlmConcept::ChatMessage.new(id: "m", output_text: reply)
    data = Provider::LlmConcept::ChatResponse.new(id: "r", model: "x", messages: [ message ], function_requests: [])
    provider.stubs(:chat_response).returns(Provider::Response.new(success?: true, data: data, error: nil))
    provider
  end

  test "a chat on a Claude model is named by Haiku 5.5" do
    anthropic = fake_provider
    stub_providers(anthropic: anthropic, openai: fake_provider)
    anthropic.expects(:chat_response).with { |text, **opts| opts[:model] == "claude-haiku-5-5" && opts[:reasoning_effort] == "low" && text.include?("CHF 412") }
      .returns(Provider::Response.new(success?: true, data: Provider::LlmConcept::ChatResponse.new(id: "r", model: "x", messages: [ Provider::LlmConcept::ChatMessage.new(id: "m", output_text: "Lebensmittel im September") ], function_requests: []), error: nil))

    assert_equal "Lebensmittel im September", Chat::TitleGenerator.new(chat_on("claude-sonnet-5-5")).generate
  end

  test "a chat on an OpenAI model is named by GPT-6 Luna" do
    stub_providers(anthropic: fake_provider, openai: fake_provider)

    provider, model = Chat::TitleGenerator.new(chat_on("gpt-6-luna")).provider_and_model
    assert_equal "gpt-6-luna", model
    assert provider
  end

  test "falls back to the other cheap model when the chat's provider has no key" do
    stub_providers(anthropic: nil, openai: fake_provider)
    assert_equal "gpt-6-luna", Chat::TitleGenerator.new(chat_on("claude-haiku-5-5")).provider_and_model.last

    stub_providers(anthropic: fake_provider, openai: nil)
    assert_equal "claude-haiku-5-5", Chat::TitleGenerator.new(chat_on("gpt-6-luna")).provider_and_model.last
  end

  test "custom endpoints are skipped, and with nothing left there is no title" do
    stub_providers(anthropic: nil, openai: fake_provider(custom: true))

    generator = Chat::TitleGenerator.new(chat_on("gpt-6-luna"))
    assert_nil generator.provider_and_model
    assert_nil generator.generate
  end

  test "a failed call or a refusal leaves no title" do
    failing = fake_provider
    failing.stubs(:chat_response).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Anthropic::Error.new("overloaded")))
    stub_providers(anthropic: failing, openai: nil)
    assert_nil Chat::TitleGenerator.new(chat_on("claude-haiku-5-5")).generate

    stub_providers(anthropic: fake_provider(reply: I18n.t("chat.notices.refusal")), openai: nil)
    assert_nil Chat::TitleGenerator.new(chat_on("claude-haiku-5-5")).generate
  end

  test "cleans quotes, prefixes, trailing punctuation and length" do
    generator = Chat::TitleGenerator.new(chat_on("gpt-6-luna"))

    assert_equal "Groceries in September", generator.clean("\"Groceries in September.\"")
    assert_equal "Ausgaben im September", generator.clean("Titel: „Ausgaben im September“\nmore")
    assert_operator generator.clean("word " * 40).length, :<=, Chat::TitleGenerator::MAX_LENGTH
    assert_nil generator.clean("  ")
  end
end
