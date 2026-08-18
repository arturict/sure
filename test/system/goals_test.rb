require "application_system_test_case"

class GoalsTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    # The whole goals surface is behind the per-user preview flag; without it
    # the sidebar item is not even rendered and every visit lands on the
    # dashboard with a flash.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    # Fixture goals share the depository account and would add cards whose
    # pace lines are not what these tests are asserting about.
    @family.goals.destroy_all
    login_as(@user)
  end

  # Artur's shape: one savings account, several pots earmarked against it. The
  # regression was visible only once rendered -- every card printed the same
  # "-CHF 890/mo avg", because Goal#pace averaged the whole account's 90-day
  # flow no matter which slice of it belonged to the goal.
  test "goals earmarked against one shared account do not repeat its pace" do
    shared = create_account("Yuh Savings", balance: 9_000)
    earmarked_goal("Notreserve", account: shared, earmark: 1_000, target: 5_000)
    earmarked_goal("Reisen", account: shared, earmark: 2_000, target: 5_000)
    earmarked_goal("Laptop", account: shared, earmark: 3_000, target: 5_000)
    dated = earmarked_goal("Umzug", account: shared, earmark: 500, target: 5_000,
                           target_date: 3.months.from_now.to_date)
    # The flow the old code divided by three and printed on all four cards.
    create_transaction(account: shared, amount: -900, date: 30.days.ago.to_date)

    # A goal that really does absorb its account's remainder still has a pace,
    # so the fix has to be "not attributable here", not "drop the feature".
    solo = create_account("Solo Savings", balance: 2_000)
    whole_balance_goal("Sabbatical", account: solo, target: 5_000)
    create_transaction(account: solo, amount: -600, date: 30.days.ago.to_date)

    visit root_url
    click_on "Goals"
    assert_selector "h1", text: "Goals"

    %w[Notreserve Reisen Laptop Umzug].each do |name|
      within "[data-goal-name='#{name}']" do
        assert_text "$5,000"
        # A borrowed figure renders as "$300/mo avg" on every one of them.
        assert_no_text(/\/mo/)
      end
    end

    within "[data-goal-name='Sabbatical']" do
      assert_text "$200/mo avg"
    end

    # A dated goal is where the borrowed figure turned into advice. The only
    # lever that moves a fixed earmark is the earmark.
    within "[data-goal-name='Umzug']" do
      assert_text "Raise the earmark by $4,500"
      click_on dated.name
    end

    # The real user path that used to 500: the projection card formatted the
    # pace unconditionally and raised "private method 'format' called for nil".
    assert_selector "h1", text: "Umzug"
    assert_text "only moves when you change the earmark"
    assert_no_text(/\/mo/)
  end

  # Twelve goals, none with a deadline: the tile's fraction counts only dated,
  # unpaused, unreached goals, so it rendered a literal "0 of 0" and a third of
  # the KPI strip carried no information.
  test "the goals KPI reports funded coverage when no goal has a target date" do
    whole_balance_goal("Reserve", account: create_account("Reserve savings", balance: 200), target: 800)
    whole_balance_goal("Gifts", account: create_account("Gifts savings", balance: 100), target: 200)

    visit root_url
    click_on "Goals"
    # Wait for the navigation before the negative assertion below, which would
    # otherwise pass vacuously against the dashboard still on screen.
    assert_selector "h1", text: "Goals"

    # The symptom, stated where it was visible: a third of the KPI strip read
    # "0 of 0" because the fraction's denominator counts only dated goals.
    assert_no_text "0 of 0"

    # Located from the tile's own label rather than a utility class, so the
    # assertions cannot silently drift onto one of the two neighbouring tiles.
    tile = find("p", text: /goals funded/i).find(:xpath, "..")

    within tile do
      assert_text "30%"
      assert_text "$300 of $1,000 saved"
      assert_text "2 without a deadline"
      # The fraction has no denominator here, so it is dropped rather than
      # printed as a second, narrower ratio next to the percent.
      assert_no_text(/on pace/i)
    end
  end

  private
    def create_account(name, balance:)
      Account.create!(family: @family, accountable: Depository.new, name: name,
                      currency: "USD", balance: balance)
    end

    # A fixed earmark pins the goal's backing to goal_accounts.allocated_amount,
    # which nothing but a form edit ever writes.
    def earmarked_goal(name, account:, earmark:, target:, target_date: nil)
      @family.goals.create!(name: name, target_amount: target, target_date: target_date, currency: "USD") do |goal|
        goal.goal_accounts.build(account: account, allocated_amount: earmark)
      end
    end

    # A blank allocation means "this goal absorbs whatever is left", which is
    # the one case where the account's flow really is the goal's pace.
    def whole_balance_goal(name, account:, target:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD") do |goal|
        goal.goal_accounts.build(account: account)
      end
    end
end
