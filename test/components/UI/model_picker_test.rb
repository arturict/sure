require "test_helper"

class UI::ModelPickerTest < ViewComponent::TestCase
  test "a single model is shown as a label, not offered" do
    render_inline(UI::ModelPicker.new(models: %w[gpt-6-luna], selected: "gpt-6-luna"))

    assert_text "6 Luna"
    assert_no_selector "[role='menuitemradio']"
  end

  test "offers every model, marks the selected one and carries what the browser needs" do
    render_inline(UI::ModelPicker.new(models: %w[gpt-6-luna claude-haiku-5-5 claude-sonnet-5-5], selected: "gpt-6-luna"))

    assert_selector "[role='menuitemradio']", count: 3
    assert_selector "[role='menuitemradio'][aria-checked='true']", text: "6 Luna"
    assert_selector "a[data-action='chat-model-picker#select'][data-chat-model-picker-model-param='claude-haiku-5-5']", text: "Haiku 5.5"
    assert_selector "a[data-chat-model-picker-model-param='claude-sonnet-5-5'][data-chat-model-picker-effort-param='true']", text: "Sonnet 5.5"
  end
end
