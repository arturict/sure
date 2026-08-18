require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @chat = @user.chats.first
  end

  test "the composer's reasoning effort is stored on the user" do
    post chat_messages_url(@chat), params: {
      message: { content: "Hello", ai_model: "gpt-5.6-luna" },
      reasoning_effort: "xhigh"
    }

    assert_equal "xhigh", @user.reload.ai_reasoning_effort
  end

  test "an unrecognized reasoning effort clears rather than sticks" do
    @user.update!(ai_reasoning_effort: "high")

    post chat_messages_url(@chat), params: {
      message: { content: "Hello", ai_model: "gpt-5.6-luna" },
      reasoning_effort: "turbo"
    }

    assert_nil @user.reload.ai_reasoning_effort
  end

  test "omitting the reasoning effort leaves the stored choice alone" do
    @user.update!(ai_reasoning_effort: "max")

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-5.6-luna" } }

    assert_equal "max", @user.reload.ai_reasoning_effort
  end

  test "can create a message" do
    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_redirected_to chat_path(@chat, thinking: true)
  end

  test "cannot create a message if AI is disabled" do
    @user.update!(ai_enabled: false)

    post chat_messages_url(@chat), params: { message: { content: "Hello", ai_model: "gpt-4.1" } }

    assert_response :forbidden
  end

  test "report_timeout fails an undelivered assistant message" do
    BackgroundJobHealth.stubs(:snapshot).returns({})
    BackgroundJobHealth.stubs(:summary).returns("")

    pending = @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending, created_at: 5.minutes.ago)

    post report_timeout_chat_message_url(@chat, pending)

    assert_response :ok
    assert_not Message.exists?(pending.id)
    assert @chat.reload.error.present?
  end

  test "report_timeout cannot touch another user's chat" do
    other_chat = users(:family_member).chats.first
    pending = other_chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending)

    post report_timeout_chat_message_url(other_chat, pending)

    assert_response :not_found
    assert Message.exists?(pending.id)
  end
end
