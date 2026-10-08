# Replaces a chat's placeholder title (its truncated first prompt) with one
# generated from the first exchange. Runs after the first answer so it never
# delays the chat itself; on any failure the placeholder simply stays.
class GenerateChatTitleJob < ApplicationJob
  queue_as :medium_priority

  def perform(chat)
    return unless chat.placeholder_title?

    title = Chat::TitleGenerator.new(chat).generate
    chat.apply_generated_title!(title) if title.present?
  end
end
