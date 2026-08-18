# The composer's thinking-depth picker writes here. It is a user preference
# rather than a field on the message, so it is set on its own instead of riding
# along with a prompt — which also keeps the picker out of the composer's form
# and avoids nesting one form inside another.
class Settings::ReasoningEffortsController < ApplicationController
  def update
    Current.user.update!(ai_reasoning_effort: params[:reasoning_effort])

    redirect_back_or_to root_path
  end
end
