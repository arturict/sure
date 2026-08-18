require "application_system_test_case"

class ChatsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as(@user)
  end

  # Driven in a real browser on purpose. The picker's request is issued by Turbo
  # from inside the chat's frame, and no controller or component test reproduces
  # that: an earlier version passed both while the panel blanked with Turbo's
  # "Content missing" on the first real click.
  #
  # Both entry points are covered because they are not the same frame. On a chat
  # page the frame holds the chat directly; on the dashboard it is lazy with a
  # `src`, which is where the failure was actually seen.
  def prepare_reasoning_chat
    @user.update!(ai_enabled: true, preferences: (@user.preferences || {}).merge("ai_reasoning_effort" => nil))
    chat = @user.chats.first
    # The composer offers the picker only for a reasoning-capable model, and it
    # takes that from the conversation's last message rather than the install
    # default, so the fixture's gpt-4.1 has to move too.
    chat.messages.update_all(ai_model: "gpt-5.6-luna")
    chat
  end

  # A chat page renders the composer twice — main column and sidebar — so the
  # picker is addressed within the sidebar and then asserted on *every* copy.
  # That is the assertion that catches a same-id replace updating only one.
  def choose_depth(label_key)
    label = I18n.t("messages.chat_form.#{label_key}")

    within "#chat-container" do
      find(".chat-effort-picker button").click
      click_on label
    end

    assert_no_text "Content missing"
    assert_selector ".chat-effort-picker", text: label, minimum: 1
    all(".chat-effort-picker").each { |picker| assert_equal label, picker.text.strip }
  end

  test "changing the thinking depth from a chat page keeps the panel intact" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token", OPENAI_MODEL: "gpt-5.6-luna" do
      visit chat_url(prepare_reasoning_chat)

      choose_depth("effort_high")

      assert_selector "#chat-form textarea"
      assert_equal "high", @user.reload.ai_reasoning_effort
    end
  end

  test "changing the thinking depth from the dashboard keeps the panel intact" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token", OPENAI_MODEL: "gpt-5.6-luna" do
      chat = prepare_reasoning_chat
      @user.update!(last_viewed_chat: chat) if @user.respond_to?(:last_viewed_chat=)

      visit root_url
      assert_selector ".chat-effort-picker"

      choose_depth("effort_max")

      assert_selector "#chat-form textarea"
      assert_equal "max", @user.reload.ai_reasoning_effort
    end
  end

  test "the chat stays usable after switching depth twice" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token", OPENAI_MODEL: "gpt-5.6-luna" do
      visit chat_url(prepare_reasoning_chat)

      choose_depth("effort_max")
      choose_depth("effort_low")

      assert_equal "low", @user.reload.ai_reasoning_effort
      assert_selector "#chat-form textarea"
    end
  end

  test "sidebar shows consent if ai is disabled for user" do
    @user.update!(ai_enabled: false)

    visit root_path

    within "#chat-container" do
      assert_selector "h3", text: "Enable AI Chats"
    end
  end

  test "sidebar shows index when enabled and chats are empty" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.update!(ai_enabled: true)
      @user.chats.destroy_all

      visit root_url

      within "#chat-container" do
        assert_selector "h1", text: "Chats"
      end
    end
  end

  test "sidebar shows last viewed chat" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      chat = @user.chats.first
      @user.update!(ai_enabled: true, last_viewed_chat: chat)

      visit root_url

      within "#chat-container" do
        assert_selector "h1", text: chat.title
      end
    end
  end

  test "create chat and navigate chats sidebar" do
    with_env_overrides OPENAI_ACCESS_TOKEN: "test-token" do
      @user.chats.destroy_all

      visit root_url

      Chat.any_instance.expects(:ask_assistant_later).once

      within "#chat-form" do
        fill_in "chat[content]", with: "Can you help with my finances?"
        find("button[type='submit']").click
      end

      assert_text "Can you help with my finances?"

      find("#chat-nav-back").click

      assert_selector "h1", text: "Chats"

      click_on @user.chats.reload.first.title

      assert_text "Can you help with my finances?"
    end
  end
end
