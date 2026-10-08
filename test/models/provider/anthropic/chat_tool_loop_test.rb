require "test_helper"

# Drives the real Anthropic SDK client against stubbed HTTP, so what is asserted
# is the request JSON Claude would receive and the SSE stream it would send,
# not a mock of the SDK. The rules checked here are the ones Claude 5.5 answers
# with a 400 when broken: each tool round must extend the previous request
# unchanged, thinking blocks go back verbatim, all results of a round travel in
# one user message, and no thinking/sampling/forced tool_choice is sent.
class Provider::Anthropic::ChatToolLoopTest < ActiveSupport::TestCase
  MESSAGES_URL = "https://api.anthropic.com/v1/messages".freeze

  FUNCTIONS = [
    {
      name: "get_accounts",
      description: "Lists the user's accounts with balances",
      params_schema: { type: "object", properties: { kind: { type: "string" } }, required: [], additionalProperties: false },
      strict: true
    },
    {
      name: "get_balance_sheet",
      description: "Gets the user's balance sheet",
      params_schema: { type: "object", properties: {}, required: [], additionalProperties: false },
      strict: true
    }
  ].freeze

  setup do
    @provider = Provider::Anthropic.new("test-anthropic-token")
    @bodies = []
  end

  test "a three-round tool loop only ever appends to the transcript" do
    stub_rounds(
      sse_message(
        id: "msg_1",
        blocks: [
          [ :thinking, "", "sig-round-1" ],
          [ :text, "Let me look that up." ],
          [ :tool_use, "toolu_a", "get_accounts", '{"kind":', '"all"}' ],
          [ :tool_use, "toolu_b", "get_balance_sheet" ]
        ],
        stop_reason: "tool_use"
      ),
      sse_message(
        id: "msg_2",
        blocks: [
          [ :thinking, "", "sig-round-2" ],
          [ :tool_use, "toolu_c", "get_accounts", '{"kind":"depository"}' ]
        ],
        stop_reason: "tool_use"
      ),
      sse_message(id: "msg_3", blocks: [ [ :text, "You have two accounts." ] ], stop_reason: "end_turn")
    )

    first = chat("What are my balances?", reasoning_effort: "high")
    assert_equal %w[toolu_a toolu_b], first.function_requests.map(&:call_id)
    assert_equal({ "kind" => "all" }, JSON.parse(first.function_requests.first.function_args))

    round_one = [ result("toolu_a", "get_accounts", { kind: "all" }, [ { name: "Checking" } ]),
                  result("toolu_b", "get_balance_sheet", {}, { net_worth: 100 }) ]
    second = chat("What are my balances?", function_results: round_one, previous_response_id: first.id, reasoning_effort: "high")
    assert_equal %w[toolu_c], second.function_requests.map(&:call_id)

    # The responder hands Anthropic every result gathered so far in the turn.
    all_results = round_one + [ result("toolu_c", "get_accounts", { kind: "depository" }, []) ]
    third = chat("What are my balances?", function_results: all_results, previous_response_id: second.id, reasoning_effort: "high")
    assert_equal "You have two accounts.", third.messages.first.output_text

    first_body, second_body, third_body = @bodies

    # Each request is the previous one plus exactly two messages.
    assert_equal first_body["messages"], second_body["messages"].first(first_body["messages"].size)
    assert_equal second_body["messages"], third_body["messages"].first(second_body["messages"].size)
    assert_equal first_body["messages"].size + 2, second_body["messages"].size
    assert_equal second_body["messages"].size + 2, third_body["messages"].size

    assistant_round_one = second_body["messages"][-2]
    assert_equal "assistant", assistant_round_one["role"]
    assert_equal(
      [
        { "type" => "thinking", "thinking" => "", "signature" => "sig-round-1" },
        { "type" => "text", "text" => "Let me look that up." },
        { "type" => "tool_use", "id" => "toolu_a", "name" => "get_accounts", "input" => { "kind" => "all" } },
        { "type" => "tool_use", "id" => "toolu_b", "name" => "get_balance_sheet", "input" => {} }
      ],
      assistant_round_one["content"]
    )

    # Parallel calls are answered together, in the order they were asked.
    results_round_one = second_body["messages"].last
    assert_equal "user", results_round_one["role"]
    assert_equal %w[toolu_a toolu_b], results_round_one["content"].map { |b| b["tool_use_id"] }
    assert_equal [ "tool_result" ], results_round_one["content"].map { |b| b["type"] }.uniq

    # Round three answers only round two's call, not the accumulated ones.
    assert_equal %w[toolu_c], third_body["messages"].last["content"].map { |b| b["tool_use_id"] }
    assert_equal "sig-round-2", third_body["messages"][-2]["content"].first["signature"]

    @bodies.each do |body|
      assert_equal({ "effort" => "high" }, body["output_config"])
      assert_equal "claude-haiku-5-5", body["model"]
      assert_not body.key?("thinking"), "thinking must stay unset so Claude 5.5 thinks adaptively"
      assert_not body.key?("temperature")
      assert_not body.key?("top_p")
      assert_not body.key?("tool_choice"), "tool_choice is left at auto; forcing a tool is a 400 on Sonnet 5.5"
    end
  end

  test "the provider default effort sends no output_config, and none asks for low" do
    stub_rounds(sse_message(id: "msg_d", blocks: [ [ :text, "ok" ] ], stop_reason: "end_turn"),
                sse_message(id: "msg_n", blocks: [ [ :text, "ok" ] ], stop_reason: "end_turn"))

    chat("hi", reasoning_effort: nil)
    chat("hi", reasoning_effort: "none", model: "claude-sonnet-5-5")

    assert_not @bodies.first.key?("output_config")
    assert_equal({ "effort" => "low" }, @bodies.second["output_config"])
  end

  test "a refusal is streamed as a notice and runs no tools" do
    stub_rounds(sse_message(id: "msg_r", blocks: [], stop_reason: "refusal"))

    chunks = []
    response = chat("something declined", streamer: ->(chunk) { chunks << chunk })

    assert_empty response.function_requests
    texts = chunks.select { |c| c.type == "output_text" }.map(&:data)
    assert_equal [ I18n.t("chat.notices.refusal") ], texts
  end

  test "usage of a Claude 5.5 chat is recorded with its price" do
    family = families(:dylan_family)
    stub_rounds(sse_message(id: "msg_u", blocks: [ [ :text, "ok" ] ], stop_reason: "end_turn", input_tokens: 1_000, output_tokens: 500))

    assert_difference -> { family.llm_usages.count }, 1 do
      chat("hi", model: "claude-sonnet-5-5", family: family)
    end

    usage = family.llm_usages.order(:created_at).last
    assert_equal "anthropic", usage.provider
    assert_equal "claude-sonnet-5-5", usage.model
    # 1,000 in at USD 2 and 500 out at USD 10 per million tokens.
    assert_in_delta 0.007, usage.estimated_cost.to_f, 0.000001
  end

  private
    def chat(prompt, model: "claude-haiku-5-5", function_results: [], previous_response_id: nil, reasoning_effort: nil, streamer: nil, family: nil)
      response = @provider.chat_response(
        prompt,
        model: model,
        instructions: "You are a finance assistant.",
        functions: FUNCTIONS,
        function_results: function_results,
        conversation_history: [],
        previous_response_id: previous_response_id,
        reasoning_effort: reasoning_effort,
        streamer: streamer || ->(_chunk) { },
        family: family
      )
      assert response.success?, -> { response.error&.message }
      response.data
    end

    def result(call_id, name, arguments, output)
      { call_id: call_id, name: name, arguments: arguments.to_json, output: output }
    end

    def stub_rounds(*sse_bodies)
      responses = sse_bodies.map do |body|
        { status: 200, body: body, headers: { "Content-Type" => "text/event-stream" } }
      end

      stub_request(:post, MESSAGES_URL).to_return do |request|
        @bodies << JSON.parse(request.body)
        responses.shift || raise("unexpected request ##{@bodies.size}")
      end
    end

    # Builds the server-sent events of one streamed Messages response. Each
    # block is [:thinking, text, signature], [:text, text] or
    # [:tool_use, id, name, *partial_json_chunks].
    def sse_message(id:, blocks:, stop_reason:, input_tokens: 10, output_tokens: 20)
      events = []
      events << [ "message_start", {
        type: "message_start",
        message: {
          id: id, type: "message", role: "assistant", model: "claude-haiku-5-5", content: [],
          stop_reason: nil, stop_sequence: nil, stop_details: nil, container: nil,
          usage: { input_tokens: input_tokens, output_tokens: 1 }
        }
      } ]

      blocks.each_with_index do |(kind, *args), index|
        case kind
        when :thinking
          text, signature = args
          events << [ "content_block_start", { type: "content_block_start", index: index, content_block: { type: "thinking", thinking: "", signature: "" } } ]
          events << [ "content_block_delta", { type: "content_block_delta", index: index, delta: { type: "thinking_delta", thinking: text } } ] if text.present?
          events << [ "content_block_delta", { type: "content_block_delta", index: index, delta: { type: "signature_delta", signature: signature } } ]
        when :text
          events << [ "content_block_start", { type: "content_block_start", index: index, content_block: { type: "text", text: "" } } ]
          events << [ "content_block_delta", { type: "content_block_delta", index: index, delta: { type: "text_delta", text: args.first } } ]
        when :tool_use
          tool_id, name, *json_chunks = args
          events << [ "content_block_start", { type: "content_block_start", index: index, content_block: { type: "tool_use", id: tool_id, name: name, input: {} } } ]
          json_chunks.each do |chunk|
            events << [ "content_block_delta", { type: "content_block_delta", index: index, delta: { type: "input_json_delta", partial_json: chunk } } ]
          end
        end
        events << [ "content_block_stop", { type: "content_block_stop", index: index } ]
      end

      events << [ "message_delta", { type: "message_delta", delta: { stop_reason: stop_reason, stop_sequence: nil }, usage: { output_tokens: output_tokens } } ]
      events << [ "message_stop", { type: "message_stop" } ]

      events.map { |event, data| "event: #{event}\ndata: #{data.to_json}\n\n" }.join
    end
end
