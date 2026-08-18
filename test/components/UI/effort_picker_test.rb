require "test_helper"

class UI::EffortPickerTest < ViewComponent::TestCase
  test "offers the provider default plus every effort level" do
    picker = UI::EffortPicker.new(selected: nil)

    assert_equal [ "" ] + Provider::Openai::REASONING_EFFORTS, picker.levels
  end

  test "an unset choice reads as the provider default" do
    assert_equal I18n.t("messages.chat_form.effort_default"), UI::EffortPicker.new(selected: nil).selected_label
  end

  test "the trigger shows the chosen depth" do
    assert_equal I18n.t("messages.chat_form.effort_max"), UI::EffortPicker.new(selected: "max").selected_label
  end

  test "renders a menu item per level, marking the active one" do
    render_inline(UI::EffortPicker.new(selected: "high"))

    assert_selector "a[href*='reasoning_effort=high']"
    assert_selector "a[data-turbo-method='patch']", count: UI::EffortPicker::DEFAULT.then { Provider::Openai::REASONING_EFFORTS.size + 1 }
  end

  test "an ENV lock replaces the menu with a static label" do
    with_env_overrides OPENAI_REASONING_EFFORT: "medium" do
      render_inline(UI::EffortPicker.new(selected: "medium"))

      assert_no_selector "a[data-turbo-method='patch']"
      assert_text I18n.t("messages.chat_form.effort_medium")
    end
  end
end
