require "test_helper"

class Goals::CardComponentTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    # A small dedicated balance, so a whole-balance link does not push every
    # goal in here straight to :reached.
    @account = Account.create!(family: @family, accountable: Depository.new,
                               name: "Ring Test Savings", currency: "USD", balance: 100)
  end

  # A dateless goal has no pace, so upstream painted its ring flat neutral.
  # These cover the rule that replaced it: identity color when there is no
  # status to report, status color whenever there is.
  test "a goal without a target date rings in its own color" do
    goal = build_goal(color: "#6471eb")

    assert_equal :no_target_date, goal.status
    assert_equal "#6471eb", Goals::CardComponent.new(goal: goal).ring_color
  end

  test "a dateless goal with no color picked falls back to its deterministic swatch" do
    goal = build_goal(color: nil)

    assert_equal Goals::AvatarComponent.color_for(goal.name),
                 Goals::CardComponent.new(goal: goal).ring_color
  end

  test "a goal that is behind or reached keeps its status tone" do
    behind = build_goal(color: "#6471eb", target_date: 1.month.from_now.to_date)
    assert_equal :behind, behind.status
    assert_nil Goals::CardComponent.new(goal: behind).ring_color
    assert_equal :warning, Goals::CardComponent.new(goal: behind).ring_tone

    reached = build_goal(name: "Reached", color: "#6471eb", target_amount: 1)
    assert_equal :reached, reached.status
    assert_nil Goals::CardComponent.new(goal: reached).ring_color
  end

  test "the rendered card carries the identity stroke" do
    goal = build_goal(color: "#4da568")

    render_inline(Goals::CardComponent.new(goal: goal))

    assert_selector "svg circle[stroke='#4da568']"
  end

  private
    def build_goal(name: "Dateless", color: nil, target_amount: 5_000, target_date: nil)
      @family.goals.create!(
        name: name, target_amount: target_amount, currency: "USD",
        color: color, target_date: target_date
      ) { |g| g.goal_accounts.build(account: @account) }
    end
end
