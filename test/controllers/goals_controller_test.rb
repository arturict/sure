require "test_helper"

class GoalsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    @goal = goals(:vacation_italy)
    @depository = accounts(:depository)
    @connected = accounts(:connected)
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get goals_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "index renders with active filter by default" do
    get goals_url
    assert_response :success
    assert_match(/Goals/i, response.body)
  end

  test "index warns when an account is earmarked past its balance" do
    account = Account.create!(family: @user.family, accountable: Depository.new, name: "Squeezed Savings", currency: "USD", balance: 100)
    @user.family.goals.create!(name: "Squeezer", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 400)
    end

    get goals_url

    assert_response :success
    assert_match(/Squeezed Savings/, response.body)
    assert_match(/Earmarks exceed the account balance/i, response.body)
  end

  test "index shows no over-earmark warning when every account has headroom" do
    account = Account.create!(family: @user.family, accountable: Depository.new, name: "Roomy Savings", currency: "USD", balance: 5_000)
    @user.family.goals.create!(name: "Roomy", target_amount: 5_000, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 400)
    end

    get goals_url

    assert_response :success
    assert_no_match(/Earmarks exceed the account balance/i, response.body)
  end

  # The real user path for the earmark-aware pace: a goal with a deadline whose
  # backing is a fixed earmark has no pace at all, and the projection card used
  # to format it unconditionally ("Current pace %{avg}/mo"), which raises on nil.
  test "show renders a dated goal backed only by an earmark" do
    account = Account.create!(family: @user.family, accountable: Depository.new, name: "Pinned Savings", currency: "USD", balance: 5_000)
    goal = @user.family.goals.create!(name: "Pinned", target_amount: 5_000, target_date: 6.months.from_now.to_date, currency: "USD") do |g|
      g.goal_accounts.build(account: account, allocated_amount: 1_000)
    end

    get goal_url(goal)

    assert_response :success
    assert_match(/only moves when you change the earmark/i, response.body)
    assert_no_match(/Current pace/i, response.body)
  end

  test "index honors state filter" do
    get goals_url(state: "paused")
    assert_response :success
  end

  test "show renders the goal" do
    get goal_url(@goal)
    assert_response :success
    assert_match(@goal.name, response.body)
  end

  test "new renders the modal form" do
    get new_goal_url
    assert_response :success
  end

  test "create persists a goal with linked accounts" do
    assert_difference -> { Goal.count } => 1,
                      -> { GoalAccount.count } => 2 do
      post goals_url, params: {
        goal: {
          name: "New goal",
          target_amount: "1000",
          target_date: 3.months.from_now.to_date.iso8601,
          color: "#4da568",
          account_ids: [ @depository.id, @connected.id ]
        }
      }
    end

    goal = Goal.order(created_at: :desc).first
    assert_redirected_to goal_path(goal)
  end

  test "create rejects missing account_ids" do
    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Bad goal",
          target_amount: "1000",
          color: "#4da568"
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "create rejects foreign accounts" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    foreign = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)

    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Foreign goal",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ foreign.id ]
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "new form excludes same-family accounts not shared with the current user" do
    # Regression for #2168: funding-account picker leaked accounts owned by
    # other family members that were never shared with the current user.
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: "USD",
      balance: 100
    )

    get new_goal_url
    assert_response :success
    assert_no_match(/Member Private Checking/, response.body)
    assert_no_match(/goal_account_ids_#{private_account.id}/, response.body)
  end

  test "create rejects a same-family account not shared with the current user" do
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: "USD",
      balance: 100
    )

    assert_no_difference "Goal.count" do
      post goals_url, params: {
        goal: {
          name: "Sneaky goal",
          target_amount: "1000",
          color: "#4da568",
          account_ids: [ private_account.id ]
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "update modifies identity fields" do
    patch goal_url(@goal), params: { goal: { name: "Renamed" } }
    assert_redirected_to goal_path(@goal)
    assert_equal "Renamed", @goal.reload.name
  end

  test "update without account_ids leaves linked accounts intact" do
    before = @goal.goal_accounts.pluck(:account_id).sort
    patch goal_url(@goal), params: { goal: { name: "Still here" } }
    assert_redirected_to goal_path(@goal)
    assert_equal before, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "update with account_ids syncs linked accounts (add + remove)" do
    patch goal_url(@goal), params: { goal: { account_ids: [ @connected.id ] } }
    assert_redirected_to goal_path(@goal)
    assert_equal [ @connected.id ], @goal.reload.goal_accounts.pluck(:account_id)
  end

  test "update preserves a linked account the current user cannot access" do
    # Regression for #2172 review: a family goal can be linked to a private
    # account owned by another member. That account is never rendered in the
    # picker, so its absence from the submitted set must not unlink it.
    private_account = Account.create!(
      family: @user.family,
      owner: users(:family_member),
      accountable: Depository.new,
      name: "Member Private Checking",
      currency: @goal.currency,
      balance: 100
    )
    @goal.goal_accounts.create!(account: private_account)

    patch goal_url(@goal), params: { goal: { account_ids: [ @depository.id ] } }

    assert_redirected_to goal_path(@goal)
    linked = @goal.reload.goal_accounts.pluck(:account_id)
    assert_includes linked, private_account.id, "inaccessible private link must be preserved"
    assert_includes linked, @depository.id
  end

  test "update with empty account_ids re-renders with error" do
    patch goal_url(@goal), params: { goal: { account_ids: [ "" ] } }
    assert_response :unprocessable_entity
    assert_not_empty @goal.reload.goal_accounts
  end

  test "update rejects a cross-currency account attachment" do
    # Regression: sync_linked_accounts! used to call goal_accounts.create!
    # directly, bypassing Goal#linked_accounts_must_match_goal_currency.
    eur_account = Account.create!(
      family: @goal.family,
      accountable: Depository.new,
      name: "EUR Checking",
      currency: "EUR",
      balance: 100
    )
    before_ids = @goal.goal_accounts.pluck(:account_id).sort

    patch goal_url(@goal), params: { goal: { account_ids: [ eur_account.id ] } }

    assert_response :unprocessable_entity
    assert_equal before_ids, @goal.reload.goal_accounts.pluck(:account_id).sort
  end

  test "pause/resume/complete/archive/unarchive flow" do
    fresh = goals(:emergency_fund)
    patch pause_goal_url(fresh)
    assert fresh.reload.paused?
    patch resume_goal_url(fresh)
    assert fresh.reload.active?
    patch complete_goal_url(fresh)
    assert fresh.reload.completed?
    patch archive_goal_url(fresh)
    assert fresh.reload.archived?
    patch unarchive_goal_url(fresh)
    assert fresh.reload.active?
  end

  test "destroy on non-archived is rejected" do
    assert_no_difference "Goal.count" do
      delete goal_url(@goal)
    end
    assert_redirected_to goal_path(@goal)
  end

  test "destroy on archived deletes" do
    @goal.archive!
    assert_difference "Goal.count", -1 do
      delete goal_url(@goal)
    end
    assert_redirected_to goals_path
  end

  test "index KPI celebrates when every active goal is fully funded" do
    family = users(:family_admin).family
    family.goals.destroy_all
    # Real reached state: target $1 against the depository fixture's
    # $5000 balance. Stubbing :status hides whether the controller
    # actually reads the right method on each goal.
    build_goal(family, "Wedding", target_amount: 1, target_date: 1.year.from_now)

    get goals_url
    assert_response :success
    assert_match(/Fully funded/i, response.body)
    assert_match(/1\s*reached/i, response.body)
  end

  test "index KPI 'on pace' denominator excludes no-target-date goals" do
    family = users(:family_admin).family
    family.goals.destroy_all
    # One trackable goal (has target_date) + one open-ended (no target_date).
    # The trackable one should be the only thing in the denominator;
    # open-ended goals can't be off pace because they have no required pace.
    build_goal(family, "House", target_amount: 1_000_000, target_date: 1.year.from_now)
    build_goal(family, "Emergency", target_amount: 1_000_000, target_date: nil)

    get goals_url
    assert_response :success
    # "0 of 1 on pace" — the open-ended goal stays out of the fraction even
    # though it is active, and the words say which denominator this is, since
    # the headline percent counts both goals.
    assert_match(/0\s*of\s*1\s*on pace/i, response.body)
    assert_match(/without a deadline/i, response.body)
  end

  # Artur's shape: twelve goals, none with a deadline, so the old tile printed
  # a literal "0 of 0" — a third of the KPI strip carrying no information.
  test "index KPI reports funded coverage when no goal has a target date" do
    family = users(:family_admin).family
    family.goals.destroy_all
    funded_goal(family, "Reserve", target_amount: 800, balance: 200)
    funded_goal(family, "Gifts", target_amount: 200, balance: 100)

    get goals_url

    assert_response :success
    assert_no_match(/0\s*of\s*0/, response.body)
    assert_match(/30%/, response.body)
    assert_match(/\$300 of \$1,000 saved/, response.body)
  end

  # The case a plain "fall back to coverage when tracked_total is zero" fix
  # cannot survive: one deadline is enough to make the fraction calculable, and
  # the headline would then describe one goal out of four.
  test "index KPI keeps the whole portfolio in the headline when only some goals are dated" do
    family = users(:family_admin).family
    family.goals.destroy_all
    dated = funded_goal(family, "Trip", target_amount: 1_000, balance: 900,
                        target_date: 1.year.from_now.to_date)
    create_transaction(account: dated.linked_accounts.first, amount: -100, date: 30.days.ago.to_date)
    3.times { |i| funded_goal(family, "Open #{i}", target_amount: 1_000, balance: 0) }

    get goals_url

    assert_response :success
    assert_match(/22%/, response.body)
    assert_match(/\$900 of \$4,000 saved/, response.body)
    assert_match(/1\s*of\s*1\s*on pace/i, response.body)
  end

  # Pins the numerator to target_amount - remaining_amount. A naive
  # sum(current_balance) / sum(target_amount) reads 150% here and clamps to a
  # "Fully funded" celebration while half the portfolio is empty.
  test "index KPI caps an over-funded goal at its target" do
    family = users(:family_admin).family
    family.goals.destroy_all
    funded_goal(family, "Overflowing", target_amount: 1_000, balance: 3_000)
    funded_goal(family, "Untouched", target_amount: 1_000, balance: 0)

    get goals_url

    assert_response :success
    assert_match(/50%/, response.body)
    assert_no_match(/Fully funded/i, response.body)
  end

  # The strip still renders when every goal is completed or archived
  # (@counts["all"] is non-zero while @active_goals is empty). An unguarded
  # coverage percent divides by zero there and takes the page down.
  test "index KPI renders no percent when no goal is active" do
    family = users(:family_admin).family
    family.goals.destroy_all
    funded_goal(family, "Done", target_amount: 1_000, balance: 1_000).complete!

    get goals_url

    assert_response :success
    assert_match(/No active goals/i, response.body)
    assert_no_match(/0\s*of\s*0/, response.body)
  end

  test "index KPI counts a paused open-ended goal once" do
    family = users(:family_admin).family
    family.goals.destroy_all
    funded_goal(family, "Resting", target_amount: 1_000, balance: 0).pause!
    funded_goal(family, "Running", target_amount: 1_000, balance: 0)

    get goals_url

    assert_response :success
    assert_match(/1 without a deadline/, response.body)
    assert_match(/1 paused/, response.body)
    assert_no_match(/2 without a deadline/, response.body)
  end

  private
    def build_goal(family, name, target_amount: 1_000_000, target_date: nil)
      g = family.goals.new(name: name, target_amount: target_amount, target_date: target_date, currency: "USD")
      g.goal_accounts.build(account: @depository)
      g.save!
      g
    end

    # One dedicated account per goal, linked whole-balance, so `balance` is
    # exactly this goal's backing. Sharing the depository fixture would give
    # every unallocated goal the same $5,000 remainder and make the coverage
    # arithmetic untestable.
    def funded_goal(family, name, target_amount:, balance:, target_date: nil)
      account = Account.create!(
        family: family, accountable: Depository.new,
        name: "#{name} account", currency: "USD", balance: balance
      )
      g = family.goals.new(name: name, target_amount: target_amount, target_date: target_date, currency: "USD")
      g.goal_accounts.build(account: account)
      g.save!
      g
    end

  public

  test "create ignores forbidden params (family_id, state)" do
    family = users(:family_admin).family
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")

    assert_difference -> { family.goals.count }, 1 do
      post goals_url, params: {
        goal: {
          name: "Hijack target",
          target_amount: 100,
          currency: "USD",
          state: "archived",
          family_id: other_family.id,
          account_ids: [ @depository.id ]
        }
      }
    end

    goal = family.goals.order(:created_at).last
    # Strong params must strip both `state` (AASM-managed) and `family_id`
    # (cross-family pivot) — otherwise a crafted POST would create rows
    # outside the current family or skip the active-state assumption.
    assert_equal "active", goal.state
    assert_equal family.id, goal.family_id
  end

  test "another family's goal returns 404" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_account = Account.create!(family: other_family, accountable: Depository.new, name: "Foreign", currency: "USD", balance: 100)
    other_goal = other_family.goals.new(name: "Foreign goal", target_amount: 100, currency: "USD")
    other_goal.goal_accounts.build(account: other_account)
    other_goal.save!

    get goal_url(other_goal)
    assert_redirected_to goals_path
    assert_equal I18n.t("goals.errors.not_found"), flash[:alert]
  end
end
