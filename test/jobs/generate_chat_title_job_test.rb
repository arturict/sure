require "test_helper"

class GenerateChatTitleJobTest < ActiveJob::TestCase
  setup do
    @chat = users(:family_admin).chats.start!("What did I spend on groceries in September?", model: "claude-haiku-5-5")
    @chat.messages.create!(type: "AssistantMessage", content: "USD 412.", ai_model: "claude-haiku-5-5", status: "complete")
  end

  test "replaces the placeholder with the generated title" do
    Chat::TitleGenerator.any_instance.stubs(:generate).returns("Groceries in September")

    GenerateChatTitleJob.perform_now(@chat)

    assert_equal "Groceries in September", @chat.reload.title
  end

  test "never overwrites a title the user chose" do
    @chat.update!(title: "My grocery budget")
    Chat::TitleGenerator.any_instance.expects(:generate).never

    GenerateChatTitleJob.perform_now(@chat)

    assert_equal "My grocery budget", @chat.reload.title
  end

  test "a rename that lands while the model answers wins" do
    chat = @chat
    Chat::TitleGenerator.any_instance.stubs(:generate).with do
      Chat.where(id: chat.id).update_all(title: "Renamed meanwhile")
      true
    end.returns("Groceries in September")

    GenerateChatTitleJob.perform_now(@chat)

    assert_equal "Renamed meanwhile", @chat.reload.title
  end

  test "keeps the placeholder when no title comes back" do
    Chat::TitleGenerator.any_instance.stubs(:generate).returns(nil)

    GenerateChatTitleJob.perform_now(@chat)

    assert_equal "What did I spend on groceries in September?", @chat.reload.title
  end

  test "is queued after the first answer only" do
    assert_enqueued_with(job: GenerateChatTitleJob) { @chat.generate_title_later }

    @chat.messages.create!(type: "AssistantMessage", content: "Second answer.", ai_model: "claude-haiku-5-5", status: "complete")
    assert_no_enqueued_jobs(only: GenerateChatTitleJob) { @chat.generate_title_later }
  end

  test "the response job queues it once the answer is in" do
    user_message = @chat.messages.where(type: "UserMessage").first
    user_message.stubs(:request_response)

    assert_enqueued_with(job: GenerateChatTitleJob) do
      AssistantResponseJob.perform_now(user_message)
    end
  end
end
