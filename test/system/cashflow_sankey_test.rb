require "application_system_test_case"

class CashflowSankeyTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    login_as(@user)
  end

  # Only a browser can answer this one. The server sends both payloads on the
  # same page load, so a request test sees the subcategory either way; which
  # column a node lands in is decided by d3-sankey at draw time, from the
  # nodeAlign callback utils/sankey_columns feeds.
  test "the expanded cashflow chart draws subcategories in their own column" do
    account = accounts(:depository)
    shopping = @family.categories.create!(name: "Shopping", color: "#FF5733")
    @family.categories.create!(name: "Groceries", parent: shopping, color: "#33FF57")
    # A childless parent is the node d3's default `justify` alignment gets
    # wrong: with no outgoing link it is dragged into the LAST column, beside
    # another parent's children, the moment any parent gains a subcategory.
    @family.categories.create!(name: "Transport", color: "#3357FF")

    create_transaction(account: account, name: "General shopping", amount: 100, category: shopping)
    create_transaction(account: account, name: "Grocery store", amount: 50, category: @family.categories.find_by(name: "Groceries"))
    create_transaction(account: account, name: "Bus pass", amount: 40, category: @family.categories.find_by(name: "Transport"))
    create_transaction(account: account, name: "Salary", amount: -900, category: categories(:income))

    visit root_url

    tile = sankey_columns(TILE_CHART)
    assert_includes tile.keys, "Shopping"
    assert_includes tile.keys, "Transport"
    # The 384px tile hides most right-column labels past ~15 nodes
    # (MIN_LABEL_SPACING), so it keeps the parents-only trunk.
    assert_not_includes tile.keys, "Groceries"

    expand_cashflow_sankey

    expanded = sankey_columns(EXPANDED_CHART)
    assert_includes expanded.keys, "Groceries"
    assert_operator expanded.fetch("Groceries"), :>, expanded.fetch("Shopping"),
                    "the subcategory must be drawn to the right of its parent"
    assert_equal expanded.fetch("Shopping"), expanded.fetch("Transport"),
                 "a childless parent must stay in the parent column"
  end

  private
    # Index into the page's two sankey-chart instances: the dashboard tile is
    # rendered first, the expand dialog's copy second.
    TILE_CHART = 0
    EXPANDED_CHART = 1

    def expand_cashflow_sankey
      section = "section[data-section-key='cashflow_sankey']"
      # The button is `lg:opacity-0 lg:group-hover:opacity-100`, so Selenium
      # reports it as not displayed until the section is hovered. Hovering the
      # heading rather than the section's centre keeps the pointer off the
      # chart, whose own hover handlers dim nodes and open a tooltip.
      find("#{section} h2").hover
      find("#{section} button[aria-label='#{I18n.t("global.expand")}']").click
      assert_selector "#cashflow-expanded-dialog[open]"
    end

    # { node name => x of its drawn rectangle }. Read off the SVG rather than
    # the payload because the column assignment is d3's output, not the
    # server's. Polls because opening the dialog resizes the chart from zero,
    # which redraws it.
    def sankey_columns(index)
      columns = nil

      page.document.synchronize do
        columns = (page.evaluate_script(<<~JS) || []).to_h
          (() => {
            const chart = document.querySelectorAll("[data-sankey-chart-target='chart']")[#{index}];
            if (!chart) return null;
            return Array.from(chart.querySelectorAll("svg > g > g")).map((node) => {
              const shape = node.querySelector("path");
              const label = node.querySelector("text tspan");
              if (!shape || !label) return null;
              return [label.textContent, Math.round(shape.getBBox().x)];
            }).filter(Boolean);
          })()
        JS

        raise Capybara::ElementNotFound, "sankey chart #{index} has not been drawn" if columns.empty?
      end

      columns
    end
end
