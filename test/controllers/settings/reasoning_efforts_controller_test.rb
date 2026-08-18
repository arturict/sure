require "test_helper"

class Settings::ReasoningEffortsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "stores a supported thinking depth" do
    patch settings_reasoning_effort_url, params: { reasoning_effort: "xhigh" }

    assert_response :redirect
    assert_equal "xhigh", @user.reload.ai_reasoning_effort
  end

  test "the default option clears the stored choice" do
    @user.update!(ai_reasoning_effort: "max")

    patch settings_reasoning_effort_url, params: { reasoning_effort: "" }

    assert_nil @user.reload.ai_reasoning_effort
  end

  test "a value the provider does not accept is refused rather than stored" do
    @user.update!(ai_reasoning_effort: "high")

    patch settings_reasoning_effort_url, params: { reasoning_effort: "turbo" }

    assert_nil @user.reload.ai_reasoning_effort
  end

  test "returns to the page the picker was used on" do
    patch settings_reasoning_effort_url,
          params: { reasoning_effort: "low" },
          headers: { "HTTP_REFERER" => chats_url }

    assert_redirected_to chats_url
  end
end
