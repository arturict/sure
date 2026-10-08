# Model selector for the chat composer, built on DS::Menu like UI::EffortPicker.
#
# The model rides on the message as a hidden field of the composer's form, so
# choosing one changes that field in the browser instead of making a request:
# the items are links handled by the `chat-model-picker` controller, because a
# button_to form inside the composer's form would be invalid nested markup.
# With only one model on offer the trigger is a plain label.
class UI::ModelPicker < ApplicationComponent
  attr_reader :models, :selected, :placement

  def initialize(models:, selected:, placement: "top-start")
    @models = models
    @selected = selected
    @placement = placement
  end

  def choice?
    models.size > 1
  end

  def label_for(model)
    Chat.humanize_model(model)
  end

  def supports_effort?(model)
    Chat.supports_reasoning_effort?(model)
  end
end
