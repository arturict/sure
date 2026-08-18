# The chat composer carries two sticky choices next to the prompt: which model
# to answer with, and how hard it should think. The model rides along on the
# message (messages.ai_model), but the effort is a user preference so it
# survives into the next chat without a column of its own.
module AiComposerOptions
  extend ActiveSupport::Concern

  private
    # No-op when the parameter is absent, so a client that does not send it
    # leaves the stored choice alone rather than clearing it. An unrecognized
    # value is rejected by User#ai_reasoning_effort= and stored as nil, which
    # falls back to the instance-wide setting.
    def persist_reasoning_effort!
      return unless params.key?(:reasoning_effort)

      Current.user.update!(ai_reasoning_effort: params[:reasoning_effort])
    end
end
