require "test_helper"

class BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "index redirects to the current month budget" do
    get budgets_url

    assert_redirected_to budget_path(Budget.date_to_param(Date.current))
  end

  test "show renders the budget page" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
  end

  test "breadcrumbs include the Plan hub for preview users" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, minimum: 1
  end

  test "renders no Plan links without preview features" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, count: 0
    assert_select "a[href=?]", budgets_path, minimum: 1
  end
  # --- Lot A3: cash on hand ---

  test "the cash panel is hidden without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get budget_url(Budget.date_to_param(Date.current.beginning_of_month))

    assert_response :success
    assert_no_match I18n.t("budgets.available_cash.heading"), response.body
  end

  test "the cash panel shows what goals have already claimed" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get budget_url(Budget.date_to_param(Date.current.beginning_of_month))

    assert_response :success
    assert_match I18n.t("budgets.available_cash.heading"), response.body
    assert_match I18n.t("budgets.available_cash.free"), response.body
  end
end

class BudgetsControllerSharingTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:empty)
    @family.update!(personal_budgets: true)
    @owner = users(:josh)
    @viewer = users(:ann)
    @date = Date.current.beginning_of_month
  end

  test "household budget is viewable and editable by any family member" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner, household: true)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: "household" })
    assert_response :success

    patch budget_url(Budget.date_to_param(@date), params: { owner: "household" }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :redirect
  end

  test "household tab is unreachable once household_budget_enabled is off, falling back to the viewer's own budget" do
    @family.update!(household_budget_enabled: false)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: "household" })

    assert_response :success
    assert_equal @viewer.id, Budget.find_by(family: @family, start_date: @date).user_id
  end

  test "a member without a BudgetShare cannot view another member's personal budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })

    # Falls back to the viewer's own budget rather than the owner's.
    assert_response :success
    assert Budget.exists?(family: @family, start_date: @date, user_id: @viewer.id)
  end

  test "a read_only BudgetShare lets the viewer see but not edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_only")
    sign_in @viewer

    get budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :success

    get edit_budget_url(Budget.date_to_param(@date), params: { owner: @owner.id })
    assert_response :not_found

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }
    assert_response :not_found
  end

  test "a read_write BudgetShare lets the viewer edit the owner's budget" do
    Budget.find_or_bootstrap(@family, start_date: @date, user: @owner)
    BudgetShare.create!(owner: @owner, viewer: @viewer, permission: "read_write")
    sign_in @viewer

    patch budget_url(Budget.date_to_param(@date), params: { owner: @owner.id }),
          params: { budget: { budgeted_spending: 1000, expected_income: 2000 } }

    assert_redirected_to budget_budget_categories_url(Budget.date_to_param(@date), owner: @owner.id)
    assert_equal 1000, Budget.find_by(family: @family, user: @owner).budgeted_spending.to_i
  end
end

class BudgetsControllerFutureMonthsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
  end

  # Planning ahead — writing next month's budget before next month arrives — is
  # the reason this fork exists on Artur's VM, and the whole path runs through
  # #set_budget -> Budget.find_or_bootstrap. Upstream owns that code and edits
  # it, so without a controller-level guard a rebase could quietly reinstate the
  # old "no budget after the current month" rule and nothing here would notice.
  # Every test pins the clock: run on the 31st, `+ 3.months` would otherwise
  # skid onto a different month and the date assertions would drift.
  test "shows a budget three months ahead and bootstraps exactly one row" do
    travel_to Date.new(2026, 8, 18) do
      assert_difference -> { Budget.count }, 1 do
        get budget_path("nov-2026")
      end

      assert_response :success

      budget = Budget.find_by(family: @family, start_date: Date.new(2026, 11, 1))
      assert_not_nil budget
      assert_equal Date.new(2026, 11, 30), budget.end_date
      assert_not budget.current?
    end
  end

  test "re-requesting the same future month reuses the bootstrapped budget" do
    travel_to Date.new(2026, 8, 18) do
      get budget_path("nov-2026")
      assert_response :success

      assert_no_difference -> { Budget.count } do
        get budget_path("nov-2026")
      end

      assert_response :success
    end
  end

  test "bootstraps a future budget on the family's custom month boundaries" do
    @family.update!(month_start_day: 15)

    travel_to Date.new(2026, 8, 18) do
      get budget_path("nov-2026")

      assert_response :success

      budget = Budget.find_by(family: @family, start_date: Date.new(2026, 11, 15))
      assert_not_nil budget, "expected the custom 15th-of-month period, not a calendar month"
      assert_equal Date.new(2026, 12, 14), budget.end_date
    end
  end

  test "future budget header offers a link to the month after it" do
    travel_to Date.new(2026, 8, 18) do
      get budget_path("nov-2026")

      assert_response :success
      assert_select "a[href=?]", budget_path("dec-2026")
    end
  end

  # `suggested_daily_spending` divides what is left by the days left in the
  # period, which is meaningless for a month that has not started. It is gated
  # on Budget#current?; this pins that the gate survives into budgets#show, the
  # only page that reaches budget_categories/_budget_category and so the only
  # one that can print the line at all.
  test "future budget page omits suggested daily spending" do
    travel_to Date.new(2026, 8, 18) do
      get budget_path("nov-2026")
      budget = Budget.find_by!(family: @family, start_date: Date.new(2026, 11, 1))
      budget.update!(budgeted_spending: 5_000, expected_income: 7_000)
      budget.budget_categories.each { |bc| bc.update!(budgeted_spending: 100) }

      get budget_path("nov-2026")

      assert_response :success
      assert_no_match(/suggested per day/i, response.body)
    end
  end

  # Positive control for the assertion above. Without it, renaming the partial
  # or dropping the line from the card would leave the negative assertion true
  # for the wrong reason and the gate unguarded.
  test "current budget page shows suggested daily spending" do
    travel_to Date.new(2026, 8, 18) do
      get budget_path("aug-2026")
      budget = Budget.find_by!(family: @family, start_date: Date.new(2026, 8, 1))
      budget.update!(budgeted_spending: 5_000, expected_income: 7_000)
      # Large enough that fixture spending cannot exhaust any category, so
      # available_to_spend stays positive and the line is expected on merit.
      budget.budget_categories.each { |bc| bc.update!(budgeted_spending: 100_000) }

      get budget_path("aug-2026")

      assert_response :success
      assert_match(/suggested per day/i, response.body)
    end
  end

  # The 2-year cap is the only bound on bootstrap-on-GET: #set_budget creates a
  # Budget plus one BudgetCategory per category for every distinct month param,
  # so an unbounded window lets any signed-in user inflate those tables by
  # walking URLs. Widening or removing the cap must break this test.
  test "rejects a month beyond the two-year window without creating a budget" do
    travel_to Date.new(2026, 8, 18) do
      assert_no_difference -> { Budget.count } do
        get budget_path("sep-2028")
      end

      assert_response :not_found
    end
  end
end
