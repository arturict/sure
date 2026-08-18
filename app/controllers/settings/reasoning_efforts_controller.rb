# The composer's thinking-depth picker writes here. It is a user preference
# rather than a field on the message, so it is set on its own instead of riding
# along with a prompt — which also keeps the picker out of the composer's form
# and avoids nesting one form inside another.
class Settings::ReasoningEffortsController < ApplicationController
  def update
    Current.user.update!(ai_reasoning_effort: params[:reasoning_effort])

    respond_to do |format|
      # The picker lives inside the chat's Turbo Frame, so a redirect here
      # returns a page with no matching frame and Turbo renders "Content
      # missing". Replacing just the picker also preserves a half-typed prompt,
      # which re-rendering the composer would discard. replace_all rather than
      # replace, because a chat page shows the composer twice — main column and
      # sidebar — and both have to end up on the same depth.
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace_all(
          UI::EffortPicker::TARGETS,
          view_context.render(UI::EffortPicker.new(selected: Current.user.ai_reasoning_effort))
        )
      end
      format.html { redirect_back_or_to root_path }
    end
  end
end
