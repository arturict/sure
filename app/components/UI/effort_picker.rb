# Thinking-depth selector for the chat composer, built on DS::Menu the same way
# UI::PeriodPicker is: a trigger button showing the current choice and a flat
# list of items, one per level, with the active one marked.
#
# The items are links carrying `turbo_method: :patch` rather than button_to
# forms, because the picker renders inside the composer's form and a nested
# form is invalid markup that browsers silently drop.
class UI::EffortPicker < ApplicationComponent
  DEFAULT = "".freeze

  # The picker replaces itself after a change rather than re-rendering the
  # whole composer, which would wipe a half-typed prompt.
  DOM_ID = "chat_effort_picker".freeze

  attr_reader :selected, :placement

  def initialize(selected: nil, placement: "top-start")
    @selected = selected.presence || DEFAULT
    @placement = placement
  end

  # Provider default first, then cheapest to most thorough.
  def levels
    [ DEFAULT, *Provider::Openai::REASONING_EFFORTS ]
  end

  def label_for(level)
    level == DEFAULT ? I18n.t("messages.chat_form.effort_default") : I18n.t("messages.chat_form.effort_#{level}")
  end

  def selected_label
    label_for(selected)
  end

  def selected?(level)
    level == selected
  end

  def href_for(level)
    "#{Rails.application.routes.url_helpers.settings_reasoning_effort_path}?reasoning_effort=#{level}"
  end

  # An operator can pin the effort through ENV, and the hosting settings form
  # disables its field when they do. The composer has to respect the same lock
  # rather than offering a choice that the provider will discard.
  def locked?
    ENV["OPENAI_REASONING_EFFORT"].present?
  end
end
