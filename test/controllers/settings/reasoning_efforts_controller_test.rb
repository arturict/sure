require "test_helper"

class Settings::ReasoningEffortsControllerTest < ActionDispatch::IntegrationTest
  # What the browser actually sends when a link inside a Turbo Frame is
  # activated with data-turbo-method. Getting this wrong is what produced
  # "Content missing" in the chat sidebar: a redirect came back, the frame
  # found no matching frame in it, and Turbo blanked the panel.
  TURBO_FRAME_HEADERS = {
    "HTTP_ACCEPT" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
    "HTTP_TURBO_FRAME" => "sidebar_chat"
  }.freeze

  setup do
    sign_in @user = users(:family_admin)
  end

  test "a framed Turbo request gets a stream back, never a redirect" do
    patch settings_reasoning_effort_url,
          params: { reasoning_effort: "xhigh" },
          headers: TURBO_FRAME_HEADERS

    assert_response :success
    assert_equal Mime[:turbo_stream], response.media_type
    assert_no_match(/Content missing/i, response.body)
  end

  test "the stream replaces the picker with the newly chosen depth" do
    patch settings_reasoning_effort_url,
          params: { reasoning_effort: "low" },
          headers: TURBO_FRAME_HEADERS

    assert_match(/<turbo-stream action="replace" targets="#{Regexp.escape(UI::EffortPicker::TARGETS)}">/, response.body)
    assert_match I18n.t("messages.chat_form.effort_low"), response.body
  end

  test "every offered level survives the round trip" do
    UI::EffortPicker.new.levels.each do |level|
      patch settings_reasoning_effort_url,
            params: { reasoning_effort: level },
            headers: TURBO_FRAME_HEADERS

      assert_response :success, "level #{level.presence || 'default'} did not render"
      stored = @user.reload.ai_reasoning_effort
      level.present? ? assert_equal(level, stored) : assert_nil(stored)
      assert_match(/targets="#{Regexp.escape(UI::EffortPicker::TARGETS)}"/, response.body)
    end
  end

  test "a plain browser request still redirects back" do
    patch settings_reasoning_effort_url,
          params: { reasoning_effort: "high" },
          headers: { "HTTP_REFERER" => chats_url }

    assert_redirected_to chats_url
    assert_equal "high", @user.reload.ai_reasoning_effort
  end

  test "the default option clears the stored choice" do
    @user.update!(ai_reasoning_effort: "max")

    patch settings_reasoning_effort_url, params: { reasoning_effort: "" }, headers: TURBO_FRAME_HEADERS

    assert_nil @user.reload.ai_reasoning_effort
  end

  test "a value the provider does not accept is refused rather than stored" do
    @user.update!(ai_reasoning_effort: "high")

    patch settings_reasoning_effort_url, params: { reasoning_effort: "turbo" }, headers: TURBO_FRAME_HEADERS

    assert_nil @user.reload.ai_reasoning_effort
  end

  test "signed-out users cannot change the setting" do
    Session.destroy_all

    patch settings_reasoning_effort_url, params: { reasoning_effort: "max" }, headers: TURBO_FRAME_HEADERS

    assert_response :redirect
    assert_nil @user.reload.ai_reasoning_effort
  end
end
