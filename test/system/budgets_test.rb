require "application_system_test_case"

class BudgetsTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    login_as(@user)
  end

  # Driven in a real browser because the future-month path exists only in the
  # UI. BudgetsController#set_budget bootstraps whatever month param it is
  # handed, so a request test passes even when every future month is rendered
  # as an inert <span> and no user can reach it. What decides that is the
  # picker markup, which lives behind a DS::Popover and a lazily-navigated
  # turbo-frame -- neither of which a controller test renders.
  test "creates a budget for a month that has not started yet" do
    target = Date.current.beginning_of_month + 3.months
    assert_nil @family.budgets.find_by(start_date: target), "fixtures must not pre-create the target month"

    visit budgets_url
    open_budget_picker(Date.current.beginning_of_month)
    go_to_picker_year(target.year)

    within "#budget_picker" do
      click_on Date::ABBR_MONTHNAMES[target.month]
    end

    assert_current_path budget_path(Budget.date_to_param(target))
    assert_selector "button", text: I18n.l(target, format: :month_year)

    budgets = @family.budgets.where(start_date: target)
    assert_equal 1, budgets.count, "one GET must bootstrap exactly one budget"
    budget = budgets.sole
    assert_equal target.end_of_month, budget.end_date
    assert_equal @family.categories.count, budget.budget_categories.count

    # The forward link has to exist too: bootstrapping a month the header
    # cannot then walk out of would strand the user on it.
    assert_equal Budget.date_to_param(target + 1.month), budget.next_budget_param
  end

  # The other half of the window. #set_budget writes a Budget plus one
  # BudgetCategory per category for every distinct month it is handed, so the
  # 2-year cap is the only bound on bootstrap-on-GET write amplification, and
  # the picker is where that bound is enforced against a real user.
  test "the picker stops offering months past the two-year cap" do
    cap = Date.current.beginning_of_month + 2.years

    visit budgets_url
    open_budget_picker(Date.current.beginning_of_month)
    go_to_picker_year(cap.year)

    within "#budget_picker" do
      assert_selector "a", text: Date::ABBR_MONTHNAMES[cap.month]

      beyond_cap = Date::ABBR_MONTHNAMES.compact.drop(cap.month)
      if beyond_cap.any?
        beyond_cap.each do |month_name|
          assert_selector "span", text: month_name
          assert_no_selector "a", text: month_name
        end
      else
        # The cap landed in December, so every month of this year is offered
        # and the only reachable month past it is in the next one.
        assert_no_selector "a[href*='year=#{cap.year + 1}']"
      end
    end
  end

  private
    # The trigger is a DS::Popover button labelled with the budget's own name,
    # which is also the only thing that tells it apart from the other popovers
    # the layout renders (account menu, user menu).
    def open_budget_picker(month)
      find("button", text: I18n.l(month, format: :month_year)).click
      assert_selector "#budget_picker"
    end

    def go_to_picker_year(year)
      (Date.current.year...year).each do |shown_year|
        find("#budget_picker a[href*='year=#{shown_year + 1}']").click
        # The chevron navigates the turbo-frame in place, so wait for the new
        # year's grid before clicking again -- otherwise the second click
        # re-finds the stale frame and the picker never leaves the first year.
        assert_selector "#budget_picker", text: (shown_year + 1).to_s
      end
    end
end
