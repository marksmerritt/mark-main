module Budget
  class CalculatorsController < ApplicationController
    before_action :require_budget_connection

    include ActionView::Helpers::NumberHelper

    def emergency_fund
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 6.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 2000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }

      @overview = threads[:overview].value || {}
      transactions = threads[:transactions].value
      @funds = threads[:funds].value
      @goals = threads[:goals].value
      recurring_result = threads[:recurring].value || {}
      @recurring_items = recurring_result.is_a?(Hash) ? (recurring_result["items"] || recurring_result["recurring"] || []) : Array(recurring_result)

      # Calculate monthly expenses from last 6 months
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }

      # Group by month
      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      months_count = [monthly_expenses.count, 1].max
      @avg_monthly_expenses = monthly_expenses.values.sum / months_count
      @avg_monthly_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      @monthly_savings = @avg_monthly_income - @avg_monthly_expenses

      # Essential vs discretionary breakdown
      @essential_categories = %w[housing rent mortgage utilities insurance groceries transportation healthcare debt]
      essential_total = 0
      discretionary_total = 0
      expenses.each do |t|
        cat = (t["category"] || t["budget_category"] || "").downcase
        if @essential_categories.any? { |ec| cat.include?(ec) }
          essential_total += t["amount"].to_f
        else
          discretionary_total += t["amount"].to_f
        end
      end
      @avg_essential = essential_total / months_count
      @avg_discretionary = discretionary_total / months_count

      # Emergency fund targets
      @target_months = (params[:months] || 6).to_i.clamp(1, 24)
      @target_amount = @avg_monthly_expenses * @target_months
      @bare_bones_target = @avg_essential * @target_months

      # Current emergency fund balance
      emergency_funds = @funds.select { |f|
        name = (f["name"] || "").downcase
        name.include?("emergency") || name.include?("rainy day") || name.include?("safety")
      }
      @emergency_balance = emergency_funds.sum { |f| f["current_amount"].to_f }

      # Also check goals tagged as emergency fund
      emergency_goals = @goals.select { |g|
        name = (g["name"] || "").downcase
        name.include?("emergency") || name.include?("rainy day")
      }
      @emergency_from_goals = emergency_goals.sum { |g| g["effective_current_amount"].to_f || g["current_amount"].to_f }
      @total_emergency_savings = @emergency_balance + @emergency_from_goals

      # Coverage calculation
      @months_covered = @avg_monthly_expenses > 0 ? (@total_emergency_savings / @avg_monthly_expenses).round(1) : 0
      @bare_bones_months = @avg_essential > 0 ? (@total_emergency_savings / @avg_essential).round(1) : 0
      @gap = [@target_amount - @total_emergency_savings, 0].max
      @funded_pct = @target_amount > 0 ? [(@total_emergency_savings / @target_amount * 100).round(1), 100].min : 0

      # Time to fully funded
      @months_to_funded = if @gap <= 0
        0
      elsif @monthly_savings > 0
        (@gap / @monthly_savings).ceil
      else
        nil
      end

      # Monthly expense breakdown for chart
      @monthly_data = monthly_expenses.sort_by { |k, _| k }.last(6).map { |month, amount|
        { month: month, expenses: amount.round(2), income: (monthly_income[month] || 0).round(2) }
      }

      # Recurring bills total (for bare-bones estimate)
      @recurring_monthly = @recurring_items.sum { |r| r["amount"].to_f }

      # Risk assessment
      @risk_score = calculate_risk_score
    end

    def debt_freedom
      threads = {}
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 6.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 1000,
          transaction_type: "expense"
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }

      debt_result = threads[:debt].value || {}
      @overview = threads[:overview].value || {}
      transactions = threads[:transactions].value

      @debts = debt_result.is_a?(Hash) ? (debt_result["debts"] || debt_result["debt_accounts"] || []) : Array(debt_result)
      @debts = @debts.select { |d| d.is_a?(Hash) && d["current_balance"].to_f > 0 }

      @total_debt = @debts.sum { |d| d["current_balance"].to_f }
      @total_minimum = @debts.sum { |d| d["minimum_payment"].to_f }
      @weighted_avg_rate = if @total_debt > 0
        @debts.sum { |d| d["interest_rate"].to_f * d["current_balance"].to_f } / @total_debt
      else
        0
      end.round(2)

      # Extra payment scenarios
      @extra_amounts = [0, 50, 100, 200, 500]
      @scenarios = @extra_amounts.map { |extra|
        monthly_payment = @total_minimum + extra
        months = estimate_payoff_months(@debts, monthly_payment)
        total_interest = estimate_total_interest(@debts, monthly_payment)
        {
          extra: extra,
          monthly: monthly_payment,
          months: months,
          years: (months / 12.0).round(1),
          total_interest: total_interest,
          payoff_date: Date.current >> months
        }
      }

      # Interest cost per day
      @daily_interest = (@total_debt * @weighted_avg_rate / 100 / 365).round(2)

      # Debt-free date at current pace
      @current_payoff = @scenarios.first
      @best_payoff = @scenarios.last

      # Debt composition
      @by_type = {}
      @debts.each do |d|
        type = d["debt_type"]&.titleize || "Other"
        @by_type[type] ||= { balance: 0, count: 0, min_payment: 0 }
        @by_type[type][:balance] += d["current_balance"].to_f
        @by_type[type][:count] += 1
        @by_type[type][:min_payment] += d["minimum_payment"].to_f
      end

      # Highest rate debt
      @highest_rate_debt = @debts.max_by { |d| d["interest_rate"].to_f }
      @highest_balance_debt = @debts.max_by { |d| d["current_balance"].to_f }
    end

    def spending_heatmap
      @year = (params[:year] || Date.current.year).to_i
      year_start = Date.new(@year, 1, 1)
      year_end = Date.new(@year, 12, 31)

      result = budget_client.transactions(
        start_date: year_start.to_s,
        end_date: year_end.to_s,
        per_page: 5000
      )
      transactions = result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)

      # Build daily spending map
      @daily_spending = {}
      transactions.each do |t|
        next if t["transaction_type"] == "income"
        date = t["transaction_date"]&.to_s&.slice(0, 10)
        next unless date
        @daily_spending[date] ||= 0
        @daily_spending[date] += t["amount"].to_f
      end

      # Stats
      @total_spent = @daily_spending.values.sum
      @max_day_amount = @daily_spending.values.max || 0
      @avg_daily = @daily_spending.any? ? (@total_spent / @daily_spending.count).round(2) : 0
      @zero_spend_days = (year_start..[@year == Date.current.year ? Date.current : year_end, year_end].min).count { |d| !@daily_spending.key?(d.to_s) }
      @spending_days = @daily_spending.count

      # Monthly totals for chart
      @monthly_totals = (1..12).map { |m|
        month_key = "#{@year}-#{m.to_s.rjust(2, '0')}"
        total = @daily_spending.select { |k, _| k.start_with?(month_key) }.values.sum
        { month: m, month_name: Date::ABBR_MONTHNAMES[m], total: total.round(2) }
      }

      # Day of week averages
      @by_dow = Array.new(7, 0)
      dow_counts = Array.new(7, 0)
      @daily_spending.each do |date_str, amount|
        d = Date.parse(date_str) rescue nil
        next unless d
        @by_dow[d.wday] += amount
        dow_counts[d.wday] += 1
      end
      @by_dow = @by_dow.each_with_index.map { |total, i|
        { day: Date::ABBR_DAYNAMES[i], avg: dow_counts[i] > 0 ? (total / dow_counts[i]).round(2) : 0 }
      }
    end

    def savings_projection
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 12.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 3000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }

      @overview = threads[:overview].value || {}
      transactions = threads[:transactions].value
      @funds = threads[:funds].value
      @goals = threads[:goals].value

      # Current savings baseline
      @current_savings = @funds.sum { |f| f["current_amount"].to_f }
      goals_savings = @goals.select { |g| g["status"] == "active" }.sum { |g| g["effective_current_amount"].to_f || g["current_amount"].to_f }
      @total_saved = @current_savings + goals_savings

      # Calculate average monthly savings from transaction history
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      months_with_data = (monthly_income.keys + monthly_expenses.keys).uniq.sort
      months_count = [months_with_data.count, 1].max

      @avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      @avg_expenses = monthly_expenses.values.any? ? monthly_expenses.values.sum / [monthly_expenses.count, 1].max : 0
      @avg_monthly_savings = @avg_income - @avg_expenses

      # Historical monthly savings for trend
      @savings_trend = months_with_data.last(12).map { |m|
        inc = monthly_income[m] || 0
        exp = monthly_expenses[m] || 0
        { month: m, income: inc.round(2), expenses: exp.round(2), saved: (inc - exp).round(2) }
      }

      # Parameters for projection
      @monthly_contribution = (params[:contribution] || [@avg_monthly_savings, 0].max).to_f.round(2)
      @annual_return = (params[:return_rate] || 5.0).to_f
      @years = (params[:years] || 10).to_i.clamp(1, 40)
      @starting_balance = (params[:starting] || @total_saved).to_f

      # Build three scenarios
      @scenarios = [
        { name: "Conservative", rate: [@annual_return - 2, 0].max, color: "var(--text-secondary)" },
        { name: "Moderate", rate: @annual_return, color: "var(--primary)" },
        { name: "Aggressive", rate: @annual_return + 3, color: "var(--positive)" }
      ]

      @scenarios.each do |s|
        monthly_rate = s[:rate] / 100.0 / 12
        points = []
        balance = @starting_balance

        (@years * 12 + 1).times do |month|
          points << { month: month, balance: balance.round(2) }
          interest = balance * monthly_rate
          balance += interest + @monthly_contribution
        end

        s[:points] = points
        s[:final_balance] = points.last[:balance]
        s[:total_contributed] = @starting_balance + (@monthly_contribution * @years * 12)
        s[:total_interest] = s[:final_balance] - s[:total_contributed]
        s[:growth_pct] = s[:total_contributed] > 0 ? ((s[:final_balance] / s[:total_contributed] - 1) * 100).round(1) : 0
      end

      # Without any interest (just saving)
      @no_interest_final = @starting_balance + (@monthly_contribution * @years * 12)

      # Compound interest advantage
      moderate = @scenarios.find { |s| s[:name] == "Moderate" }
      @compound_advantage = moderate ? (moderate[:final_balance] - @no_interest_final).round(2) : 0

      # Milestones
      @milestones = []
      targets = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
      moderate_points = moderate ? moderate[:points] : []
      targets.each do |target|
        next if target <= @starting_balance
        hit = moderate_points.find { |p| p[:balance] >= target }
        if hit
          years_to = (hit[:month] / 12.0).round(1)
          @milestones << { target: target, month: hit[:month], years: years_to, date: Date.current >> hit[:month] }
        end
      end

      # What-if: different contribution levels
      @contribution_scenarios = [100, 250, 500, 1000, 2000].map { |contrib|
        monthly_rate = @annual_return / 100.0 / 12
        balance = @starting_balance
        (@years * 12).times do
          balance = balance * (1 + monthly_rate) + contrib
        end
        { contribution: contrib, final: balance.round(2), interest_earned: (balance - @starting_balance - contrib * @years * 12).round(2) }
      }
    end

    def wellness_scorecard
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 6.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 2000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }

      @overview = threads[:overview].value || {}
      transactions = threads[:transactions].value
      nw_result = threads[:net_worth].value || {}
      debt_result = threads[:debt].value || {}
      @goals = threads[:goals].value
      @funds = threads[:funds].value
      recurring_result = threads[:recurring].value || {}

      # Extract data
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }

      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end
      months_count = [monthly_expenses.count, 1].max
      avg_expenses = monthly_expenses.values.sum / months_count

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end
      avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0

      debts = debt_result.is_a?(Hash) ? (debt_result["debts"] || debt_result["debt_accounts"] || []) : Array(debt_result)
      debts = debts.select { |d| d.is_a?(Hash) }
      total_debt = debts.sum { |d| d["current_balance"].to_f }

      assets = nw_result.is_a?(Hash) ? (nw_result["assets"] || []) : []
      total_assets = assets.is_a?(Array) ? assets.sum { |a| a["balance"].to_f } : 0

      net_worth = total_assets - total_debt

      emergency_funds = @funds.select { |f| (f["name"] || "").downcase.match?(/emergency|rainy|safety/) }
      emergency_balance = emergency_funds.sum { |f| f["current_amount"].to_f }

      active_goals = @goals.select { |g| g["status"] == "active" }
      goals_progress = active_goals.any? ? (active_goals.sum { |g| g["percentage_complete"].to_f } / active_goals.count).round(1) : 0

      # Score each dimension (0-100)
      @dimensions = []

      # 1. Savings Rate
      savings_rate = avg_income > 0 ? ((avg_income - avg_expenses) / avg_income * 100).round(1) : 0
      savings_score = case savings_rate
                      when 20.. then 100
                      when 15..19.9 then 85
                      when 10..14.9 then 70
                      when 5..9.9 then 50
                      when 0..4.9 then 30
                      else 10
                      end
      @dimensions << {
        name: "Savings Rate", icon: "savings", score: savings_score,
        grade: score_to_grade(savings_score),
        detail: "#{savings_rate}% of income saved",
        tip: savings_rate >= 20 ? "Excellent savings discipline!" : "Aim for 20%+ savings rate"
      }

      # 2. Emergency Fund
      months_covered = avg_expenses > 0 ? (emergency_balance / avg_expenses).round(1) : 0
      ef_score = case months_covered
                 when 6.. then 100
                 when 3..5.9 then 75
                 when 1..2.9 then 50
                 when 0.1..0.9 then 25
                 else 0
                 end
      @dimensions << {
        name: "Emergency Fund", icon: "health_and_safety", score: ef_score,
        grade: score_to_grade(ef_score),
        detail: "#{months_covered} months of expenses covered",
        tip: months_covered >= 6 ? "Well-prepared for emergencies!" : "Build to 6 months of expenses"
      }

      # 3. Debt Health
      debt_to_income = avg_income > 0 ? (total_debt / (avg_income * 12) * 100).round(1) : 0
      high_rate_debt = debts.count { |d| d["interest_rate"].to_f > 15 }
      debt_score = if total_debt == 0
        100
      elsif debt_to_income < 20 && high_rate_debt == 0
        85
      elsif debt_to_income < 36
        65
      elsif debt_to_income < 50
        40
      else
        20
      end
      @dimensions << {
        name: "Debt Health", icon: "credit_card", score: debt_score,
        grade: score_to_grade(debt_score),
        detail: total_debt > 0 ? "#{number_to_currency(total_debt)} total · #{debt_to_income}% DTI" : "Debt-free!",
        tip: total_debt == 0 ? "Congratulations on being debt-free!" : high_rate_debt > 0 ? "Prioritize paying off high-interest debt" : "Keep making consistent payments"
      }

      # 4. Net Worth Trend
      nw_positive = net_worth > 0
      nw_score = if net_worth > avg_income * 12 then 100
                 elsif net_worth > avg_income * 6 then 80
                 elsif net_worth > 0 then 60
                 elsif net_worth > -avg_income * 6 then 35
                 else 15
                 end
      @dimensions << {
        name: "Net Worth", icon: "account_balance", score: nw_score,
        grade: score_to_grade(nw_score),
        detail: number_to_currency(net_worth),
        tip: nw_positive ? "Positive net worth — keep growing!" : "Focus on building assets and reducing debt"
      }

      # 5. Budget Adherence
      budget_spent = @overview.is_a?(Hash) ? @overview["total_spent"].to_f : 0
      budget_limit = @overview.is_a?(Hash) ? @overview["total_budgeted"].to_f : 0
      budget_pct = budget_limit > 0 ? (budget_spent / budget_limit * 100).round(1) : 0
      budget_score = case budget_pct
                     when 0..80 then 100
                     when 80..95 then 80
                     when 95..100 then 60
                     when 100..110 then 40
                     else 20
                     end
      budget_score = 50 if budget_limit == 0 # No budget set
      @dimensions << {
        name: "Budget Discipline", icon: "receipt_long", score: budget_score,
        grade: score_to_grade(budget_score),
        detail: budget_limit > 0 ? "#{budget_pct}% of budget used" : "No active budget",
        tip: budget_limit == 0 ? "Create a budget to track spending" : budget_pct <= 100 ? "Under budget — great discipline!" : "Overspending — review categories"
      }

      # 6. Goal Progress
      goal_score = if active_goals.empty? then 40
                   elsif goals_progress >= 75 then 100
                   elsif goals_progress >= 50 then 80
                   elsif goals_progress >= 25 then 60
                   else 40
                   end
      @dimensions << {
        name: "Goal Progress", icon: "flag", score: goal_score,
        grade: score_to_grade(goal_score),
        detail: active_goals.any? ? "#{goals_progress}% average across #{active_goals.count} goals" : "No active goals",
        tip: active_goals.empty? ? "Set financial goals to stay motivated" : "Keep working toward your targets"
      }

      # Overall score (weighted)
      weights = { "Savings Rate" => 25, "Emergency Fund" => 20, "Debt Health" => 20, "Net Worth" => 15, "Budget Discipline" => 10, "Goal Progress" => 10 }
      @overall_score = (@dimensions.sum { |d| d[:score] * (weights[d[:name]] || 10) } / weights.values.sum.to_f).round(0)
      @overall_grade = score_to_grade(@overall_score)

      # Key stats for display
      @avg_income = avg_income
      @avg_expenses = avg_expenses
      @savings_rate = savings_rate
      @total_debt = total_debt
      @net_worth = net_worth
      @emergency_months = months_covered
    end

    def recurring_analyzer
      threads = {}
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 12.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 5000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }

      recurring_result = threads[:recurring].value || {}
      transactions = threads[:transactions].value

      @recurring_items = recurring_result.is_a?(Hash) ? (recurring_result["items"] || recurring_result["recurring"] || []) : Array(recurring_result)
      @recurring_items = @recurring_items.select { |r| r.is_a?(Hash) }

      expenses = transactions.select { |t| t["transaction_type"] != "income" }

      # Total monthly recurring
      @monthly_total = @recurring_items.sum { |r| r["amount"].to_f }
      @annual_total = @monthly_total * 12

      # Detect recurring patterns from transactions (merchant frequency)
      merchant_history = {}
      expenses.each do |t|
        merchant = t["merchant"].presence || t["description"].presence
        next unless merchant
        merchant_history[merchant] ||= []
        merchant_history[merchant] << { date: t["transaction_date"], amount: t["amount"].to_f }
      end

      # Find merchants that appear monthly-ish (at least 3 times with ~30-day gaps)
      @detected_subscriptions = []
      merchant_history.each do |merchant, txns|
        next if txns.count < 3
        sorted = txns.sort_by { |t| t[:date].to_s }
        amounts = sorted.map { |t| t[:amount] }
        dates = sorted.map { |t| Date.parse(t[:date]) rescue nil }.compact
        next if dates.count < 3

        # Check if gaps are roughly monthly (20-40 days)
        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }
        avg_gap = gaps.sum.to_f / gaps.count
        next unless avg_gap.between?(15, 45)

        # Price change detection
        first_amount = amounts.first(3).sum / 3.0
        last_amount = amounts.last(3).sum / 3.0
        price_change = last_amount - first_amount
        price_change_pct = first_amount > 0 ? ((price_change / first_amount) * 100).round(1) : 0

        @detected_subscriptions << {
          merchant: merchant,
          count: txns.count,
          avg_amount: (amounts.sum / amounts.count).round(2),
          last_amount: amounts.last.round(2),
          first_seen: dates.first,
          last_seen: dates.last,
          avg_gap_days: avg_gap.round(0),
          price_change: price_change.round(2),
          price_change_pct: price_change_pct,
          has_increased: price_change > 1
        }
      end

      @detected_subscriptions.sort_by! { |s| -s[:last_amount] }

      # Subscription creep (compare first 6 months vs last 6 months)
      six_months_ago = 6.months.ago.to_date
      early_subs = @detected_subscriptions.select { |s| s[:first_seen] < six_months_ago }
      @early_total = early_subs.sum { |s| s[:avg_amount] }
      @current_total = @detected_subscriptions.sum { |s| s[:last_amount] }
      @creep_amount = (@current_total - @early_total).round(2)

      # Price increases
      @price_increases = @detected_subscriptions.select { |s| s[:has_increased] }.sort_by { |s| -s[:price_change] }

      # Category breakdown
      @by_category = {}
      @recurring_items.each do |r|
        cat = r["category"] || r["budget_category"] || "Other"
        @by_category[cat] ||= { count: 0, total: 0 }
        @by_category[cat][:count] += 1
        @by_category[cat][:total] += r["amount"].to_f
      end
      @by_category = @by_category.sort_by { |_, v| -v[:total] }.to_h

      # Upcoming renewals (next 7 days)
      @upcoming = @recurring_items.select { |r|
        next_date = r["next_date"] || r["next_occurrence"]
        next unless next_date
        d = Date.parse(next_date.to_s) rescue nil
        d && d >= Date.current && d <= 7.days.from_now.to_date
      }.sort_by { |r| r["next_date"] || r["next_occurrence"] || "" }
    end

    def goal_planner
      threads = {}
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 6.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 2000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }

      @goals = threads[:goals].value
      transactions = threads[:transactions].value
      @funds = threads[:funds].value

      # Monthly savings
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }
      monthly_income = {}
      income_txns.each { |t| month = t["transaction_date"]&.to_s&.slice(0, 7); next unless month; monthly_income[month] ||= 0; monthly_income[month] += t["amount"].to_f }
      monthly_expenses = {}
      expense_txns.each { |t| month = t["transaction_date"]&.to_s&.slice(0, 7); next unless month; monthly_expenses[month] ||= 0; monthly_expenses[month] += t["amount"].to_f }

      avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      avg_expenses = monthly_expenses.values.any? ? monthly_expenses.values.sum / [monthly_expenses.count, 1].max : 0
      @monthly_savings = avg_income - avg_expenses
      @available_for_goals = [@monthly_savings * 0.5, 0].max # Suggest allocating 50% of savings to goals

      # Enrich goals
      @active_goals = @goals.select { |g| g["status"] == "active" }.map { |g|
        target = g["target_amount"].to_f
        current = (g["effective_current_amount"] || g["current_amount"]).to_f
        remaining = [target - current, 0].max
        pct = target > 0 ? (current / target * 100).round(1) : 0
        target_date = g["target_date"].present? ? (Date.parse(g["target_date"]) rescue nil) : nil
        months_left = target_date ? [(target_date - Date.current).to_i / 30.0, 0].max : nil
        monthly_needed = months_left && months_left > 0 ? (remaining / months_left).round(2) : nil

        # Priority score (higher = more urgent)
        priority = 50
        priority += 25 if months_left && months_left < 3
        priority += 15 if months_left && months_left < 6
        priority -= 10 if pct > 75
        priority += 20 if pct < 25 && months_left && months_left < 12
        priority = priority.clamp(0, 100)

        # Estimated completion without extra funding
        months_to_complete = if @monthly_savings > 0 && remaining > 0
          # Proportional: if this goal gets its share of savings
          share = @active_goals ? (@available_for_goals / [@goals.select { |gg| gg["status"] == "active" }.count, 1].max) : @available_for_goals
          share > 0 ? (remaining / share).ceil : nil
        end

        {
          id: g["id"],
          name: g["name"],
          target: target,
          current: current,
          remaining: remaining,
          pct: pct,
          target_date: target_date,
          months_left: months_left&.round(1),
          monthly_needed: monthly_needed,
          priority: priority,
          on_track: monthly_needed && @available_for_goals > 0 ? monthly_needed <= @available_for_goals / [@goals.select { |gg| gg["status"] == "active" }.count, 1].max : nil,
          months_to_complete: months_to_complete,
          icon: g["icon"] || "flag"
        }
      }

      @active_goals.sort_by! { |g| -g[:priority] }

      @completed_goals = @goals.select { |g| g["status"] == "completed" }

      # Summary
      @total_target = @active_goals.sum { |g| g[:target] }
      @total_saved = @active_goals.sum { |g| g[:current] }
      @total_remaining = @active_goals.sum { |g| g[:remaining] }
      @overall_pct = @total_target > 0 ? (@total_saved / @total_target * 100).round(1) : 0
      @on_track_count = @active_goals.count { |g| g[:on_track] == true }
      @at_risk_count = @active_goals.count { |g| g[:on_track] == false }
    end

    def income_allocator
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 6.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 3000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:recurring] = Thread.new { budget_client.recurring_summary rescue {} }

      @overview = threads[:overview].value || {}
      transactions = threads[:transactions].value
      debt_result = threads[:debt].value || {}
      @goals = threads[:goals].value
      recurring_result = threads[:recurring].value || {}

      # Income calculation
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expenses = transactions.select { |t| t["transaction_type"] != "income" }

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end
      @avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0

      # Use params income or calculated
      @income = (params[:income] || @avg_income).to_f
      @pay_frequency = params[:frequency] || "monthly"
      @per_paycheck = case @pay_frequency
                      when "weekly" then @income / 4.33
                      when "biweekly" then @income / 2.17
                      when "semimonthly" then @income / 2
                      else @income
                      end

      # Current spending breakdown by category
      @category_spending = {}
      expenses.each do |t|
        cat = t["category"] || t["budget_category"] || "Other"
        @category_spending[cat] ||= 0
        @category_spending[cat] += t["amount"].to_f
      end
      months_count = (transactions.map { |t| t["transaction_date"]&.to_s&.slice(0, 7) }.compact.uniq.count)
      months_count = [months_count, 1].max
      @category_spending = @category_spending.transform_values { |v| (v / months_count).round(2) }
      @category_spending = @category_spending.sort_by { |_, v| -v }.to_h

      # Classify into needs/wants/savings
      needs_keywords = %w[housing rent mortgage utilities insurance groceries transportation healthcare debt phone internet water electric gas]
      @needs_total = 0
      @wants_total = 0
      @category_spending.each do |cat, amount|
        if needs_keywords.any? { |kw| cat.downcase.include?(kw) }
          @needs_total += amount
        else
          @wants_total += amount
        end
      end
      @savings_total = [@income - @needs_total - @wants_total, 0].max

      # Current percentages
      @current_pcts = {
        needs: @income > 0 ? (@needs_total / @income * 100).round(1) : 0,
        wants: @income > 0 ? (@wants_total / @income * 100).round(1) : 0,
        savings: @income > 0 ? (@savings_total / @income * 100).round(1) : 0
      }

      # Debt info
      debts = debt_result.is_a?(Hash) ? (debt_result["debts"] || debt_result["debt_accounts"] || []) : []
      debts = debts.select { |d| d.is_a?(Hash) }
      @total_debt = debts.sum { |d| d["current_balance"].to_f }
      @min_debt_payment = debts.sum { |d| d["minimum_payment"].to_f }

      # Recurring obligations
      @recurring_items = recurring_result.is_a?(Hash) ? (recurring_result["items"] || recurring_result["recurring"] || []) : Array(recurring_result)
      @recurring_total = @recurring_items.sum { |r| r["amount"].to_f }

      # Budgeting frameworks
      @frameworks = [
        {
          name: "50/30/20",
          description: "The classic rule: 50% needs, 30% wants, 20% savings",
          buckets: [
            { name: "Needs", pct: 50, amount: (@income * 0.50).round(2), color: "var(--primary)", icon: "home" },
            { name: "Wants", pct: 30, amount: (@income * 0.30).round(2), color: "#9c27b0", icon: "shopping_bag" },
            { name: "Savings & Debt", pct: 20, amount: (@income * 0.20).round(2), color: "var(--positive)", icon: "savings" }
          ]
        },
        {
          name: "60/20/20",
          description: "Conservative: 60% needs, 20% wants, 20% savings — for higher cost-of-living areas",
          buckets: [
            { name: "Needs", pct: 60, amount: (@income * 0.60).round(2), color: "var(--primary)", icon: "home" },
            { name: "Wants", pct: 20, amount: (@income * 0.20).round(2), color: "#9c27b0", icon: "shopping_bag" },
            { name: "Savings & Debt", pct: 20, amount: (@income * 0.20).round(2), color: "var(--positive)", icon: "savings" }
          ]
        },
        {
          name: "70/20/10",
          description: "Starter: 70% living expenses, 20% savings, 10% giving/fun",
          buckets: [
            { name: "Living", pct: 70, amount: (@income * 0.70).round(2), color: "var(--primary)", icon: "home" },
            { name: "Savings", pct: 20, amount: (@income * 0.20).round(2), color: "var(--positive)", icon: "savings" },
            { name: "Giving & Fun", pct: 10, amount: (@income * 0.10).round(2), color: "#ff5722", icon: "volunteer_activism" }
          ]
        },
        {
          name: "80/20",
          description: "Pay Yourself First: save 20% automatically, spend 80% freely",
          buckets: [
            { name: "Everything Else", pct: 80, amount: (@income * 0.80).round(2), color: "var(--primary)", icon: "payments" },
            { name: "Savings", pct: 20, amount: (@income * 0.20).round(2), color: "var(--positive)", icon: "savings" }
          ]
        }
      ]

      # Recommended framework based on situation
      @recommended = if @current_pcts[:needs] > 55
        "60/20/20"
      elsif @total_debt > @income * 6
        "70/20/10"
      else
        "50/30/20"
      end

      # Active goals monthly allocation
      active_goals = @goals.select { |g| g["status"] == "active" }
      @goals_monthly = active_goals.sum { |g|
        remaining = g["target_amount"].to_f - (g["effective_current_amount"] || g["current_amount"]).to_f
        months_left = g["target_date"].present? ? [(Date.parse(g["target_date"]) - Date.current).to_i / 30.0, 1].max : 12
        (remaining / months_left).round(2)
      }
    end

    def spending_anomalies
      result = budget_client.transactions(
        start_date: 6.months.ago.to_date.to_s,
        end_date: Date.current.to_s,
        per_page: 5000
      )
      transactions = result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      expenses = transactions.select { |t| t["transaction_type"] != "income" }

      # Group by merchant
      by_merchant = {}
      expenses.each do |t|
        merchant = t["merchant"].presence || t["description"].presence || "Unknown"
        by_merchant[merchant] ||= []
        by_merchant[merchant] << t
      end

      # Detect anomalies
      @anomalies = []

      # 1. Unusually large single transactions (>2x average for that merchant)
      by_merchant.each do |merchant, txns|
        next if txns.count < 3
        amounts = txns.map { |t| t["amount"].to_f }
        avg = amounts.sum / amounts.count
        std_dev = Math.sqrt(amounts.map { |a| (a - avg) ** 2 }.sum / amounts.count)
        threshold = avg + [std_dev * 2, avg * 0.5].max

        txns.each do |t|
          next unless t["amount"].to_f > threshold && t["amount"].to_f > avg * 1.5
          @anomalies << {
            type: :large_transaction,
            severity: t["amount"].to_f > avg * 3 ? :high : :medium,
            icon: "warning",
            title: "Unusually large at #{merchant}",
            detail: "#{number_to_currency(t["amount"])} vs avg #{number_to_currency(avg)}",
            date: t["transaction_date"],
            amount: t["amount"].to_f,
            avg: avg.round(2),
            merchant: merchant,
            multiplier: (t["amount"].to_f / avg).round(1)
          }
        end
      end

      # 2. Category spending spikes (this month vs prior months)
      by_category_month = {}
      expenses.each do |t|
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        by_category_month[cat] ||= {}
        by_category_month[cat][month] ||= 0
        by_category_month[cat][month] += t["amount"].to_f
      end

      current_month = Date.current.strftime("%Y-%m")
      @category_spikes = []

      by_category_month.each do |cat, months|
        prior_months = months.reject { |m, _| m == current_month }
        next if prior_months.count < 2
        prior_avg = prior_months.values.sum / prior_months.count
        current_val = months[current_month] || 0
        next if prior_avg < 10 || current_val < 20

        if current_val > prior_avg * 1.5
          pct_increase = ((current_val / prior_avg - 1) * 100).round(0)
          @category_spikes << {
            category: cat,
            current: current_val.round(2),
            avg: prior_avg.round(2),
            pct_increase: pct_increase,
            severity: pct_increase > 100 ? :high : :medium
          }
        end
      end
      @category_spikes.sort_by! { |s| -s[:pct_increase] }

      # 3. New merchants (first-time spending)
      @new_merchants = []
      by_merchant.each do |merchant, txns|
        dates = txns.map { |t| t["transaction_date"].to_s }.sort
        first_date = dates.first
        next unless first_date
        first = Date.parse(first_date) rescue nil
        next unless first && first >= 30.days.ago.to_date
        @new_merchants << {
          merchant: merchant,
          first_date: first_date,
          total: txns.sum { |t| t["amount"].to_f }.round(2),
          count: txns.count
        }
      end
      @new_merchants.sort_by! { |m| -m[:total] }

      # 4. Frequency anomalies (more visits than usual)
      @frequency_anomalies = []
      by_merchant.each do |merchant, txns|
        next if txns.count < 4

        monthly_counts = {}
        txns.each do |t|
          month = t["transaction_date"]&.to_s&.slice(0, 7)
          next unless month
          monthly_counts[month] ||= 0
          monthly_counts[month] += 1
        end

        prior = monthly_counts.reject { |m, _| m == current_month }
        next if prior.count < 2
        avg_freq = prior.values.sum.to_f / prior.count
        current_freq = monthly_counts[current_month] || 0

        if current_freq > avg_freq * 2 && current_freq >= 3
          @frequency_anomalies << {
            merchant: merchant,
            current_count: current_freq,
            avg_count: avg_freq.round(1),
            current_total: txns.select { |t| t["transaction_date"]&.to_s&.start_with?(current_month) }.sum { |t| t["amount"].to_f }.round(2)
          }
        end
      end
      @frequency_anomalies.sort_by! { |f| -f[:current_count] }

      # 5. Daily spending trend
      @daily_trend = {}
      expenses.select { |t| t["transaction_date"]&.to_s&.start_with?(current_month) }.each do |t|
        day = t["transaction_date"].to_s
        @daily_trend[day] ||= 0
        @daily_trend[day] += t["amount"].to_f
      end

      # Summary stats
      all_amounts = expenses.map { |t| t["amount"].to_f }
      @total_anomalies = @anomalies.count + @category_spikes.count + @frequency_anomalies.count
      @high_severity = @anomalies.count { |a| a[:severity] == :high } + @category_spikes.count { |s| s[:severity] == :high }
    end

    def net_worth_forecast
      threads = {}
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: 12.months.ago.to_date.to_s,
          end_date: Date.current.to_s,
          per_page: 3000
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:snapshots] = Thread.new { budget_client.net_worth_history rescue [] }

      nw_result = threads[:net_worth].value || {}
      debt_result = threads[:debt].value || {}
      transactions = threads[:transactions].value
      @goals = threads[:goals].value
      snapshots_result = threads[:snapshots].value

      # Current net worth breakdown
      @assets = nw_result.is_a?(Hash) ? (nw_result["assets"] || []) : []
      @assets = @assets.is_a?(Array) ? @assets : []
      @total_assets = @assets.sum { |a| a["balance"].to_f }

      debts = debt_result.is_a?(Hash) ? (debt_result["debts"] || debt_result["debt_accounts"] || []) : Array(debt_result)
      debts = debts.select { |d| d.is_a?(Hash) }
      @total_debt = debts.sum { |d| d["current_balance"].to_f }
      @current_net_worth = @total_assets - @total_debt

      # Historical snapshots
      @snapshots = snapshots_result.is_a?(Array) ? snapshots_result : (snapshots_result.is_a?(Hash) ? (snapshots_result["snapshots"] || []) : [])
      @snapshots = @snapshots.sort_by { |s| s["date"] || s["created_at"] || "" }

      # Monthly savings rate from transaction history
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      monthly_expenses = {}
      expense_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      @avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      @avg_expenses = monthly_expenses.values.any? ? monthly_expenses.values.sum / [monthly_expenses.count, 1].max : 0
      @monthly_savings = @avg_income - @avg_expenses
      @savings_rate = @avg_income > 0 ? ((@monthly_savings / @avg_income) * 100).round(1) : 0

      # Debt payoff rate
      @monthly_debt_payment = debts.sum { |d| d["minimum_payment"].to_f }
      @avg_interest_rate = if @total_debt > 0
        debts.sum { |d| d["interest_rate"].to_f * d["current_balance"].to_f } / @total_debt
      else
        0
      end.round(2)

      # Projection params
      @years = (params[:years] || 10).to_i.clamp(1, 30)
      @asset_growth_rate = (params[:asset_growth] || 7.0).to_f
      @monthly_contribution = (params[:monthly_saving] || [@monthly_savings, 0].max).to_f

      # Build projection
      @projection = []
      assets = @total_assets
      debt = @total_debt
      monthly_asset_rate = @asset_growth_rate / 100.0 / 12
      monthly_debt_rate = @avg_interest_rate / 100.0 / 12

      (@years * 12 + 1).times do |month|
        nw = assets - debt
        @projection << { month: month, assets: assets.round(2), debt: debt.round(2), net_worth: nw.round(2) }

        # Grow assets
        assets += assets * monthly_asset_rate
        assets += @monthly_contribution

        # Reduce debt
        if debt > 0
          interest = debt * monthly_debt_rate
          debt += interest
          payment = [@monthly_debt_payment, debt].min
          debt -= payment
          debt = 0 if debt < 0
        end
      end

      @projected_net_worth = @projection.last[:net_worth]
      @projected_assets = @projection.last[:assets]
      @projected_debt = @projection.last[:debt]

      # Milestones
      @nw_milestones = []
      targets = [0, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000]
      targets.each do |target|
        next if target <= @current_net_worth
        hit = @projection.find { |p| p[:net_worth] >= target }
        if hit
          @nw_milestones << { target: target, month: hit[:month], years: (hit[:month] / 12.0).round(1), date: Date.current >> hit[:month] }
        end
      end

      # Scenario comparison
      @scenarios = [
        { name: "Conservative", asset_rate: [@asset_growth_rate - 3, 0].max, save_rate: @monthly_contribution * 0.8 },
        { name: "Current Pace", asset_rate: @asset_growth_rate, save_rate: @monthly_contribution },
        { name: "Optimistic", asset_rate: @asset_growth_rate + 3, save_rate: @monthly_contribution * 1.25 }
      ]

      @scenarios.each do |s|
        a = @total_assets
        d = @total_debt
        mar = s[:asset_rate] / 100.0 / 12

        (@years * 12).times do
          a += a * mar + s[:save_rate]
          if d > 0
            d += d * monthly_debt_rate
            d -= [@monthly_debt_payment, d].min
            d = 0 if d < 0
          end
        end

        s[:final_nw] = (a - d).round(2)
        s[:final_assets] = a.round(2)
        s[:final_debt] = d.round(2)
      end

      # Debt-free date
      if @total_debt > 0 && @monthly_debt_payment > 0
        d = @total_debt
        months = 0
        while d > 0 && months < 600
          months += 1
          d += d * monthly_debt_rate
          d -= [@monthly_debt_payment, d].min
          d = 0 if d < 0
        end
        @debt_free_months = months
        @debt_free_date = Date.current >> months
      end
    end

    def expense_forecast
      # Fetch transactions
      result = budget_client.transactions(per_page: 1000) rescue nil
      if result.is_a?(Hash)
        transactions = result["transactions"] || []
      else
        transactions = Array(result)
      end

      # Filter to expenses only (amount < 0 or has a category indicating expense)
      expenses = transactions.select { |t|
        amt = t["amount"].to_f rescue 0
        amt < 0 || (t["category"].is_a?(String) && t["category"].present? && t["transaction_type"] != "income")
      }

      # Normalize amounts to positive for expense analysis
      expenses.each { |t| t["_abs_amount"] = t["amount"].to_f.abs }

      # Group expenses by month and category
      now = Date.current
      six_months_ago = (now << 6).beginning_of_month
      recent_expenses = expenses.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= six_months_ago && d <= now
      }

      # Build monthly category data for last 6 months
      monthly_cat_data = {}  # { category => { "2026-01" => total, ... } }
      monthly_totals = {}    # { "2026-01" => total }
      months_list = (0..5).map { |i| (now << i).strftime("%Y-%m") }.reverse

      recent_expenses.each do |t|
        cat = t["category"].is_a?(String) && t["category"].present? ? t["category"] : "Uncategorized"
        month = t["transaction_date"].to_s.slice(0, 7) rescue nil
        next unless month && months_list.include?(month)

        monthly_cat_data[cat] ||= {}
        monthly_cat_data[cat][month] = (monthly_cat_data[cat][month] || 0) + t["_abs_amount"].to_f
        monthly_totals[month] = (monthly_totals[month] || 0) + t["_abs_amount"].to_f
      end

      # Monthly spending averages by category
      @category_averages = {}
      monthly_cat_data.each do |cat, month_data|
        values = months_list.map { |m| month_data[m] || 0 }
        active_months = values.count { |v| v > 0 }
        @category_averages[cat] = active_months > 0 ? values.sum / active_months : 0
      end

      # Spending trend per category (compare last 3 months avg to prior 3 months avg)
      @category_trends = {}
      monthly_cat_data.each do |cat, month_data|
        recent_3 = months_list.last(3).map { |m| month_data[m] || 0 }
        prior_3 = months_list.first(3).map { |m| month_data[m] || 0 }
        recent_avg = recent_3.sum / [recent_3.count { |v| v > 0 }, 1].max.to_f
        prior_avg = prior_3.sum / [prior_3.count { |v| v > 0 }, 1].max.to_f

        if prior_avg == 0 && recent_avg == 0
          @category_trends[cat] = { direction: :stable, pct_change: 0 }
        elsif prior_avg == 0
          @category_trends[cat] = { direction: :increasing, pct_change: 100 }
        else
          pct = ((recent_avg - prior_avg) / prior_avg * 100).round(1) rescue 0
          direction = if pct > 15
            :increasing
          elsif pct < -15
            :decreasing
          else
            :stable
          end
          @category_trends[cat] = { direction: direction, pct_change: pct }
        end
      end

      # Weighted moving average forecast per category (recent months weighted more)
      weights = [1, 1, 1, 2, 2, 3]  # older to newer
      @category_forecasts = {}
      monthly_cat_data.each do |cat, month_data|
        values = months_list.map { |m| month_data[m] || 0 }
        weighted_sum = 0
        weight_total = 0
        values.each_with_index do |v, i|
          w = weights[i] || 1
          weighted_sum += v * w
          weight_total += w
        end
        @category_forecasts[cat] = weight_total > 0 ? (weighted_sum / weight_total.to_f).round(2) : 0
      end

      # Confidence intervals (based on standard deviation)
      @confidence_intervals = {}
      monthly_cat_data.each do |cat, month_data|
        values = months_list.map { |m| month_data[m] || 0 }
        mean = values.sum / [values.size, 1].max.to_f
        variance = values.map { |v| (v - mean) ** 2 }.sum / [values.size, 1].max.to_f
        std_dev = Math.sqrt(variance) rescue 0
        forecast = @category_forecasts[cat] || 0
        @confidence_intervals[cat] = {
          low: [forecast - std_dev, 0].max.round(2),
          high: (forecast + std_dev).round(2),
          std_dev: std_dev.round(2)
        }
      end

      # Total forecasts for next 1, 3, 6 months
      next_month_total = @category_forecasts.values.sum
      @forecast_1_month = next_month_total.round(2)
      @forecast_3_month = (next_month_total * 3).round(2)
      @forecast_6_month = (next_month_total * 6).round(2)

      # Average monthly spend
      filled_months = months_list.select { |m| (monthly_totals[m] || 0) > 0 }
      @avg_monthly_spend = filled_months.any? ? (monthly_totals.values.sum / filled_months.size.to_f).round(2) : 0

      # Trending counts
      @trending_up_count = @category_trends.count { |_, t| t[:direction] == :increasing }
      @trending_down_count = @category_trends.count { |_, t| t[:direction] == :decreasing }

      # Actual monthly totals for chart (last 3 months)
      @chart_actual_months = months_list.last(3).map { |m|
        { month: m, total: (monthly_totals[m] || 0).round(2) }
      }

      # Forecast months for chart (next 3 months)
      @chart_forecast_months = (1..3).map { |i|
        future_month = (now >> i).strftime("%Y-%m")
        { month: future_month, total: @forecast_1_month }
      }

      # Seasonal patterns: flag categories with seasonal spikes
      @seasonal_patterns = []
      monthly_cat_data.each do |cat, month_data|
        values = months_list.map { |m| month_data[m] || 0 }
        mean = values.sum / [values.size, 1].max.to_f
        next if mean == 0

        values.each_with_index do |v, i|
          if v > mean * 2 && v > 50
            month_name = Date.parse("#{months_list[i]}-01").strftime("%B %Y") rescue months_list[i]
            @seasonal_patterns << {
              category: cat,
              month: month_name,
              amount: v.round(2),
              avg: mean.round(2),
              multiplier: (v / mean).round(1)
            }
          end
        end
      end

      # Trend alerts: categories with significant increases (>25%)
      @trend_alerts = @category_trends.select { |cat, t|
        t[:direction] == :increasing && t[:pct_change] > 25 && (@category_averages[cat] || 0) > 20
      }.map { |cat, t|
        {
          category: cat,
          pct_change: t[:pct_change],
          avg: (@category_averages[cat] || 0).round(2),
          forecast: (@category_forecasts[cat] || 0).round(2)
        }
      }.sort_by { |a| -a[:pct_change] }

      # Budget variance forecast (compare to budget limits if available)
      @budget_variances = []
      begin
        budget_result = budget_client.budgets rescue nil
        if budget_result
          budgets_list = budget_result.is_a?(Hash) ? (budget_result["budgets"] || []) : Array(budget_result)
          current_budget = budgets_list.first
          if current_budget.is_a?(Hash)
            categories = current_budget["categories"] || current_budget["budget_categories"] || []
            categories.each do |bc|
              cat_name = bc["name"] || bc["category"] || ""
              limit = bc["amount"].to_f rescue 0
              next if limit <= 0
              forecast = @category_forecasts[cat_name] || 0
              next if forecast <= 0
              variance = forecast - limit
              @budget_variances << {
                category: cat_name,
                budget_limit: limit.round(2),
                forecast: forecast.round(2),
                variance: variance.round(2),
                over_budget: variance > 0
              }
            end
          end
        end
      rescue => e
        # Budget data unavailable, skip variance analysis
      end

      # Sort categories by forecast amount descending for display
      @sorted_categories = @category_forecasts.sort_by { |_, v| -v }.map(&:first)
    end

    def bill_splitter
      # Fetch transactions
      result = budget_client.transactions(per_page: 500) rescue nil
      if result.is_a?(Hash)
        transactions = result["transactions"] || []
      else
        transactions = Array(result)
      end

      # Filter to expenses only
      expenses = transactions.select { |t|
        t["transaction_type"] != "income"
      }

      # Normalize amounts to positive
      expenses.each { |t| t["_abs_amount"] = t["amount"].to_f.abs }

      # Define shared vs personal category mappings
      shared_category_keywords = {
        "Rent / Mortgage" => %w[rent mortgage housing],
        "Utilities" => %w[utilities electric gas water power energy sewer],
        "Internet / Cable" => %w[internet cable wifi broadband telecom phone],
        "Groceries" => %w[groceries food grocery supermarket],
        "Streaming / Subscriptions" => %w[streaming subscription netflix hulu spotify disney entertainment],
        "Insurance" => %w[insurance renters homeowners],
        "Household" => %w[household cleaning supplies home maintenance]
      }

      personal_category_keywords = %w[clothing personal dining restaurant coffee fast\ food
        health medical fitness gym beauty salon haircut gas fuel parking
        transport rideshare uber lyft travel vacation hobby gift shopping]

      # Classify transactions into shared vs personal
      @shared_expenses = {}  # { category_label => total }
      @personal_total = 0.0
      @uncategorized_total = 0.0

      now = Date.current
      start_of_period = (now << 3).beginning_of_month
      recent_expenses = expenses.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= start_of_period && d <= now
      }

      # Count months for averaging
      months_in_period = ((now.year * 12 + now.month) - (start_of_period.year * 12 + start_of_period.month)) + 1
      months_in_period = [months_in_period, 1].max

      recent_expenses.each do |t|
        cat = (t["category"] || t["budget_category"] || "").to_s.downcase
        amt = t["_abs_amount"].to_f

        matched_shared = false
        shared_category_keywords.each do |label, keywords|
          if keywords.any? { |kw| cat.include?(kw) }
            @shared_expenses[label] ||= 0.0
            @shared_expenses[label] += amt
            matched_shared = true
            break
          end
        end

        unless matched_shared
          if personal_category_keywords.any? { |kw| cat.include?(kw) }
            @personal_total += amt
          elsif cat.present?
            # Unknown categories default to personal
            @personal_total += amt
          else
            @uncategorized_total += amt
            @personal_total += amt
          end
        end
      end

      # Monthly averages
      @shared_monthly = {}
      @shared_expenses.each { |label, total| @shared_monthly[label] = (total / months_in_period).round(2) }

      @total_shared_monthly = @shared_monthly.values.sum.round(2)
      @total_personal_monthly = (@personal_total / months_in_period).round(2)
      @total_monthly = @total_shared_monthly + @total_personal_monthly

      # Split scenarios: 2-way, 3-way, 4-way
      @split_scenarios = [2, 3, 4].map { |n|
        per_person = (@total_shared_monthly / [n, 1].max).round(2)
        savings = (@total_shared_monthly - per_person).round(2)
        {
          people: n,
          per_person: per_person,
          savings: savings,
          total_with_personal: (per_person + @total_personal_monthly).round(2)
        }
      }

      # Category breakdown for split table
      @category_splits = @shared_monthly.sort_by { |_, v| -v }.map { |label, monthly|
        {
          category: label,
          monthly: monthly,
          split_2: (monthly / 2.0).round(2),
          split_3: (monthly / 3.0).round(2),
          split_4: (monthly / 4.0).round(2)
        }
      }

      # Income-proportional split example (60/40)
      @income_split_ratios = [
        { label: "Higher earner (60%)", pct: 60, amount: (@total_shared_monthly * 0.6).round(2) },
        { label: "Lower earner (40%)", pct: 40, amount: (@total_shared_monthly * 0.4).round(2) }
      ]

      # Shared vs personal percentage
      @shared_pct = @total_monthly > 0 ? ((@total_shared_monthly / @total_monthly) * 100).round(1) : 0
      @personal_pct = @total_monthly > 0 ? ((@total_personal_monthly / @total_monthly) * 100).round(1) : 0

      # Number of shareable categories
      @shareable_categories_count = @shared_monthly.count { |_, v| v > 0 }
    end

    def subscription_manager
      begin
        result = budget_client.transactions(per_page: 1000)
        transactions = result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      rescue => e
        transactions = []
        flash.now[:alert] = "Could not load transactions: #{e.message}"
      end

      transactions = transactions.select { |t| t.is_a?(Hash) }
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }

      # Group transactions by merchant/description
      merchant_history = {}
      expenses.each do |t|
        merchant = (t["merchant"].presence || t["description"].presence || "").strip
        next if merchant.blank?
        merchant_history[merchant] ||= []
        merchant_history[merchant] << {
          date: t["transaction_date"].to_s,
          amount: t["amount"].to_f,
          category: t["category"] || t["budget_category"] || "Other"
        }
      end

      # Detect recurring subscriptions
      @subscriptions = []
      merchant_history.each do |merchant, txns|
        next if txns.count < 2
        sorted = txns.sort_by { |t| t[:date] }
        dates = sorted.map { |t| Date.parse(t[:date]) rescue nil }.compact
        next if dates.count < 2
        amounts = sorted.map { |t| t[:amount] }
        categories = sorted.map { |t| t[:category] }

        gaps = dates.each_cons(2).map { |a, b| (b - a).to_i }
        avg_gap = gaps.sum.to_f / [gaps.count, 1].max

        # Determine frequency
        frequency = if avg_gap.between?(5, 10)
          "weekly"
        elsif avg_gap.between?(25, 35)
          "monthly"
        elsif avg_gap.between?(340, 390)
          "annual"
        else
          next
        end

        monthly_cost = case frequency
        when "weekly" then amounts.last * 4.33
        when "monthly" then amounts.last
        when "annual" then amounts.last / 12.0
        end

        annual_cost = monthly_cost * 12

        # Price history and increase detection
        price_history = sorted.map { |t| { date: t[:date], amount: t[:amount] } }
        first_avg = amounts.first([3, amounts.count].min).sum / [amounts.first([3, amounts.count].min).count, 1].max.to_f
        last_avg = amounts.last([3, amounts.count].min).sum / [amounts.last([3, amounts.count].min).count, 1].max.to_f
        price_change = last_avg - first_avg
        price_change_pct = first_avg > 0 ? ((price_change / first_avg) * 100).round(1) : 0
        has_increased = price_change > 0.50

        # Next expected date
        last_date = dates.last
        next_expected = case frequency
        when "weekly" then last_date + 7
        when "monthly" then last_date >> 1
        when "annual" then last_date >> 12
        end

        # "Worth it" score: proxy based on frequency of charges and category diversity
        merchant_categories = categories.uniq.count
        charge_frequency_score = [txns.count * 10, 50].min
        recency_score = (Date.current - last_date).to_i < 45 ? 30 : 10
        category_bonus = merchant_categories > 1 ? 20 : 0
        worth_score = [charge_frequency_score + recency_score + category_bonus, 100].min

        primary_category = categories.group_by(&:itself).max_by { |_, v| v.count }&.first || "Other"

        status = if (Date.current - last_date).to_i > (avg_gap * 2)
          "possibly_cancelled"
        elsif next_expected && next_expected < Date.current
          "overdue"
        else
          "active"
        end

        @subscriptions << {
          name: merchant,
          monthly_cost: monthly_cost.round(2),
          annual_cost: annual_cost.round(2),
          frequency: frequency,
          category: primary_category,
          last_charge: last_date,
          next_expected: next_expected,
          price_history: price_history,
          price_change: price_change.round(2),
          price_change_pct: price_change_pct,
          has_increased: has_increased,
          worth_score: worth_score,
          charge_count: txns.count,
          first_seen: dates.first,
          status: status,
          last_amount: amounts.last.round(2)
        }
      end

      @subscriptions.sort_by! { |s| -s[:monthly_cost] }

      # Active subscriptions only
      @active_subscriptions = @subscriptions.select { |s| s[:status] == "active" }

      # Totals
      @total_monthly = @active_subscriptions.sum { |s| s[:monthly_cost] }
      @total_annual = @total_monthly * 12
      @daily_cost = (@total_monthly / 30.0).round(2)

      # Income calculation
      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end
      @avg_monthly_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      @income_pct = @avg_monthly_income > 0 ? ((@total_monthly / @avg_monthly_income) * 100).round(1) : 0

      # Bottom 3 by worth_score for savings opportunity
      @cut_candidates = @active_subscriptions.sort_by { |s| s[:worth_score] }.first([3, @active_subscriptions.count].min)
      @projected_savings = @cut_candidates.sum { |s| s[:annual_cost] }.round(2)

      # Price increase alerts
      @price_increases = @subscriptions.select { |s| s[:has_increased] }.sort_by { |s| -s[:price_change] }

      # Group by category
      @by_category = {}
      @active_subscriptions.each do |s|
        cat = s[:category]
        @by_category[cat] ||= { count: 0, monthly: 0 }
        @by_category[cat][:count] += 1
        @by_category[cat][:monthly] += s[:monthly_cost]
      end
      @by_category = @by_category.sort_by { |_, v| -v[:monthly] }.to_h

      # Cost timeline: monthly subscription cost over time
      @cost_timeline = []
      if @subscriptions.any?
        earliest = @subscriptions.map { |s| s[:first_seen] }.compact.min
        if earliest
          current_month = earliest
          while current_month <= Date.current
            month_str = current_month.strftime("%Y-%m")
            active_at_time = @subscriptions.select { |s|
              s[:first_seen] <= current_month &&
                (s[:status] == "active" || s[:last_charge] >= current_month)
            }
            monthly_total = active_at_time.sum { |s| s[:monthly_cost] }
            @cost_timeline << { month: month_str, label: current_month.strftime("%b %y"), total: monthly_total.round(2) }
            current_month = current_month >> 1
          end
        end
      end
    end

    def savings_challenges
      # Fetch data defensively
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 500) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }

      transactions = threads[:transactions].value || []
      funds = threads[:funds].value || []
      goals = threads[:goals].value || []

      # Separate by type
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }

      # Discretionary categories (non-essential)
      essential_keywords = %w[housing rent mortgage utilities insurance groceries transportation healthcare debt]
      discretionary = expenses.reject { |t|
        cat = (t["category"] || t["budget_category"] || "").downcase
        essential_keywords.any? { |k| cat.include?(k) }
      }

      # Monthly income and expenses
      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      # --- 52-Week Challenge ---
      current_week = Date.current.cweek
      week_52_target = (1..52).sum # 1378
      savings_fund_contributions = funds.sum { |f| f["current_amount"].to_f }
      week_52_expected = (1..current_week).sum
      week_52_progress = [savings_fund_contributions, week_52_expected].min
      week_52_pct = week_52_target > 0 ? (week_52_progress / week_52_target.to_f * 100).round(1) : 0

      # --- No-Spend Challenge ---
      today = Date.current
      sorted_expenses = discretionary.map { |t|
        date = t["transaction_date"]&.to_s&.to_date rescue nil
        date
      }.compact.sort.reverse

      current_streak = 0
      check_date = today
      expense_dates = sorted_expenses.uniq
      while check_date >= (today - 365)
        if expense_dates.include?(check_date)
          break
        else
          current_streak += 1
        end
        check_date -= 1
      end

      # Best streak: longest gap between consecutive expense dates
      best_streak = current_streak
      if expense_dates.length > 1
        sorted_dates = expense_dates.sort
        sorted_dates.each_cons(2) do |a, b|
          gap = (b - a).to_i - 1
          best_streak = gap if gap > best_streak
        end
      end

      # --- Round-Up Challenge ---
      round_up_total = expenses.sum { |t|
        amt = t["amount"].to_f
        cents = amt - amt.floor
        cents > 0 ? (1.0 - cents).round(2) : 0
      }
      days_span = if expenses.any?
        dates = expenses.map { |t| t["transaction_date"]&.to_s&.to_date rescue nil }.compact
        dates.any? ? [(today - dates.min).to_i, 1].max : 30
      else
        30
      end
      round_up_daily = days_span > 0 ? round_up_total / days_span : 0
      round_up_annual = (round_up_daily * 365).round(2)

      # --- Latte Factor ---
      small_purchases = expenses.select { |t| t["amount"].to_f > 0 && t["amount"].to_f < 10 }
      latte_total = small_purchases.sum { |t| t["amount"].to_f }
      latte_daily = days_span > 0 ? (latte_total / days_span).round(2) : 0
      latte_monthly = (latte_daily * 30).round(2)
      latte_annual = (latte_daily * 365).round(2)

      # Group latte purchases by merchant
      @latte_by_merchant = {}
      small_purchases.each do |t|
        merchant = t["merchant"] || t["description"] || "Unknown"
        @latte_by_merchant[merchant] ||= { count: 0, total: 0 }
        @latte_by_merchant[merchant][:count] += 1
        @latte_by_merchant[merchant][:total] += t["amount"].to_f
      end
      @latte_by_merchant = @latte_by_merchant.sort_by { |_, v| -v[:total] }.first(10).to_h

      # --- Pantry Challenge ---
      grocery_expenses = expenses.select { |t|
        cat = (t["category"] || t["budget_category"] || "").downcase
        cat.include?("grocer") || cat.include?("food") || cat.include?("supermarket")
      }
      weekly_grocery = {}
      grocery_expenses.each do |t|
        date = t["transaction_date"]&.to_s&.to_date rescue nil
        next unless date
        week_key = date.strftime("%Y-W%U")
        weekly_grocery[week_key] ||= 0
        weekly_grocery[week_key] += t["amount"].to_f
      end
      avg_grocery_week = weekly_grocery.values.any? ? (weekly_grocery.values.sum / weekly_grocery.count).round(2) : 0
      last_week_key = (today - 7).strftime("%Y-W%U")
      last_week_grocery = weekly_grocery[last_week_key] || 0
      pantry_savings = [avg_grocery_week - last_week_grocery, 0].max.round(2)
      pantry_reduction_weeks = weekly_grocery.count { |_, v| v < avg_grocery_week }

      # --- Cash Envelope ---
      discretionary_categories = {}
      discretionary.each do |t|
        cat = t["category"] || t["budget_category"] || "Other"
        discretionary_categories[cat] ||= 0
        discretionary_categories[cat] += t["amount"].to_f
      end
      months_count = [monthly_expenses.count, 1].max
      @envelope_suggestions = discretionary_categories.map { |cat, total|
        monthly_avg = (total / months_count).round(2)
        weekly_budget = (monthly_avg / 4.33).round(2)
        { category: cat, monthly: monthly_avg, weekly: weekly_budget }
      }.sort_by { |e| -e[:monthly] }.first(8)

      # --- Savings Rate Challenge ---
      monthly_rates = {}
      monthly_income.each do |month, inc|
        exp = monthly_expenses[month] || 0
        rate = inc > 0 ? ((inc - exp) / inc * 100).round(1) : 0
        monthly_rates[month] = rate
      end
      sorted_rate_months = monthly_rates.keys.sort
      @current_savings_rate = sorted_rate_months.any? ? monthly_rates[sorted_rate_months.last] : 0
      @savings_rate_trend = if sorted_rate_months.length >= 2
        monthly_rates[sorted_rate_months.last] - monthly_rates[sorted_rate_months[-2]]
      else
        0
      end
      @savings_rate_target = (@current_savings_rate + 1).round(1)
      @monthly_savings_rates = sorted_rate_months.last(6).map { |m| { month: m, rate: monthly_rates[m] } }

      # --- Debt Snowball Sprint ---
      debt_goals = goals.select { |g|
        name = (g["name"] || "").downcase
        name.include?("debt") || name.include?("loan") || name.include?("credit")
      }
      debt_funds = funds.select { |f|
        name = (f["name"] || "").downcase
        name.include?("debt") || name.include?("loan") || name.include?("payment")
      }
      has_debt = debt_goals.any? || debt_funds.any?
      smallest_debt = debt_goals.min_by { |g| g["target_amount"].to_f } if debt_goals.any?
      debt_progress = if smallest_debt
        paid = smallest_debt["effective_current_amount"].to_f || smallest_debt["current_amount"].to_f
        target = smallest_debt["target_amount"].to_f
        target > 0 ? (paid / target * 100).round(1) : 0
      else
        0
      end

      # --- Build Challenge Objects ---
      @challenges = []

      @challenges << {
        name: "52-Week Challenge",
        icon: "calendar_month",
        description: "Save $1 in week 1, $2 in week 2... $52 in week 52. Total: $1,378 per year.",
        current_progress: week_52_pct,
        target: week_52_target,
        current_amount: week_52_progress.round(2),
        savings_potential: week_52_target,
        status: week_52_pct >= 100 ? "completed" : (week_52_pct >= (current_week.to_f / 52 * 100 * 0.8) ? "on_track" : "behind"),
        color: "#4caf50"
      }

      @challenges << {
        name: "No-Spend Challenge",
        icon: "block",
        description: "How many consecutive days can you go without discretionary spending?",
        current_progress: [current_streak.to_f / 7 * 100, 100].min.round(1),
        target: 7,
        current_amount: current_streak,
        savings_potential: (latte_daily * 7).round(2),
        status: current_streak >= 7 ? "completed" : (current_streak >= 3 ? "on_track" : "starting"),
        color: "#e91e63",
        extra: { best_streak: best_streak }
      }

      @challenges << {
        name: "Round-Up Challenge",
        icon: "arrow_circle_up",
        description: "Round up every purchase to the nearest dollar and save the difference.",
        current_progress: round_up_total > 0 ? [round_up_total / [round_up_annual, 1].max * 100, 100].min.round(1) : 0,
        target: round_up_annual,
        current_amount: round_up_total.round(2),
        savings_potential: round_up_annual,
        status: round_up_annual > 100 ? "high_impact" : "moderate",
        color: "#2196f3"
      }

      @challenges << {
        name: "Latte Factor",
        icon: "local_cafe",
        description: "Small daily purchases under $10 that add up over time.",
        current_progress: latte_annual > 0 ? 100 : 0,
        target: latte_annual,
        current_amount: latte_total.round(2),
        savings_potential: latte_annual,
        status: latte_daily > 5 ? "high_impact" : (latte_daily > 2 ? "moderate" : "low"),
        color: "#795548",
        extra: { daily: latte_daily, monthly: latte_monthly, annual: latte_annual }
      }

      @challenges << {
        name: "Pantry Challenge",
        icon: "kitchen",
        description: "Use what you have! Reduce grocery spending by eating from your pantry.",
        current_progress: avg_grocery_week > 0 ? [(pantry_reduction_weeks.to_f / [weekly_grocery.count, 1].max * 100), 100].min.round(1) : 0,
        target: avg_grocery_week,
        current_amount: last_week_grocery.round(2),
        savings_potential: (pantry_savings * 52).round(2),
        status: last_week_grocery < avg_grocery_week ? "on_track" : "behind",
        color: "#ff9800",
        extra: { avg_weekly: avg_grocery_week, reduction_weeks: pantry_reduction_weeks, total_weeks: weekly_grocery.count }
      }

      @challenges << {
        name: "Cash Envelope",
        icon: "payments",
        description: "Set cash-based budgets for discretionary categories to control spending.",
        current_progress: @envelope_suggestions.any? ? 50 : 0,
        target: @envelope_suggestions.sum { |e| e[:monthly] }.round(2),
        current_amount: @envelope_suggestions.sum { |e| e[:monthly] }.round(2),
        savings_potential: (@envelope_suggestions.sum { |e| e[:monthly] } * 0.15 * 12).round(2),
        status: "active",
        color: "#9c27b0"
      }

      @challenges << {
        name: "Savings Rate Challenge",
        icon: "trending_up",
        description: "Increase your savings rate by 1% each month. Small steps, big results.",
        current_progress: [@current_savings_rate, 100].min.round(1),
        target: @savings_rate_target,
        current_amount: @current_savings_rate,
        savings_potential: if monthly_income.values.any?
          avg_inc = monthly_income.values.sum / [monthly_income.count, 1].max
          (avg_inc * 0.01 * 12).round(2)
        else
          0
        end,
        status: @savings_rate_trend > 0 ? "improving" : (@savings_rate_trend == 0 ? "flat" : "declining"),
        color: "#00bcd4",
        extra: { trend: @savings_rate_trend.round(1), history: @monthly_savings_rates }
      }

      @challenges << {
        name: "Debt Snowball Sprint",
        icon: "ac_unit",
        description: "Focus extra payments on your smallest debt first for quick wins.",
        current_progress: debt_progress,
        target: smallest_debt ? smallest_debt["target_amount"].to_f : 0,
        current_amount: smallest_debt ? (smallest_debt["effective_current_amount"].to_f || smallest_debt["current_amount"].to_f) : 0,
        savings_potential: 0,
        status: has_debt ? (debt_progress > 50 ? "on_track" : "active") : "no_debt",
        color: "#607d8b",
        extra: { has_debt: has_debt, smallest_debt_name: smallest_debt ? smallest_debt["name"] : nil }
      }

      # --- Gamification: Level & Badges ---
      active_count = @challenges.count { |c| %w[on_track active improving completed high_impact].include?(c[:status]) }
      total_potential = @challenges.sum { |c| c[:savings_potential].to_f }

      points = 0
      points += active_count * 15
      points += 20 if @current_savings_rate >= 20
      points += 10 if @current_savings_rate >= 10
      points += 15 if current_streak >= 3
      points += 25 if current_streak >= 7
      points += 10 if week_52_pct >= 50
      points += 20 if week_52_pct >= 100
      points += 10 if debt_progress >= 50
      points += 15 if @savings_rate_trend > 0

      @level = if points >= 120
        { name: "Money Master", rank: 3, icon: "workspace_premium", color: "#f9a825", min: 120, max: 200 }
      elsif points >= 60
        { name: "Super Saver", rank: 2, icon: "star", color: "#1a73e8", min: 60, max: 120 }
      else
        { name: "Saver", rank: 1, icon: "savings", color: "#4caf50", min: 0, max: 60 }
      end
      @level_progress = [((points - @level[:min]).to_f / (@level[:max] - @level[:min]) * 100).round(1), 100].min
      @points = points

      @badges = []
      @badges << { name: "First Steps", icon: "directions_walk", earned: active_count >= 1, description: "Start your first challenge" }
      @badges << { name: "Streak Master", icon: "local_fire_department", earned: current_streak >= 7, description: "7-day no-spend streak" }
      @badges << { name: "Half Way", icon: "flag", earned: week_52_pct >= 50, description: "52-Week Challenge at 50%" }
      @badges << { name: "Latte Aware", icon: "visibility", earned: @latte_by_merchant.any?, description: "Identify your latte factor" }
      @badges << { name: "Penny Pincher", icon: "toll", earned: round_up_annual > 50, description: "Round-up over $50/year" }
      @badges << { name: "Pantry Pro", icon: "food_bank", earned: pantry_reduction_weeks >= 2, description: "Beat grocery avg 2+ weeks" }
      @badges << { name: "Rate Climber", icon: "show_chart", earned: @savings_rate_trend > 0, description: "Increase savings rate month over month" }
      @badges << { name: "Debt Crusher", icon: "gavel", earned: debt_progress >= 50, description: "Pay off 50% of smallest debt" }
      @badges << { name: "Envelope Expert", icon: "inventory_2", earned: @envelope_suggestions.length >= 4, description: "Track 4+ envelope categories" }
      @badges << { name: "Money Master", icon: "workspace_premium", earned: points >= 120, description: "Reach Money Master level" }

      @active_challenges = active_count
      @total_potential_savings = total_potential
      @no_spend_streak = current_streak
      @round_up_projection = round_up_annual
      @latte_daily = latte_daily
      @latte_monthly = latte_monthly
      @latte_annual = latte_annual
    end

    def cash_flow_planner
      # Fetch transactions and recurring bills
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 1000) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        else
          Array(result)
        end
      }
      threads[:recurring] = Thread.new {
        result = budget_client.recurring rescue []
        if result.is_a?(Array)
          result
        elsif result.is_a?(Hash)
          result["items"] || result["recurring"] || result["recurring_transactions"] || []
        else
          []
        end
      }

      transactions = threads[:transactions].value || []
      recurring_items = threads[:recurring].value || []

      now = Date.current
      six_months_ago = (now << 6).beginning_of_month

      # Separate income vs expenses
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      # Filter to last 6 months
      recent_income = income_txns.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= six_months_ago && d <= now
      }
      recent_expenses = expense_txns.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= six_months_ago && d <= now
      }

      # Build months list (last 6 months)
      months_list = (0..5).map { |i| (now << i).strftime("%Y-%m") }.reverse

      # Monthly cash flow: income - expenses for each month
      monthly_income = {}
      monthly_expenses = {}
      months_list.each { |m| monthly_income[m] = 0; monthly_expenses[m] = 0 }

      recent_income.each do |t|
        month = t["transaction_date"].to_s.slice(0, 7) rescue nil
        next unless month && months_list.include?(month)
        monthly_income[month] += t["amount"].to_f.abs
      end

      recent_expenses.each do |t|
        month = t["transaction_date"].to_s.slice(0, 7) rescue nil
        next unless month && months_list.include?(month)
        monthly_expenses[month] += t["amount"].to_f.abs
      end

      @monthly_cash_flow = months_list.map { |m|
        {
          month: m,
          income: monthly_income[m],
          expenses: monthly_expenses[m],
          surplus: monthly_income[m] - monthly_expenses[m]
        }
      }

      # Average monthly surplus/deficit
      active_months = @monthly_cash_flow.select { |m| m[:income] > 0 || m[:expenses] > 0 }
      active_count = [active_months.size, 1].max
      total_surplus = active_months.sum { |m| m[:surplus] }
      @avg_monthly_surplus = total_surplus / active_count.to_f
      @avg_monthly_income = active_months.sum { |m| m[:income] } / active_count.to_f
      @avg_monthly_expenses = active_months.sum { |m| m[:expenses] } / active_count.to_f

      # Income timing: what day of month income typically arrives
      income_days = recent_income.map { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d&.day
      }.compact
      @income_day_counts = {}
      income_days.each { |d| @income_day_counts[d] = (@income_day_counts[d] || 0) + 1 }
      @typical_income_days = @income_day_counts.sort_by { |_, c| -c }.first(3).map { |d, c| { day: d, count: c } }
      @primary_income_day = @typical_income_days.first ? @typical_income_days.first[:day] : 1

      # Bill timing: when major bills are due (from recurring items)
      @bill_timing = recurring_items.map { |item|
        day = (item["day_of_month"] || item["due_day"] || item["next_due_date"]&.to_s&.slice(8, 2)).to_i rescue 0
        day = 1 if day <= 0 || day > 31
        {
          name: item["name"] || item["merchant"] || item["description"] || "Bill",
          amount: (item["amount"] || item["avg_amount"] || 0).to_f.abs,
          day: day,
          category: item["category"] || "Uncategorized"
        }
      }.select { |b| b[:amount] > 0 }.sort_by { |b| b[:day] }

      # Cash crunch detection: periods where bills cluster before income
      @cash_crunches = []
      if @typical_income_days.any? && @bill_timing.any?
        income_day = @primary_income_day
        # Group bills by week-of-month
        bills_before_income = @bill_timing.select { |b| b[:day] < income_day }
        bills_total_before = bills_before_income.sum { |b| b[:amount] }
        if bills_before_income.size >= 2 && bills_total_before > @avg_monthly_income * 0.2
          @cash_crunches << {
            period: "Days 1-#{income_day - 1}",
            description: "#{bills_before_income.size} bills totaling #{number_to_currency(bills_total_before)} due before income arrives on day #{income_day}",
            severity: bills_total_before > @avg_monthly_income * 0.4 ? "high" : "medium",
            bills: bills_before_income.first(5),
            total: bills_total_before
          }
        end

        # Detect clusters of 3+ bills within 5 days
        @bill_timing.each_with_index do |bill, i|
          cluster = @bill_timing.select { |b| (b[:day] - bill[:day]).abs <= 2 }
          if cluster.size >= 3
            cluster_total = cluster.sum { |b| b[:amount] }
            already_reported = @cash_crunches.any? { |c| c[:period].include?(bill[:day].to_s) }
            unless already_reported
              @cash_crunches << {
                period: "Days #{[bill[:day] - 2, 1].max}-#{[bill[:day] + 2, 28].min}",
                description: "#{cluster.size} bills clustered around day #{bill[:day]} totaling #{number_to_currency(cluster_total)}",
                severity: cluster_total > @avg_monthly_income * 0.3 ? "high" : "medium",
                bills: cluster.first(5),
                total: cluster_total
              }
            end
          end
        end
        @cash_crunches = @cash_crunches.uniq { |c| c[:period] }.first(4)
      end

      # Float days: days between income and next major expense where cash is highest
      if @primary_income_day > 0 && @bill_timing.any?
        next_bill_after_income = @bill_timing.select { |b| b[:day] > @primary_income_day }.first
        if next_bill_after_income
          @float_days = next_bill_after_income[:day] - @primary_income_day
        else
          # Bills are all before income day, so float lasts rest of month
          first_bill_next_month = @bill_timing.first
          @float_days = first_bill_next_month ? (30 - @primary_income_day + first_bill_next_month[:day]) : 0
        end
      else
        @float_days = 0
      end
      @float_days = @float_days.clamp(0, 30)

      # Runway calculation: at current burn rate, how many months of savings
      # Estimate savings as difference between total income and expenses over the period
      total_income_period = monthly_income.values.sum
      total_expenses_period = monthly_expenses.values.sum
      total_saved = [total_income_period - total_expenses_period, 0].max
      monthly_burn = @avg_monthly_expenses
      @runway_months = monthly_burn > 0 ? (total_saved / monthly_burn).round(1) : 0

      # Seasonal cash flow: identify months that are tight vs flush
      month_names = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
      @seasonal_data = months_list.map { |m|
        month_num = m.split("-").last.to_i
        surplus = monthly_income[m] - monthly_expenses[m]
        {
          month: m,
          month_name: month_names[month_num - 1] || m,
          income: monthly_income[m],
          expenses: monthly_expenses[m],
          surplus: surplus,
          status: surplus > @avg_monthly_surplus * 1.2 ? "flush" : (surplus < @avg_monthly_surplus * 0.5 ? "tight" : "normal")
        }
      }

      # Cash flow forecast: next 3 months
      # Use weighted average with trend
      weights = [1, 1, 1, 2, 2, 3]
      income_values = months_list.map { |m| monthly_income[m] }
      expense_values = months_list.map { |m| monthly_expenses[m] }

      weighted_income = income_values.each_with_index.sum { |v, i| v * (weights[i] || 1) } / weights.sum.to_f
      weighted_expenses = expense_values.each_with_index.sum { |v, i| v * (weights[i] || 1) } / weights.sum.to_f

      # Detect trend direction
      recent_3_income = income_values.last(3)
      prior_3_income = income_values.first(3)
      income_trend = (recent_3_income.sum - prior_3_income.sum) / [prior_3_income.sum, 1].max.to_f

      recent_3_expenses = expense_values.last(3)
      prior_3_expenses = expense_values.first(3)
      expense_trend = (recent_3_expenses.sum - prior_3_expenses.sum) / [prior_3_expenses.sum, 1].max.to_f

      # Add known recurring bills to forecast
      recurring_monthly_total = @bill_timing.sum { |b| b[:amount] }

      @forecast_months = (1..3).map { |i|
        future_date = now >> i
        month_str = future_date.strftime("%Y-%m")
        month_name = future_date.strftime("%B %Y")

        # Apply trend adjustment (capped at +/- 15%)
        income_adj = 1 + (income_trend * i * 0.05).clamp(-0.15, 0.15)
        expense_adj = 1 + (expense_trend * i * 0.05).clamp(-0.15, 0.15)

        proj_income = weighted_income * income_adj
        proj_expenses = [weighted_expenses * expense_adj, recurring_monthly_total].max

        {
          month: month_str,
          month_name: month_name,
          projected_income: proj_income.round(2),
          projected_expenses: proj_expenses.round(2),
          projected_surplus: (proj_income - proj_expenses).round(2)
        }
      }

      # Next cash crunch date
      @next_crunch = @cash_crunches.first
      @next_crunch_label = @next_crunch ? @next_crunch[:period] : "None"

      # Optimization tips
      @optimization_tips = []

      # Tip: shift bill due dates away from clusters
      if @cash_crunches.any?
        @optimization_tips << {
          icon: "event",
          title: "Redistribute Bill Due Dates",
          description: "You have bills clustering #{@cash_crunches.first[:period]}. Contact providers to shift due dates to after your income arrives (day #{@primary_income_day}).",
          impact: "Reduce cash crunch stress"
        }
      end

      # Tip: if float days are short
      if @float_days < 5
        @optimization_tips << {
          icon: "schedule",
          title: "Extend Your Float Period",
          description: "Only #{@float_days} days between income and first major bill. Try moving discretionary spending to right after payday.",
          impact: "More breathing room"
        }
      end

      # Tip: if surplus is negative
      if @avg_monthly_surplus < 0
        @optimization_tips << {
          icon: "warning",
          title: "Address Monthly Deficit",
          description: "You're spending #{number_to_currency(@avg_monthly_surplus.abs)} more than you earn monthly. Review discretionary categories for cuts.",
          impact: "Prevent debt accumulation"
        }
      end

      # Tip: if runway is low
      if @runway_months < 3
        @optimization_tips << {
          icon: "savings",
          title: "Build Emergency Buffer",
          description: "At your current rate, you have #{@runway_months} months of runway. Aim for at least 3 months of expenses saved.",
          impact: "Financial security"
        }
      end

      # Tip: time large purchases
      if @float_days > 0
        @optimization_tips << {
          icon: "shopping_cart",
          title: "Time Large Purchases",
          description: "Schedule big purchases for days #{@primary_income_day}-#{@primary_income_day + @float_days} when your cash balance is highest.",
          impact: "Avoid overdrafts"
        }
      end

      # Tip: if seasonal variation is high
      flush_months = @seasonal_data.count { |s| s[:status] == "flush" }
      tight_months = @seasonal_data.count { |s| s[:status] == "tight" }
      if tight_months > 0 && flush_months > 0
        tight_names = @seasonal_data.select { |s| s[:status] == "tight" }.map { |s| s[:month_name] }.join(", ")
        @optimization_tips << {
          icon: "ac_unit",
          title: "Plan for Tight Months",
          description: "#{tight_names} tend to be tight. Set aside extra during flush months to cover lean periods.",
          impact: "Smooth cash flow"
        }
      end

      # Ensure at least one tip
      if @optimization_tips.empty?
        @optimization_tips << {
          icon: "check_circle",
          title: "Cash Flow Looks Healthy",
          description: "Your income and expenses are well-balanced. Keep monitoring for changes in recurring bills.",
          impact: "Stay on track"
        }
      end
    end

    def spending_personality
      # Fetch transactions defensively
      begin
        result = budget_client.transactions(per_page: 1000)
        all_transactions = if result.is_a?(Hash)
                             result["transactions"] || []
                           else
                             Array(result)
                           end
      rescue => e
        Rails.logger.error("SpendingPersonality: failed to fetch transactions: #{e.message}")
        all_transactions = []
      end

      # Separate by type
      expenses = all_transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = all_transactions.select { |t| t["transaction_type"] == "income" }

      total_income = income_txns.sum { |t| t["amount"].to_f }
      total_expenses = expenses.sum { |t| t["amount"].to_f }

      # ---- Dimension 1: Needs vs Wants vs Savings ratio ----
      needs_keywords = %w[housing rent mortgage utilities insurance groceries transportation healthcare debt loan]
      wants_keywords = %w[restaurant dining entertainment shopping clothing subscription streaming travel hobby gift]

      needs_total = 0.0
      wants_total = 0.0
      savings_total = 0.0

      expenses.each do |t|
        cat = (t["category"] || t["budget_category"] || t["merchant"] || "").downcase
        if needs_keywords.any? { |kw| cat.include?(kw) }
          needs_total += t["amount"].to_f
        elsif wants_keywords.any? { |kw| cat.include?(kw) }
          wants_total += t["amount"].to_f
        end
      end

      other_total = total_expenses - needs_total - wants_total
      wants_total += other_total * 0.5
      needs_total += other_total * 0.5

      savings_total = [total_income - total_expenses, 0].max

      grand_total = needs_total + wants_total + savings_total
      grand_total = 1.0 if grand_total <= 0

      needs_pct = (needs_total / grand_total * 100).round(1)
      wants_pct = (wants_total / grand_total * 100).round(1)
      savings_pct = (savings_total / grand_total * 100).round(1)

      # Needs/wants score: lower wants = higher planning score
      planning_score = [(100 - wants_pct * 1.5).round, 0].max.clamp(0, 100)

      # ---- Dimension 2: Impulse Score ----
      small_threshold = 20.0
      small_purchases = expenses.select { |t| t["amount"].to_f > 0 && t["amount"].to_f <= small_threshold }
      small_ratio = expenses.any? ? (small_purchases.size.to_f / expenses.size * 100) : 0

      weekend_txns = 0
      weekday_txns = 0
      expenses.each do |t|
        date = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
        next unless date
        if date.saturday? || date.sunday?
          weekend_txns += 1
        else
          weekday_txns += 1
        end
      end
      total_day_txns = weekend_txns + weekday_txns
      weekend_ratio = total_day_txns > 0 ? (weekend_txns.to_f / total_day_txns * 100) : 28.6  # baseline 2/7

      # Higher impulse = more small purchases + weekend-heavy
      impulse_raw = (small_ratio * 0.6 + [weekend_ratio - 28.6, 0].max * 2.0).round
      impulse_score = impulse_raw.clamp(0, 100)

      # ---- Dimension 3: Consistency Score ----
      monthly_totals = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_totals[month] ||= 0.0
        monthly_totals[month] += t["amount"].to_f
      end

      if monthly_totals.size >= 2
        values = monthly_totals.values
        mean = values.sum / values.size
        variance = values.sum { |v| (v - mean) ** 2 } / values.size
        std_dev = Math.sqrt(variance)
        cv = mean > 0 ? (std_dev / mean) : 0
        consistency_score = [(100 - cv * 200).round, 0].max.clamp(0, 100)
      else
        consistency_score = 50
      end

      # ---- Dimension 4: Frugality Index ----
      avg_txn_size = expenses.any? ? (total_expenses / expenses.size) : 0
      savings_rate = total_income > 0 ? (savings_total / total_income * 100) : 0

      # Higher savings rate + lower avg transaction = more frugal
      frugality_score = [
        (savings_rate * 2.0) + [50 - avg_txn_size, 0].max * 0.5,
        100
      ].min.round.clamp(0, 100)

      # ---- Dimension 5: Category Diversity ----
      categories_used = expenses.map { |t|
        (t["category"] || t["budget_category"] || "uncategorized").downcase
      }.uniq
      cat_count = categories_used.size
      # Normalize: 1 category = 0, 15+ categories = 100
      diversity_score = [(cat_count.to_f / 15 * 100).round, 100].min.clamp(0, 100)

      # ---- Dimension 6: Time Patterns ----
      morning_count = 0
      evening_count = 0
      expenses.each do |t|
        time_str = t["created_at"] || t["transaction_date"]
        next unless time_str.to_s.include?("T") || time_str.to_s.include?(" ")
        begin
          hour = Time.parse(time_str.to_s).hour
          if hour < 12
            morning_count += 1
          else
            evening_count += 1
          end
        rescue
          next
        end
      end

      time_total = morning_count + evening_count
      morning_pct = time_total > 0 ? (morning_count.to_f / time_total * 100).round : 50
      # Time pattern score: higher = more morning/planned spending
      time_score = morning_pct.clamp(0, 100)

      # ---- Build dimensions hash ----
      @dimensions = {
        planning: { label: "Planning", score: planning_score, icon: "event_note", description: "How well spending aligns with needs vs wants" },
        impulse_control: { label: "Impulse Control", score: [(100 - impulse_score), 0].max, icon: "speed", description: "Resistance to small unplanned purchases" },
        consistency: { label: "Consistency", score: consistency_score, icon: "straighten", description: "How stable your monthly spending is" },
        frugality: { label: "Frugality", score: frugality_score, icon: "savings", description: "Savings rate and average spending efficiency" },
        diversity: { label: "Diversity", score: diversity_score, icon: "category", description: "Range of spending categories" },
        time_discipline: { label: "Time Discipline", score: time_score, icon: "schedule", description: "Morning (planned) vs evening (reactive) spending" }
      }

      # ---- Determine personality type ----
      scores = {
        planning: planning_score,
        impulse_control: (100 - impulse_score),
        consistency: consistency_score,
        frugality: frugality_score,
        diversity: diversity_score,
        time_discipline: time_score
      }
      avg_score = scores.values.sum.to_f / scores.size

      # Personality matching
      personalities = {
        planner: {
          name: "The Planner",
          icon: "event_available",
          color: "#1976d2",
          description: "You're methodical and intentional with your money. Your spending is consistent, well-planned, and aligned with your priorities. You rarely make impulse purchases and prefer to map out expenses in advance.",
          strengths: ["Highly consistent spending patterns", "Strong impulse control", "Excellent budget adherence", "Long-term financial vision"],
          growth_areas: ["May be overly rigid with budgets", "Could miss opportunities for enjoyable spontaneous purchases", "Risk of analysis paralysis on spending decisions"],
          tips: ["Allow a small 'fun money' budget for spontaneous treats", "Review your plan quarterly to ensure it still fits your life", "Celebrate your discipline -- it's a rare strength", "Consider automating more to free up mental energy"]
        },
        optimizer: {
          name: "The Optimizer",
          icon: "tune",
          color: "#00897b",
          description: "You're always looking for the best deal and maximum value. Your spending varies as you hunt for opportunities, compare prices, and optimize every dollar. You treat budgeting like a game to win.",
          strengths: ["Great at finding deals and value", "Flexible spending approach", "High awareness of price differences", "Strong research habits before purchasing"],
          growth_areas: ["Variable spending can make budgeting harder", "Time spent optimizing may not always be worth it", "May delay necessary purchases waiting for deals"],
          tips: ["Set a time limit for deal-hunting to avoid diminishing returns", "Use price tracking tools to automate deal finding", "Focus optimization energy on big-ticket items first", "Track your actual savings from deal-hunting to stay motivated"]
        },
        comfort_spender: {
          name: "The Comfort Spender",
          icon: "spa",
          color: "#8e24aa",
          description: "You value quality of life and don't mind spending on things that bring comfort and joy. Your wants ratio is higher, but your patterns are consistent -- you know what you like and budget for it.",
          strengths: ["Good quality of life", "Consistent and predictable spending", "Self-aware about spending preferences", "Likely to maintain spending habits long-term"],
          growth_areas: ["Higher wants-to-needs ratio", "Savings rate could be improved", "Lifestyle inflation risk as income grows"],
          tips: ["Identify your top 3 'joy purchases' and protect those in your budget", "Find one wants category to reduce by 20%", "Set up automatic savings before spending on wants", "Try a 'swap' approach: upgrade one area while downgrading another"]
        },
        minimalist: {
          name: "The Minimalist",
          icon: "eco",
          color: "#2e7d32",
          description: "Less is more for you. You spend in few categories, keep transactions small, and prioritize saving over spending. You find satisfaction in simplicity and financial security.",
          strengths: ["High savings rate", "Low financial stress", "Minimal lifestyle inflation", "Strong financial safety net"],
          growth_areas: ["May under-invest in experiences and personal growth", "Few spending categories could mean missing out", "Risk of becoming too restrictive with money"],
          tips: ["Allocate a small 'experience' fund for trying new things", "Review if any underspending is actually causing problems", "Consider investing your strong savings more aggressively", "Allow yourself one new spending category per quarter to explore"]
        },
        social_spender: {
          name: "The Social Spender",
          icon: "groups",
          color: "#e65100",
          description: "Your money flows toward shared experiences -- dining out, entertainment, and social activities. You value relationships and experiences over material things, with spending peaking on weekends.",
          strengths: ["Rich social life and experiences", "Strong relationships through shared activities", "Memory-creating spending over material accumulation", "Good work-life balance indicators"],
          growth_areas: ["Weekend spending can spiral", "Social pressure may increase spending", "Restaurant and entertainment costs add up quickly"],
          tips: ["Host more gatherings at home to cut dining costs", "Suggest free or low-cost social activities regularly", "Set a weekly 'social budget' and track it", "Use happy hours and early-bird specials strategically"]
        },
        balanced: {
          name: "The Balanced",
          icon: "balance",
          color: "#546e7a",
          description: "You maintain a healthy equilibrium across all spending dimensions. You're neither too restrictive nor too indulgent, with moderate scores across planning, saving, and spending categories.",
          strengths: ["Well-rounded financial habits", "Sustainable spending patterns", "Adaptable to changing circumstances", "Good foundation for any financial goal"],
          growth_areas: ["Jack of all trades, master of none", "Could benefit from strengthening one specific area", "May lack a clear financial identity or strategy"],
          tips: ["Pick one dimension to excel in this quarter", "Set one ambitious financial goal to stretch yourself", "Your balance is an asset -- use it to weather financial storms", "Consider increasing savings rate by just 5% for outsized impact"]
        }
      }

      # Determine best-fit personality
      social_categories = %w[restaurant dining entertainment bar cafe coffee social event]
      social_spending = expenses.count { |t|
        cat = (t["category"] || t["budget_category"] || t["merchant"] || "").downcase
        social_categories.any? { |sc| cat.include?(sc) }
      }
      social_ratio = expenses.any? ? (social_spending.to_f / expenses.size * 100) : 0

      personality_key = if scores[:planning] >= 70 && scores[:impulse_control] >= 70 && scores[:consistency] >= 65
                          :planner
                        elsif scores[:frugality] >= 70 && scores[:diversity] <= 40
                          :minimalist
                        elsif social_ratio >= 30 && weekend_ratio >= 35
                          :social_spender
                        elsif wants_pct >= 40 && scores[:consistency] >= 55
                          :comfort_spender
                        elsif scores[:diversity] >= 60 && consistency_score <= 50
                          :optimizer
                        else
                          :balanced
                        end

      @personality = personalities[personality_key]
      @personality_key = personality_key

      # ---- Evidence data ----
      @evidence = {
        total_transactions: all_transactions.size,
        expense_count: expenses.size,
        income_count: income_txns.size,
        total_income: total_income,
        total_expenses: total_expenses,
        savings_total: savings_total,
        savings_rate: savings_rate.round(1),
        needs_pct: needs_pct,
        wants_pct: wants_pct,
        savings_pct: savings_pct,
        avg_transaction: avg_txn_size.round(2),
        categories_used: cat_count,
        category_names: categories_used.sort,
        weekend_ratio: weekend_ratio.round(1),
        small_purchase_ratio: small_ratio.round(1),
        monthly_totals: monthly_totals,
        morning_pct: morning_pct,
        months_analyzed: monthly_totals.size
      }
    end

    def year_in_review
      @year = (params[:year] || Date.current.year).to_i
      year_start = Date.new(@year, 1, 1)
      year_end = Date.new(@year, 12, 31)
      prev_year_start = Date.new(@year - 1, 1, 1)
      prev_year_end = Date.new(@year - 1, 12, 31)

      # Fetch current year and prior year transactions in parallel
      threads = {}
      threads[:current] = Thread.new {
        result = budget_client.transactions(
          start_date: year_start.to_s,
          end_date: year_end.to_s,
          per_page: 2000
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:prior] = Thread.new {
        result = budget_client.transactions(
          start_date: prev_year_start.to_s,
          end_date: prev_year_end.to_s,
          per_page: 2000
        ) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }

      transactions = threads[:current].value rescue []
      prior_transactions = threads[:prior].value rescue []

      # Separate income and expenses
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      # --- Annual totals ---
      @total_income = income_txns.sum { |t| t["amount"].to_f }
      @total_spending = expense_txns.sum { |t| t["amount"].to_f }
      @total_saved = @total_income - @total_spending
      @savings_rate = @total_income > 0 ? (@total_saved / @total_income * 100).round(1) : 0

      # --- Monthly breakdown ---
      @monthly_data = (1..12).map do |m|
        month_key = "#{@year}-#{m.to_s.rjust(2, '0')}"
        m_income = income_txns.select { |t| t["transaction_date"]&.to_s&.start_with?(month_key) }.sum { |t| t["amount"].to_f }
        m_expense = expense_txns.select { |t| t["transaction_date"]&.to_s&.start_with?(month_key) }.sum { |t| t["amount"].to_f }
        m_saved = m_income - m_expense
        m_rate = m_income > 0 ? (m_saved / m_income * 100).round(1) : 0
        { month: m, name: Date::ABBR_MONTHNAMES[m], income: m_income.round(2), expenses: m_expense.round(2), saved: m_saved.round(2), savings_rate: m_rate }
      end

      # --- Top spending categories ---
      category_totals = Hash.new(0)
      expense_txns.each do |t|
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        category_totals[cat] += t["amount"].to_f
      end
      @top_categories = category_totals.sort_by { |_, v| -v }.first(10).map do |cat, total|
        pct = @total_spending > 0 ? (total / @total_spending * 100).round(1) : 0
        { name: cat, total: total.round(2), pct: pct }
      end

      # --- Top merchants ---
      merchant_totals = Hash.new(0)
      expense_txns.each do |t|
        merchant = t["merchant"] || t["description"] || "Unknown"
        merchant_totals[merchant] += t["amount"].to_f
      end
      @top_merchants = merchant_totals.sort_by { |_, v| -v }.first(10).map do |merchant, total|
        { name: merchant, total: total.round(2) }
      end

      # --- Biggest single expense ---
      @biggest_expense = expense_txns.max_by { |t| t["amount"].to_f } || {}

      # --- Highest and lowest spending months ---
      months_with_data = @monthly_data.select { |m| m[:expenses] > 0 }
      @highest_month = months_with_data.max_by { |m| m[:expenses] } || @monthly_data.first
      @lowest_month = months_with_data.min_by { |m| m[:expenses] } || @monthly_data.first

      # --- Year-over-year comparison ---
      prior_income = prior_transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
      prior_spending = prior_transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
      @has_prior_year = prior_transactions.any?
      @prior_year_income = prior_income
      @prior_year_spending = prior_spending
      @prior_year_saved = prior_income - prior_spending
      @income_change_pct = prior_income > 0 ? ((@total_income - prior_income) / prior_income * 100).round(1) : 0
      @spending_change_pct = prior_spending > 0 ? ((@total_spending - prior_spending) / prior_spending * 100).round(1) : 0

      # --- Spending trends (category comparison vs prior year) ---
      prior_cat_totals = Hash.new(0)
      prior_transactions.select { |t| t["transaction_type"] != "income" }.each do |t|
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        prior_cat_totals[cat] += t["amount"].to_f
      end
      all_cats = (category_totals.keys + prior_cat_totals.keys).uniq
      @spending_trends = all_cats.map do |cat|
        curr = category_totals[cat]
        prev = prior_cat_totals[cat]
        change = prev > 0 ? ((curr - prev) / prev * 100).round(1) : (curr > 0 ? 100.0 : 0)
        { name: cat, current: curr.round(2), previous: prev.round(2), change_pct: change }
      end.sort_by { |t| -t[:change_pct].abs }.first(10)

      # --- Achievement highlights ---
      @achievements = []
      @achievements << "Saved #{number_to_currency(@total_saved)} this year!" if @total_saved > 0
      @achievements << "Savings rate of #{@savings_rate}% - above 20% target!" if @savings_rate >= 20
      @achievements << "Savings rate improved vs last year!" if @has_prior_year && @savings_rate > (@prior_year_saved > 0 && prior_income > 0 ? (@prior_year_saved / prior_income * 100) : 0)
      @achievements << "Reduced spending by #{@spending_change_pct.abs}% vs last year!" if @has_prior_year && @spending_change_pct < 0
      @achievements << "Income grew #{@income_change_pct}% vs last year!" if @has_prior_year && @income_change_pct > 0
      zero_spend_days = (year_start..[year_end, Date.current].min).count { |d| !expense_txns.any? { |t| t["transaction_date"]&.to_s&.start_with?(d.to_s) } }
      @achievements << "#{zero_spend_days} no-spend days!" if zero_spend_days >= 30

      # --- Seasonal patterns ---
      @seasonal = {
        q1: @monthly_data[0..2].sum { |m| m[:expenses] }.round(2),
        q2: @monthly_data[3..5].sum { |m| m[:expenses] }.round(2),
        q3: @monthly_data[6..8].sum { |m| m[:expenses] }.round(2),
        q4: @monthly_data[9..11].sum { |m| m[:expenses] }.round(2)
      }
      holiday_months = [11, 12].map { |m| @monthly_data[m - 1][:expenses] }.sum
      non_holiday_avg = @monthly_data.reject { |m| [11, 12].include?(m[:month]) }.sum { |m| m[:expenses] } / 10.0
      @holiday_spike_pct = non_holiday_avg > 0 ? ((holiday_months / 2.0 - non_holiday_avg) / non_holiday_avg * 100).round(1) : 0

      # --- Fun stats ---
      days_in_year = (@year == Date.current.year ? (Date.current - year_start).to_i + 1 : 365).clamp(1, 366)
      @avg_daily_spend = (@total_spending / days_in_year).round(2)
      @transactions_per_day = (expense_txns.count.to_f / days_in_year).round(1)
      @total_transactions = transactions.count

      # Most expensive day of week
      dow_totals = Array.new(7, 0)
      dow_counts = Array.new(7, 0)
      expense_txns.each do |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        next unless d
        dow_totals[d.wday] += t["amount"].to_f
        dow_counts[d.wday] += 1
      end
      dow_avgs = dow_totals.each_with_index.map { |total, i| { day: Date::DAYNAMES[i], avg: dow_counts[i] > 0 ? (total / dow_counts[i]).round(2) : 0 } }
      @most_expensive_dow = dow_avgs.max_by { |d| d[:avg] } || { day: "N/A", avg: 0 }

      # Available years for selector
      all_dates = transactions.map { |t| t["transaction_date"]&.to_s&.slice(0, 4) }.compact.uniq
      prior_dates = prior_transactions.map { |t| t["transaction_date"]&.to_s&.slice(0, 4) }.compact.uniq
      @available_years = ((all_dates + prior_dates).uniq.map(&:to_i) + [@year, @year - 1]).uniq.sort.reverse
    end

    def debt_visualizer
      raw = budget_client.debt_accounts rescue []
      accounts = if raw.is_a?(Array)
        raw
      elsif raw.is_a?(Hash)
        raw["debt_accounts"] || raw["debts"] || raw["accounts"] || []
      else
        []
      end
      @debts = Array(accounts).select { |d| d.is_a?(Hash) && d["current_balance"].to_f > 0 }

      @total_debt = @debts.sum { |d| d["current_balance"].to_f }
      @total_minimum = @debts.sum { |d| d["minimum_payment"].to_f }
      @weighted_avg_rate = if @total_debt > 0
        @debts.sum { |d| d["interest_rate"].to_f * d["current_balance"].to_f } / @total_debt
      else
        0
      end.round(2)

      # Per-debt analysis
      @extra_amounts = [50, 100, 200]
      @debt_details = @debts.map do |d|
        balance = d["current_balance"].to_f
        rate = d["interest_rate"].to_f
        min_pay = d["minimum_payment"].to_f
        name = d["name"] || "Unknown"
        debt_type = d["debt_type"]&.titleize || "Other"

        base_months = compute_single_payoff_months(balance, rate, min_pay)
        base_interest = compute_single_total_interest(balance, rate, min_pay)
        base_date = Date.current >> base_months

        scenarios = @extra_amounts.map do |extra|
          accel_months = compute_single_payoff_months(balance, rate, min_pay + extra)
          accel_interest = compute_single_total_interest(balance, rate, min_pay + extra)
          {
            extra: extra,
            months: accel_months,
            interest: accel_interest,
            interest_saved: base_interest - accel_interest,
            months_saved: base_months - accel_months,
            payoff_date: Date.current >> accel_months
          }
        end

        {
          name: name,
          debt_type: debt_type,
          balance: balance,
          rate: rate,
          min_payment: min_pay,
          base_months: base_months,
          base_interest: base_interest,
          base_date: base_date,
          scenarios: scenarios
        }
      end

      # Snowball order: smallest balance first
      @snowball_order = @debt_details.sort_by { |d| d[:balance] }
      # Avalanche order: highest rate first
      @avalanche_order = @debt_details.sort_by { |d| -d[:rate] }

      # Simulate snowball method
      snowball_result = simulate_strategy(@debts.sort_by { |d| d["current_balance"].to_f }, @total_minimum)
      @snowball_months = snowball_result[:months]
      @snowball_interest = snowball_result[:total_interest]
      @snowball_milestones = snowball_result[:milestones]

      # Simulate avalanche method
      avalanche_result = simulate_strategy(@debts.sort_by { |d| -d["interest_rate"].to_f }, @total_minimum)
      @avalanche_months = avalanche_result[:months]
      @avalanche_interest = avalanche_result[:total_interest]
      @avalanche_milestones = avalanche_result[:milestones]

      # Aggregate acceleration scenarios
      @aggregate_scenarios = @extra_amounts.map do |extra|
        months = estimate_payoff_months(@debts, @total_minimum + extra)
        interest = estimate_total_interest(@debts, @total_minimum + extra)
        base_months = estimate_payoff_months(@debts, @total_minimum)
        base_interest = estimate_total_interest(@debts, @total_minimum)
        {
          extra: extra,
          months: months,
          interest: interest,
          months_saved: base_months - months,
          interest_saved: base_interest - interest,
          payoff_date: Date.current >> months
        }
      end

      @base_months = estimate_payoff_months(@debts, @total_minimum)
      @base_interest = estimate_total_interest(@debts, @total_minimum)
      @base_payoff_date = Date.current >> @base_months

      # Payoff timeline data for SVG chart (balance over time for each debt)
      @timeline_data = build_payoff_timeline(@debts)

      # Debt colors for chart consistency
      @debt_colors = ["#e53935", "#1e88e5", "#43a047", "#fb8c00", "#8e24aa", "#00acc1", "#6d4c41", "#546e7a"]
    end

    def lifestyle_inflation
      result = budget_client.transactions(per_page: 2000) rescue nil
      all_transactions = if result.is_a?(Hash)
        result["transactions"] || []
      elsif result.is_a?(Array)
        result
      else
        []
      end

      expenses = all_transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = all_transactions.select { |t| t["transaction_type"] == "income" }

      # Group expenses by month
      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      # Group income by month
      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      sorted_months = monthly_expenses.keys.sort
      @monthly_data = sorted_months.map { |m|
        { month: m, expenses: monthly_expenses[m].round(2), income: (monthly_income[m] || 0).round(2) }
      }

      # Monthly spending trend percentage
      if @monthly_data.size >= 2
        first_half = @monthly_data[0...(@monthly_data.size / 2)]
        second_half = @monthly_data[(@monthly_data.size / 2)..]
        first_avg = first_half.any? ? first_half.sum { |d| d[:expenses] } / first_half.size : 0
        second_avg = second_half.any? ? second_half.sum { |d| d[:expenses] } / second_half.size : 0
        @spending_trend_pct = first_avg > 0 ? ((second_avg - first_avg) / first_avg * 100).round(1) : 0
      else
        @spending_trend_pct = 0
      end

      # Category creep: compare earlier half to recent half spending per category
      cat_by_month = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        next unless month
        cat_by_month[cat] ||= {}
        cat_by_month[cat][month] ||= 0
        cat_by_month[cat][month] += t["amount"].to_f
      end

      midpoint = sorted_months.size / 2
      early_months = sorted_months[0...midpoint]
      recent_months = sorted_months[midpoint..]
      early_months = early_months.presence || []
      recent_months = recent_months.presence || sorted_months

      @category_creep = []
      cat_by_month.each do |cat, month_data|
        early_vals = early_months.map { |m| month_data[m] || 0 }
        recent_vals = recent_months.map { |m| month_data[m] || 0 }
        early_avg = early_vals.any? ? early_vals.sum / early_vals.size : 0
        recent_avg = recent_vals.any? ? recent_vals.sum / recent_vals.size : 0
        next if early_avg < 5 && recent_avg < 5

        change_pct = early_avg > 0 ? ((recent_avg - early_avg) / early_avg * 100).round(1) : (recent_avg > 0 ? 100.0 : 0.0)
        @category_creep << {
          category: cat,
          early_avg: early_avg.round(2),
          recent_avg: recent_avg.round(2),
          change_pct: change_pct,
          direction: change_pct > 0 ? :up : (change_pct < 0 ? :down : :flat)
        }
      end
      @category_creep.sort_by! { |c| -c[:change_pct] }
      @categories_creeping_count = @category_creep.count { |c| c[:change_pct] > 20 }

      # Lifestyle score: overall spending increase as a percentage (inflation-adjusted)
      annual_inflation_rate = 3.0
      months_span = sorted_months.size
      inflation_factor = (1 + annual_inflation_rate / 100) ** (months_span / 12.0)
      raw_increase = @spending_trend_pct
      @lifestyle_score = (raw_increase - (inflation_factor - 1) * 100).round(1)
      @lifestyle_score = [@lifestyle_score, 0].max

      # Upgrade detection: categories where avg transaction size increased
      cat_txn_sizes = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        amount = t["amount"].to_f
        next unless month && amount > 0
        period = early_months.include?(month) ? :early : (recent_months.include?(month) ? :recent : nil)
        next unless period
        cat_txn_sizes[cat] ||= { early: [], recent: [] }
        cat_txn_sizes[cat][period] << amount
      end

      @upgrade_detection = []
      cat_txn_sizes.each do |cat, data|
        next if data[:early].size < 3 || data[:recent].size < 3
        early_avg_size = data[:early].sum / data[:early].size
        recent_avg_size = data[:recent].sum / data[:recent].size
        next if early_avg_size < 1
        increase_pct = ((recent_avg_size - early_avg_size) / early_avg_size * 100).round(1)
        next if increase_pct <= 5
        @upgrade_detection << {
          category: cat,
          early_avg_size: early_avg_size.round(2),
          recent_avg_size: recent_avg_size.round(2),
          increase_pct: increase_pct
        }
      end
      @upgrade_detection.sort_by! { |u| -u[:increase_pct] }

      # New category spending: categories in recent months not in early months
      early_categories = Set.new
      recent_categories = Set.new
      cat_by_month.each do |cat, month_data|
        early_categories << cat if early_months.any? { |m| (month_data[m] || 0) > 0 }
        recent_categories << cat if recent_months.any? { |m| (month_data[m] || 0) > 0 }
      end
      new_cats = recent_categories - early_categories
      @new_categories = new_cats.map do |cat|
        total = recent_months.sum { |m| cat_by_month[cat][m] || 0 }
        { category: cat, total: total.round(2) }
      end.sort_by { |c| -c[:total] }

      # Savings rate trend
      @savings_rate_data = sorted_months.map do |m|
        inc = monthly_income[m] || 0
        exp = monthly_expenses[m] || 0
        rate = inc > 0 ? ((inc - exp) / inc * 100).round(1) : 0
        { month: m, rate: rate }
      end

      # Savings erosion detection
      if @savings_rate_data.size >= 2
        first_half_rates = @savings_rate_data[0...(@savings_rate_data.size / 2)]
        second_half_rates = @savings_rate_data[(@savings_rate_data.size / 2)..]
        @early_savings_rate = first_half_rates.any? ? (first_half_rates.sum { |d| d[:rate] } / first_half_rates.size).round(1) : 0
        @recent_savings_rate = second_half_rates.any? ? (second_half_rates.sum { |d| d[:rate] } / second_half_rates.size).round(1) : 0
        @savings_eroded = @recent_savings_rate < @early_savings_rate
      else
        @early_savings_rate = 0
        @recent_savings_rate = 0
        @savings_eroded = false
      end

      # Cost-per-day trend by month
      @cost_per_day = sorted_months.map do |m|
        year, mon = m.split("-").map(&:to_i)
        days = Date.new(year, mon, -1).day rescue 30
        daily = monthly_expenses[m].to_f / days
        { month: m, daily: daily.round(2) }
      end

      # Creep alerts: categories with >20% increase quarter-over-quarter
      @creep_alerts = []
      if sorted_months.size >= 6
        quarters = sorted_months.each_slice(3).to_a.select { |q| q.size == 3 }
        if quarters.size >= 2
          cat_by_month.each do |cat, month_data|
            prev_q = quarters[-2]
            curr_q = quarters[-1]
            prev_total = prev_q.sum { |m| month_data[m] || 0 }
            curr_total = curr_q.sum { |m| month_data[m] || 0 }
            next if prev_total < 10
            qoq_change = ((curr_total - prev_total) / prev_total * 100).round(1)
            next if qoq_change <= 20
            @creep_alerts << {
              category: cat,
              prev_quarter: prev_total.round(2),
              curr_quarter: curr_total.round(2),
              change_pct: qoq_change
            }
          end
          @creep_alerts.sort_by! { |a| -a[:change_pct] }
        end
      end

      # Overall averages for stats
      total_expenses = monthly_expenses.values.sum
      total_months = [sorted_months.size, 1].max
      @avg_monthly_spending = (total_expenses / total_months).round(2)
      @avg_cost_per_day = @cost_per_day.any? ? (@cost_per_day.sum { |d| d[:daily] } / @cost_per_day.size).round(2) : 0
    end

    def fire_calculator
      @current_age = (params[:age] || 30).to_i.clamp(18, 80)
      @target_retirement_age = (params[:retirement_age] || 65).to_i.clamp(@current_age + 1, 90)
      @assumed_return = (params[:return_rate] || 7.0).to_f.clamp(0, 20)

      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 1000) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        elsif result.is_a?(Array)
          result
        else
          []
        end
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }

      all_transactions = threads[:transactions].value || []
      @funds = threads[:funds].value || []
      @goals = threads[:goals].value || []

      # Separate expenses and income
      expenses = all_transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = all_transactions.select { |t| t["transaction_type"] == "income" }

      # Group by month
      monthly_expenses = {}
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      # Use last 6 months for averages
      sorted_months = monthly_expenses.keys.sort
      recent_months = sorted_months.last(6)
      months_count = [recent_months.size, 1].max

      recent_expense_total = recent_months.sum { |m| monthly_expenses[m] || 0 }
      @avg_monthly_expenses = (recent_expense_total / months_count).round(2)
      @annual_expenses = (@avg_monthly_expenses * 12).round(2)

      recent_income_total = recent_months.sum { |m| monthly_income[m] || 0 }
      @avg_monthly_income = (recent_income_total / [recent_months.count { |m| monthly_income[m] }, 1].max).round(2)
      @monthly_savings = (@avg_monthly_income - @avg_monthly_expenses).round(2)

      # Savings rate
      @savings_rate = if @avg_monthly_income > 0
        ((@monthly_savings / @avg_monthly_income) * 100).round(1)
      else
        0.0
      end

      # Essential vs discretionary
      essential_categories = %w[housing rent mortgage utilities insurance groceries transportation healthcare debt]
      essential_total = 0
      discretionary_total = 0
      recent_expenses = expenses.select { |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        month && recent_months.include?(month)
      }
      recent_expenses.each do |t|
        cat = (t["category"] || t["budget_category"] || "").downcase
        if essential_categories.any? { |ec| cat.include?(ec) }
          essential_total += t["amount"].to_f
        else
          discretionary_total += t["amount"].to_f
        end
      end
      @avg_essential = (essential_total / months_count).round(2)
      @avg_discretionary = (discretionary_total / months_count).round(2)

      # FIRE Number (4% rule: annual expenses * 25)
      @fire_number = (@annual_expenses * 25).round(2)

      # Current savings from funds and goals
      @current_savings = @funds.sum { |f| f["current_amount"].to_f } + @goals.sum { |g| (g["effective_current_amount"] || g["current_amount"]).to_f }

      # FIRE progress percentage
      @fire_progress = @fire_number > 0 ? [(@current_savings / @fire_number * 100).round(1), 100].min : 0

      # 4% rule monthly income at FIRE
      @monthly_fire_income = (@fire_number * 0.04 / 12).round(2)

      # FIRE variants
      @lean_fire = (@fire_number * 0.8).round(2)
      @fat_fire = (@fire_number * 1.5).round(2)
      @barista_fire = (@avg_essential * 12 * 25).round(2)

      # Coast FIRE: amount needed now to grow to FIRE number by retirement age with no contributions
      years_to_retirement = @target_retirement_age - @current_age
      monthly_return = @assumed_return / 100.0 / 12
      annual_return = @assumed_return / 100.0

      @coast_fire = if annual_return > 0 && years_to_retirement > 0
        (@fire_number / ((1 + annual_return) ** years_to_retirement)).round(2)
      else
        @fire_number
      end

      # Years to FIRE using compound growth formula
      # FV = PV*(1+r)^n + PMT*((1+r)^n - 1)/r
      # Solve for n given FV = FIRE number, PV = current_savings, PMT = monthly_savings
      @years_to_fire = if @current_savings >= @fire_number
        0.0
      elsif @monthly_savings <= 0
        nil # Cannot reach FIRE with negative savings
      elsif monthly_return > 0
        # Iterative approach for accuracy
        months = 0
        balance = @current_savings.to_f
        while balance < @fire_number && months < 1200 # Cap at 100 years
          balance = balance * (1 + monthly_return) + @monthly_savings
          months += 1
        end
        months < 1200 ? (months / 12.0).round(1) : nil
      else
        gap = @fire_number - @current_savings
        months_needed = (gap / @monthly_savings).ceil
        (months_needed / 12.0).round(1)
      end

      @fire_date = @years_to_fire ? (Date.current + (@years_to_fire * 365.25).to_i.days) : nil
      @fire_age = @years_to_fire ? (@current_age + @years_to_fire).round(1) : nil

      # Monthly savings needed to reach FIRE by target retirement age
      months_to_retire = years_to_retirement * 12
      @monthly_savings_needed = if months_to_retire > 0 && monthly_return > 0
        fv_current = @current_savings * ((1 + monthly_return) ** months_to_retire)
        remaining = @fire_number - fv_current
        if remaining <= 0
          0.0
        else
          (remaining * monthly_return / ((1 + monthly_return) ** months_to_retire - 1)).round(2)
        end
      elsif months_to_retire > 0
        gap = @fire_number - @current_savings
        gap > 0 ? (gap / months_to_retire).round(2) : 0.0
      else
        0.0
      end

      # Expense reduction scenarios
      @expense_scenarios = [10, 20, 30].map do |pct|
        reduced_monthly = @avg_monthly_expenses * (1 - pct / 100.0)
        reduced_annual = reduced_monthly * 12
        reduced_fire = reduced_annual * 25
        new_savings = @avg_monthly_income - reduced_monthly
        new_savings_rate = @avg_monthly_income > 0 ? (new_savings / @avg_monthly_income * 100).round(1) : 0

        years = if @current_savings >= reduced_fire
          0.0
        elsif new_savings <= 0
          nil
        elsif monthly_return > 0
          m = 0
          bal = @current_savings.to_f
          while bal < reduced_fire && m < 1200
            bal = bal * (1 + monthly_return) + new_savings
            m += 1
          end
          m < 1200 ? (m / 12.0).round(1) : nil
        else
          gap = reduced_fire - @current_savings
          (gap / new_savings / 12.0).round(1)
        end

        {
          reduction_pct: pct,
          monthly_expenses: reduced_monthly.round(2),
          fire_number: reduced_fire.round(2),
          monthly_savings: new_savings.round(2),
          savings_rate: new_savings_rate,
          years_to_fire: years,
          fire_date: years ? (Date.current + (years * 365.25).to_i.days) : nil
        }
      end

      # FIRE variants with years
      @fire_variants = [
        { name: "Lean FIRE", amount: @lean_fire, description: "80% of regular expenses", icon: "eco", color: "var(--positive)" },
        { name: "Regular FIRE", amount: @fire_number, description: "Current lifestyle", icon: "local_fire_department", color: "#e65100" },
        { name: "Fat FIRE", amount: @fat_fire, description: "150% of regular expenses", icon: "diamond", color: "#6a1b9a" },
        { name: "Coast FIRE", amount: @coast_fire, description: "Invest now, no more contributions", icon: "sailing", color: "#0277bd" },
        { name: "Barista FIRE", amount: @barista_fire, description: "Cover essentials only", icon: "local_cafe", color: "#4e342e" }
      ].map do |v|
        target = v[:amount]
        years = if @current_savings >= target
          0.0
        elsif @monthly_savings <= 0
          nil
        elsif monthly_return > 0
          m = 0
          bal = @current_savings.to_f
          while bal < target && m < 1200
            bal = bal * (1 + monthly_return) + @monthly_savings
            m += 1
          end
          m < 1200 ? (m / 12.0).round(1) : nil
        else
          gap = target - @current_savings
          (gap / @monthly_savings / 12.0).round(1)
        end
        v.merge(years_to_fire: years)
      end

      # Savings projection data for chart (monthly points)
      projection_months = @years_to_fire ? [(@years_to_fire * 12).ceil, 600].min : [years_to_retirement * 12, 600].min
      projection_months = [projection_months, 12].max
      @projection_points = []
      balance = @current_savings.to_f
      step = [projection_months / 100, 1].max
      (0..projection_months).each do |m|
        if m % step == 0 || m == projection_months
          @projection_points << { month: m, balance: balance.round(2) }
        end
        balance = balance * (1 + monthly_return) + [@monthly_savings, 0].max
      end

      # Monthly data for sparkline
      @monthly_data = sorted_months.last(12).map do |m|
        {
          month: m,
          expenses: (monthly_expenses[m] || 0).round(2),
          income: (monthly_income[m] || 0).round(2),
          savings: ((monthly_income[m] || 0) - (monthly_expenses[m] || 0)).round(2)
        }
      end
    end

    def purchase_advisor
      @amount = (params[:amount] || 100).to_f
      @amount = 0.01 if @amount <= 0

      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 500) rescue {}
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
      threads[:budgets] = Thread.new {
        result = budget_client.budgets rescue []
        result.is_a?(Hash) ? (result["budgets"] || []) : Array(result)
      }

      transactions = threads[:transactions].value rescue []
      transactions = Array(transactions)
      budgets_list = threads[:budgets].value rescue []
      budgets_list = Array(budgets_list)

      # --- Monthly income & expenses ---
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      monthly_expenses = {}
      expense_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      all_months = (monthly_income.keys + monthly_expenses.keys).uniq.sort
      months_count = [all_months.count, 1].max

      avg_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      avg_expenses = monthly_expenses.values.any? ? monthly_expenses.values.sum / [monthly_expenses.count, 1].max : 0
      @avg_monthly_surplus = avg_income - avg_expenses

      # --- Affordability check ---
      @months_of_surplus = @avg_monthly_surplus > 0 ? (@amount / @avg_monthly_surplus).round(2) : nil
      @affordability = if @avg_monthly_surplus <= 0
        { verdict: "no", color: "var(--negative)", icon: "cancel", message: "You're currently spending more than you earn. This purchase would add to your deficit." }
      elsif @months_of_surplus <= 0.25
        { verdict: "yes", color: "var(--positive)", icon: "check_circle", message: "This is less than a week's surplus. Easily affordable if it aligns with your priorities." }
      elsif @months_of_surplus <= 1.0
        { verdict: "maybe", color: "#f9a825", icon: "warning", message: "This represents #{@months_of_surplus} months of savings. Consider whether it's a need or a want." }
      else
        { verdict: "no", color: "var(--negative)", icon: "cancel", message: "This would take #{@months_of_surplus} months of surplus to recoup. Think carefully before committing." }
      end

      # --- Cost-per-use estimates ---
      @cost_per_use = [
        { frequency: "Daily use", uses_per_year: 365, cost: (@amount / 365.0).round(2) },
        { frequency: "Weekdays only", uses_per_year: 260, cost: (@amount / 260.0).round(2) },
        { frequency: "Weekly use", uses_per_year: 52, cost: (@amount / 52.0).round(2) },
        { frequency: "2x per month", uses_per_year: 24, cost: (@amount / 24.0).round(2) },
        { frequency: "Monthly use", uses_per_year: 12, cost: (@amount / 12.0).round(2) },
        { frequency: "Quarterly use", uses_per_year: 4, cost: (@amount / 4.0).round(2) }
      ]

      # --- Opportunity cost (7% annual return) ---
      rate = 0.07
      @opportunity_cost = [1, 5, 10, 20, 30].map do |years|
        future_value = (@amount * (1 + rate)**years).round(2)
        { years: years, future_value: future_value, growth: (future_value - @amount).round(2) }
      end

      # --- Work hours equivalent ---
      @estimated_hourly = avg_income > 0 ? (avg_income / 160.0).round(2) : 25.0
      @work_hours = (@amount / @estimated_hourly).round(1)
      @work_days = (@work_hours / 8.0).round(1)

      # --- Budget impact ---
      @budget_impacts = []
      current_budget = budgets_list.first
      if current_budget.is_a?(Hash)
        categories = current_budget["categories"] || current_budget["budget_categories"] || []
        categories = Array(categories)
        categories.each do |cat|
          cat_name = cat["name"] || cat["category"] || "Unknown"
          budgeted = cat["budgeted"].to_f
          spent = cat["spent"].to_f || cat["actual"].to_f
          remaining = budgeted - spent
          would_exceed = (@amount > remaining && remaining >= 0) ? true : false
          items = cat["items"] || cat["budget_items"] || []
          @budget_impacts << {
            category: cat_name,
            budgeted: budgeted,
            spent: spent,
            remaining: remaining.round(2),
            would_exceed: would_exceed,
            items: Array(items)
          }
        end
      end
      @budget_impacts = @budget_impacts.sort_by { |b| b[:remaining] }

      # --- 30-day rule ---
      @thirty_day_threshold = 50
      @show_thirty_day_rule = @amount > @thirty_day_threshold

      # --- Comparison framework: cost per day at various lifespans ---
      @durability = [
        { lifespan: "1 year", days: 365, cost_per_day: (@amount / 365.0).round(3) },
        { lifespan: "3 years", days: 1095, cost_per_day: (@amount / 1095.0).round(3) },
        { lifespan: "5 years", days: 1825, cost_per_day: (@amount / 1825.0).round(3) },
        { lifespan: "10 years", days: 3650, cost_per_day: (@amount / 3650.0).round(3) }
      ]

      # --- Purchase history context: largest past purchases by category ---
      @past_purchases = {}
      expense_txns.each do |t|
        cat = t["category"] || t["budget_category"] || "Other"
        amt = t["amount"].to_f
        desc = t["description"] || t["merchant"] || "Unknown"
        date = t["transaction_date"]
        @past_purchases[cat] ||= []
        @past_purchases[cat] << { amount: amt, description: desc, date: date }
      end
      @largest_purchases = @past_purchases.map do |cat, items|
        largest = items.max_by { |i| i[:amount] }
        { category: cat, amount: largest[:amount], description: largest[:description], date: largest[:date] }
      end.sort_by { |p| -p[:amount] }.first(10)
    end

    def net_worth_dashboard
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 500) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        else
          Array(result)
        end
      }
      threads[:funds] = Thread.new {
        result = budget_client.funds rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["funds"] || []) : [])
      }
      threads[:goals] = Thread.new {
        result = budget_client.goals rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["goals"] || []) : [])
      }
      threads[:debt_accounts] = Thread.new {
        result = budget_client.debt_accounts rescue []
        if result.is_a?(Array)
          result
        elsif result.is_a?(Hash)
          result["debt_accounts"] || result["debts"] || result["accounts"] || []
        else
          []
        end
      }

      transactions = threads[:transactions].value || []
      funds = threads[:funds].value || []
      goals = threads[:goals].value || []
      debt_accounts = threads[:debt_accounts].value || []

      # Ensure arrays
      transactions = Array(transactions).select { |t| t.is_a?(Hash) }
      funds = Array(funds).select { |f| f.is_a?(Hash) }
      goals = Array(goals).select { |g| g.is_a?(Hash) }
      debt_accounts = Array(debt_accounts).select { |d| d.is_a?(Hash) }

      # --- Assets ---
      @asset_allocation = funds.map do |f|
        {
          name: f["name"] || "Unnamed Fund",
          amount: f["current_amount"].to_f,
          target: f["target_amount"].to_f,
          fund_type: f["fund_type"] || f["category"] || "savings"
        }
      end.sort_by { |a| -a[:amount] }

      @total_assets = @asset_allocation.sum { |a| a[:amount] }

      # Liquid vs Illiquid classification
      illiquid_keywords = %w[investment retirement 401k ira pension real_estate property]
      @liquid_assets = 0.0
      @illiquid_assets = 0.0
      @asset_allocation.each do |a|
        key = (a[:name].to_s + " " + a[:fund_type].to_s).downcase
        if illiquid_keywords.any? { |kw| key.include?(kw) }
          @illiquid_assets += a[:amount]
        else
          @liquid_assets += a[:amount]
        end
      end

      # --- Liabilities ---
      @debt_composition = debt_accounts.select { |d| d["current_balance"].to_f > 0 }.map do |d|
        {
          name: d["name"] || "Unknown Debt",
          balance: d["current_balance"].to_f,
          rate: d["interest_rate"].to_f,
          min_payment: d["minimum_payment"].to_f,
          debt_type: d["debt_type"]&.titleize || "Other"
        }
      end.sort_by { |d| -d[:balance] }

      @total_liabilities = @debt_composition.sum { |d| d[:balance] }

      # --- Net Worth ---
      @net_worth = @total_assets - @total_liabilities

      # --- Asset-to-Debt Ratio ---
      @asset_debt_ratio = if @total_liabilities > 0
        (@total_assets / @total_liabilities).round(2)
      else
        @total_assets > 0 ? Float::INFINITY : 0
      end

      # --- Monthly Change from Transactions ---
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_income[month] ||= 0
        monthly_income[month] += t["amount"].to_f
      end

      monthly_expenses = {}
      expense_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_expenses[month] ||= 0
        monthly_expenses[month] += t["amount"].to_f
      end

      all_months = (monthly_income.keys + monthly_expenses.keys).uniq.sort
      @monthly_trend = all_months.last(6).map do |m|
        inc = monthly_income[m] || 0
        exp = monthly_expenses[m] || 0
        { month: m, income: inc, expenses: exp, net: inc - exp }
      end

      @avg_monthly_income = monthly_income.values.any? ? monthly_income.values.sum / [monthly_income.count, 1].max : 0
      @avg_monthly_expenses = monthly_expenses.values.any? ? monthly_expenses.values.sum / [monthly_expenses.count, 1].max : 0
      @monthly_change = @avg_monthly_income - @avg_monthly_expenses

      # Current month vs previous month for change indicator
      current_month = Date.current.strftime("%Y-%m")
      prev_month = (Date.current << 1).strftime("%Y-%m")
      current_net = (monthly_income[current_month] || 0) - (monthly_expenses[current_month] || 0)
      prev_net = (monthly_income[prev_month] || 0) - (monthly_expenses[prev_month] || 0)
      @month_over_month_change = current_net - prev_net

      # --- Growth Rate (month-over-month %) ---
      if @monthly_trend.length >= 2
        recent = @monthly_trend.last[:net]
        previous = @monthly_trend[-2][:net]
        @growth_rate = if previous != 0
          ((recent - previous) / previous.abs * 100).round(1)
        else
          0
        end
      else
        @growth_rate = 0
      end

      # --- Milestones ---
      milestone_targets = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
      @milestones_reached = milestone_targets.select { |m| @net_worth >= m }
      @milestones_upcoming = milestone_targets.select { |m| @net_worth < m }

      # --- Next Milestone ---
      @next_milestone = @milestones_upcoming.first
      if @next_milestone
        @milestone_gap = @next_milestone - @net_worth
        @milestone_progress = (@net_worth.to_f / @next_milestone * 100).clamp(0, 100).round(1)
        @milestone_eta_months = if @monthly_change > 0
          (@milestone_gap / @monthly_change).ceil
        else
          nil
        end
      end

      # Chart colors
      @asset_colors = ["#2e7d32", "#43a047", "#66bb6a", "#81c784", "#a5d6a7", "#c8e6c9", "#388e3c", "#1b5e20"]
      @debt_colors = ["#e53935", "#ef5350", "#e57373", "#ef9a9a", "#d32f2f", "#c62828", "#f44336", "#b71c1c"]
    end

    def money_calendar
      # Determine target month from params
      now = Date.current
      target_year = (params[:year] || now.year).to_i
      target_month = (params[:month] || now.month).to_i
      target_year = target_year.clamp(2000, 2100)
      target_month = target_month.clamp(1, 12)
      @target_date = Date.new(target_year, target_month, 1)
      @month_start = @target_date.beginning_of_month
      @month_end = @target_date.end_of_month

      # Fetch data
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 1000) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        else
          Array(result)
        end
      }
      threads[:recurring] = Thread.new {
        result = budget_client.recurring rescue []
        if result.is_a?(Array)
          result
        elsif result.is_a?(Hash)
          result["items"] || result["recurring"] || result["recurring_transactions"] || []
        else
          []
        end
      }

      transactions = threads[:transactions].value || []
      recurring_items = threads[:recurring].value || []

      # Filter transactions to target month
      month_transactions = transactions.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= @month_start && d <= @month_end
      }

      income_txns = month_transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = month_transactions.select { |t| t["transaction_type"] != "income" }

      # Build daily data
      @daily_data = {}
      (@month_start..@month_end).each do |day|
        @daily_data[day] = { expenses: 0.0, income: 0.0, net: 0.0, is_bill: false }
      end

      expense_txns.each do |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        next unless d && @daily_data[d]
        @daily_data[d][:expenses] += t["amount"].to_f.abs
      end

      income_txns.each do |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        next unless d && @daily_data[d]
        @daily_data[d][:income] += t["amount"].to_f.abs
      end

      # Mark bill days from recurring items
      recurring_items.each do |item|
        day_of_month = (item["day_of_month"] || item["due_day"]).to_i
        next unless day_of_month > 0 && day_of_month <= @month_end.day
        bill_date = Date.new(target_year, target_month, day_of_month) rescue nil
        next unless bill_date && @daily_data[bill_date]
        @daily_data[bill_date][:is_bill] = true
        amount = (item["amount"] || item["average_amount"]).to_f.abs
        if amount > 0 && @daily_data[bill_date][:expenses] == 0
          @daily_data[bill_date][:expenses] += amount
        end
      end

      # Calculate net for each day
      @daily_data.each do |day, data|
        data[:net] = data[:income] - data[:expenses]
      end

      # Running balance
      @running_balance = {}
      cumulative = 0.0
      (@month_start..@month_end).each do |day|
        cumulative += @daily_data[day][:net]
        @running_balance[day] = cumulative
      end

      # Summary stats
      @total_spent = @daily_data.values.sum { |d| d[:expenses] }
      @total_income = @daily_data.values.sum { |d| d[:income] }
      @no_spend_days = @daily_data.values.count { |d| d[:expenses] == 0 }

      days_with_data = @daily_data.select { |_, d| d[:net] != 0 }
      if days_with_data.any?
        best_entry = @daily_data.max_by { |_, d| d[:net] }
        worst_entry = @daily_data.min_by { |_, d| d[:net] }
        @best_day = { date: best_entry[0], net: best_entry[1][:net] }
        @worst_day = { date: worst_entry[0], net: worst_entry[1][:net] }
      else
        @best_day = { date: @month_start, net: 0 }
        @worst_day = { date: @month_start, net: 0 }
      end

      # Weekly totals
      @weekly_totals = []
      week_start = @month_start
      while week_start <= @month_end
        week_end = [week_start + (6 - week_start.wday).days, @month_end].min
        week_expenses = 0.0
        week_income = 0.0
        (week_start..week_end).each do |d|
          next unless @daily_data[d]
          week_expenses += @daily_data[d][:expenses]
          week_income += @daily_data[d][:income]
        end
        @weekly_totals << { start: week_start, finish: week_end, expenses: week_expenses, income: week_income, net: week_income - week_expenses }
        week_start = week_end + 1.day
      end

      # Day-of-week averages (from all transactions, not just this month)
      all_expense_txns = transactions.select { |t| t["transaction_type"] != "income" }
      dow_totals = Array.new(7, 0.0)
      dow_counts = Array.new(7, 0)
      all_expense_txns.each do |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        next unless d
        dow_totals[d.wday] += t["amount"].to_f.abs
        dow_counts[d.wday] += 1
      end
      @dow_averages = %w[Sun Mon Tue Wed Thu Fri Sat].each_with_index.map { |name, i|
        { day: name, avg: dow_counts[i] > 0 ? (dow_totals[i] / dow_counts[i]).round(2) : 0.0 }
      }

      # Income days
      @income_days = @daily_data.select { |_, d| d[:income] > 0 }.keys

      # Max spending for color intensity
      @max_expense = [@daily_data.values.map { |d| d[:expenses] }.max.to_f, 1].max

      # Navigation
      @prev_month = @target_date << 1
      @next_month = @target_date >> 1
      @show_next = @next_month.beginning_of_month <= now.beginning_of_month
    end

    def impulse_tracker
      # Fetch transactions defensively
      begin
        result = budget_client.transactions(per_page: 1000)
        all_transactions = if result.is_a?(Hash)
                             result["transactions"] || []
                           else
                             Array(result)
                           end
      rescue => e
        Rails.logger.error("ImpulseTracker: failed to fetch transactions: #{e.message}")
        all_transactions = []
      end

      # Separate by type
      expenses = all_transactions.select { |t| t["transaction_type"] != "income" }
      income_txns = all_transactions.select { |t| t["transaction_type"] == "income" }

      @total_transactions = expenses.size
      @impulse_flags = []

      # ---- Pattern 1: Late night purchases (10pm - 6am) ----
      late_night = []
      expenses.each do |t|
        time_str = t["created_at"] || t["transaction_date"]
        next unless time_str.to_s.include?("T") || time_str.to_s.include?(" ")
        begin
          hour = Time.parse(time_str.to_s).hour
          late_night << t if hour >= 22 || hour < 6
        rescue
          next
        end
      end
      @late_night_purchases = late_night

      # ---- Pattern 2: Weekend splurges ----
      weekend_spending = 0.0
      weekday_spending = 0.0
      weekend_count = 0
      weekday_count = 0
      expenses.each do |t|
        date = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
        next unless date
        if date.saturday? || date.sunday?
          weekend_spending += t["amount"].to_f
          weekend_count += 1
        else
          weekday_spending += t["amount"].to_f
          weekday_count += 1
        end
      end
      avg_weekend = weekend_count > 0 ? weekend_spending / weekend_count : 0
      avg_weekday = weekday_count > 0 ? weekday_spending / weekday_count : 0
      @weekend_premium = avg_weekday > 0 ? ((avg_weekend - avg_weekday) / avg_weekday * 100).round(1) : 0
      @weekend_splurge = @weekend_premium > 20
      weekend_impulse_txns = []
      if @weekend_splurge
        expenses.each do |t|
          date = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
          next unless date && (date.saturday? || date.sunday?) && t["amount"].to_f > avg_weekday * 1.5
          weekend_impulse_txns << t
        end
      end

      # ---- Pattern 3: Merchant frequency spikes ----
      impulse_merchants_keywords = %w[amazon uber doordash grubhub ubereats postmates instacart target walmart netflix spotify entertainment gaming steam playstation xbox shop store mall boutique]
      merchant_counts = Hash.new(0)
      merchant_totals = Hash.new(0.0)
      expenses.each do |t|
        merchant = (t["merchant"] || t["description"] || "unknown").downcase.strip
        merchant_counts[merchant] += 1
        merchant_totals[merchant] += t["amount"].to_f
      end
      @merchant_spikes = merchant_counts.select { |merchant, count|
        count >= 5 && impulse_merchants_keywords.any? { |kw| merchant.include?(kw) }
      }.map { |merchant, count|
        { merchant: merchant.titleize, count: count, total: merchant_totals[merchant].round(2) }
      }.sort_by { |m| -m[:total] }

      # ---- Pattern 4: Small purchase accumulation (sub-$20) ----
      small_purchases = expenses.select { |t| t["amount"].to_f > 0 && t["amount"].to_f < 20 }
      @small_purchase_count = small_purchases.size
      @small_purchase_total = small_purchases.sum { |t| t["amount"].to_f }.round(2)
      @small_purchase_pct = expenses.any? ? (small_purchases.size.to_f / expenses.size * 100).round(1) : 0

      # ---- Pattern 5: Category outliers ----
      category_totals = Hash.new { |h, k| h[k] = [] }
      expenses.each do |t|
        cat = (t["category"] || t["budget_category"] || "uncategorized").downcase
        category_totals[cat] << t["amount"].to_f
      end
      @category_outliers = []
      category_totals.each do |cat, amounts|
        next if amounts.size < 3
        avg = amounts.sum / amounts.size
        std_dev = Math.sqrt(amounts.sum { |a| (a - avg) ** 2 } / amounts.size)
        threshold = avg + (std_dev * 1.5)
        expenses.each do |t|
          t_cat = (t["category"] || t["budget_category"] || "uncategorized").downcase
          next unless t_cat == cat && t["amount"].to_f > threshold && t["amount"].to_f > avg * 2
          @category_outliers << { transaction: t, category: cat.titleize, amount: t["amount"].to_f, avg: avg.round(2) }
        end
      end
      @category_outliers = @category_outliers.sort_by { |o| -o[:amount] }.first(10)

      # ---- Pattern 6: Post-payday spending ----
      income_dates = income_txns.map { |t|
        begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
      }.compact
      post_payday_txns = []
      income_dates.each do |payday|
        (1..3).each do |offset|
          target_day = payday + offset
          expenses.each do |t|
            date = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
            next unless date == target_day
            post_payday_txns << t
          end
        end
      end
      @post_payday_spending = post_payday_txns.sum { |t| t["amount"].to_f }.round(2)
      @post_payday_count = post_payday_txns.size
      total_expenses_amount = expenses.sum { |t| t["amount"].to_f }
      total_days_span = if expenses.any?
        dates = expenses.map { |t| begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end }.compact
        dates.any? ? ([dates.max - dates.min, 1].max).to_i : 1
      else
        1
      end
      avg_daily_spending = total_expenses_amount / total_days_span
      payday_window_days = income_dates.size * 3
      expected_payday_spending = avg_daily_spending * payday_window_days
      @post_payday_premium = expected_payday_spending > 0 ? ((@post_payday_spending - expected_payday_spending) / expected_payday_spending * 100).round(1) : 0

      # ---- Pattern 7: Emotional spending (clusters of small purchases on same day) ----
      daily_purchase_counts = Hash.new(0)
      daily_purchase_amounts = Hash.new(0.0)
      expenses.each do |t|
        date = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
        next unless date
        daily_purchase_counts[date] += 1
        daily_purchase_amounts[date] += t["amount"].to_f
      end
      @emotional_spending_days = daily_purchase_counts.select { |date, count|
        count >= 4
      }.map { |date, count|
        { date: date, count: count, total: daily_purchase_amounts[date].round(2) }
      }.sort_by { |d| -d[:count] }

      # ---- Compute impulse score (0-100) ----
      score_components = []

      # Late night component (0-15)
      late_night_ratio = expenses.any? ? (late_night.size.to_f / expenses.size * 100) : 0
      score_components << { name: "Late Night Purchases", weight: 15, raw: [late_night_ratio * 3, 15].min.round(1) }

      # Weekend splurge component (0-15)
      weekend_score = [@weekend_premium.clamp(0, 100) * 0.15, 15].min.round(1)
      score_components << { name: "Weekend Splurges", weight: 15, raw: weekend_score }

      # Merchant frequency component (0-15)
      merchant_spike_score = [@merchant_spikes.size * 3, 15].min.to_f.round(1)
      score_components << { name: "Merchant Frequency Spikes", weight: 15, raw: merchant_spike_score }

      # Small purchase component (0-20)
      small_score = [@small_purchase_pct * 0.4, 20].min.round(1)
      score_components << { name: "Small Purchase Accumulation", weight: 20, raw: small_score }

      # Category outlier component (0-10)
      outlier_score = [@category_outliers.size * 2, 10].min.to_f.round(1)
      score_components << { name: "Category Outliers", weight: 10, raw: outlier_score }

      # Post-payday component (0-15)
      payday_score = [@post_payday_premium.clamp(0, 100) * 0.15, 15].min.round(1)
      score_components << { name: "Post-Payday Spending", weight: 15, raw: payday_score }

      # Emotional spending component (0-10)
      emotional_score = [@emotional_spending_days.size * 2, 10].min.to_f.round(1)
      score_components << { name: "Emotional Spending Clusters", weight: 10, raw: emotional_score }

      @impulse_score = [score_components.sum { |c| c[:raw] }.round, 100].min
      @score_components = score_components.sort_by { |c| -c[:raw] }

      # ---- Total impulse spending estimate ----
      impulse_transaction_ids = Set.new
      late_night.each { |t| impulse_transaction_ids << t.object_id }
      weekend_impulse_txns.each { |t| impulse_transaction_ids << t.object_id }
      small_purchases.each { |t| impulse_transaction_ids << t.object_id }
      post_payday_txns.each { |t| impulse_transaction_ids << t.object_id }
      @category_outliers.each { |o| impulse_transaction_ids << o[:transaction].object_id }

      flagged_txns = expenses.select { |t| impulse_transaction_ids.include?(t.object_id) }
      @total_impulse_spending = flagged_txns.sum { |t| t["amount"].to_f }.round(2)
      @impulse_pct_of_total = total_expenses_amount > 0 ? (@total_impulse_spending / total_expenses_amount * 100).round(1) : 0

      # ---- Monthly impulse trend ----
      monthly_impulse = Hash.new(0.0)
      monthly_total = Hash.new(0.0)
      flagged_txns.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_impulse[month] += t["amount"].to_f
      end
      expenses.each do |t|
        month = t["transaction_date"]&.to_s&.slice(0, 7)
        next unless month
        monthly_total[month] += t["amount"].to_f
      end
      @monthly_trend = monthly_total.keys.sort.map { |month|
        impulse_amt = monthly_impulse[month] || 0
        total_amt = monthly_total[month] || 1
        { month: month, impulse: impulse_amt.round(2), total: total_amt.round(2), pct: (impulse_amt / total_amt * 100).round(1) }
      }

      # Trend direction
      if @monthly_trend.size >= 2
        recent = @monthly_trend.last(3).map { |m| m[:pct] }
        older = @monthly_trend.first([3, @monthly_trend.size - 3].max).map { |m| m[:pct] }
        recent_avg = recent.any? ? recent.sum / recent.size : 0
        older_avg = older.any? ? older.sum / older.size : 0
        @trend_direction = if recent_avg < older_avg - 5
          "improving"
        elsif recent_avg > older_avg + 5
          "worsening"
        else
          "stable"
        end
      else
        @trend_direction = "insufficient_data"
      end

      # ---- Impulse triggers ranking ----
      @impulse_triggers = @score_components.select { |c| c[:raw] > 0 }.map { |c|
        { name: c[:name], score: c[:raw], max: c[:weight] }
      }

      # ---- Savings if eliminated ----
      months_of_data = [@monthly_trend.size, 1].max
      monthly_avg_impulse = @total_impulse_spending / months_of_data
      @annual_savings_potential = (monthly_avg_impulse * 12).round(2)

      # ---- Worst impulse days ----
      @worst_days = daily_purchase_counts.map { |date, count|
        flagged_on_day = flagged_txns.select { |t|
          d = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
          d == date
        }
        {
          date: date,
          total_transactions: count,
          flagged_count: flagged_on_day.size,
          flagged_total: flagged_on_day.sum { |t| t["amount"].to_f }.round(2)
        }
      }.select { |d| d[:flagged_count] > 0 }.sort_by { |d| -d[:flagged_total] }.first(7)

      # ---- Tips ----
      @tips = []
      @tips << { title: "Implement the 24-Hour Rule", description: "Before any non-essential purchase over $30, wait 24 hours. Most impulse urges fade within a day.", icon: "timer" }
      @tips << { title: "Unsubscribe from Marketing Emails", description: "Remove yourself from retail mailing lists. Out of sight, out of mind.", icon: "unsubscribe" }
      @tips << { title: "Use Cash for Discretionary Spending", description: "Physical money makes spending feel more real. Set a weekly cash allowance.", icon: "payments" }
      @tips << { title: "Track Emotional Triggers", description: "Note your mood before purchases. Stress, boredom, and sadness are top impulse triggers.", icon: "psychology" }
      @tips << { title: "Set a Fun Money Budget", description: "Allocate a specific amount for impulse buys each month. Spend guilt-free within that limit.", icon: "savings" }
      if @late_night_purchases.any?
        @tips << { title: "Avoid Late Night Shopping", description: "Your data shows late-night purchases. Remove saved payment info from apps or set a phone curfew.", icon: "nightlight" }
      end
      if @post_payday_premium > 30
        @tips << { title: "Automate Savings on Payday", description: "Move money to savings immediately on payday before you can spend it.", icon: "account_balance" }
      end
      if @small_purchase_pct > 40
        @tips << { title: "Batch Small Purchases", description: "Your small purchases add up to #{number_to_currency(@small_purchase_total)}. Try batching errands into one weekly trip.", icon: "shopping_basket" }
      end
    end

    def paycheck_planner
      # Fetch transactions and recurring bills
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 500) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        else
          Array(result)
        end
      }
      threads[:recurring] = Thread.new {
        result = budget_client.recurring rescue []
        if result.is_a?(Array)
          result
        elsif result.is_a?(Hash)
          result["items"] || result["recurring"] || result["recurring_transactions"] || []
        else
          []
        end
      }

      transactions = threads[:transactions].value || []
      recurring_items = threads[:recurring].value || []

      now = Date.current
      six_months_ago = (now << 6).beginning_of_month

      # Separate income vs expenses
      income_txns = transactions.select { |t| t["transaction_type"] == "income" }
      expense_txns = transactions.select { |t| t["transaction_type"] != "income" }

      # Filter to last 6 months
      recent_income = income_txns.select { |t|
        d = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
        d && d >= six_months_ago && d <= now
      }
      recent_expenses = expense_txns.select { |t|
        d = begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
        d && d >= six_months_ago && d <= now
      }

      # ---- Pay frequency detection ----
      income_dates = recent_income.map { |t|
        begin; Date.parse(t["transaction_date"].to_s); rescue; nil; end
      }.compact.sort

      # Detect frequency from gaps between income deposits
      if income_dates.size >= 2
        gaps = income_dates.each_cons(2).map { |a, b| (b - a).to_i }
        median_gap = gaps.sort[gaps.size / 2] || 30

        @pay_frequency = if median_gap <= 10
          "weekly"
        elsif median_gap <= 20
          "biweekly"
        else
          "monthly"
        end
      else
        @pay_frequency = "monthly"
      end

      @paychecks_per_month = case @pay_frequency
        when "weekly" then 4.33
        when "biweekly" then 2.17
        else 1.0
      end

      # ---- Average paycheck (median income deposit) ----
      income_amounts = recent_income.map { |t| t["amount"].to_f.abs }.sort
      if income_amounts.any?
        mid = income_amounts.size / 2
        @avg_paycheck = income_amounts.size.odd? ? income_amounts[mid] : ((income_amounts[mid - 1] + income_amounts[mid]) / 2.0)
      else
        @avg_paycheck = 0
      end
      @avg_paycheck = @avg_paycheck.round(2)

      @monthly_income = (@avg_paycheck * @paychecks_per_month).round(2)

      # ---- Fixed expenses from recurring bills ----
      @fixed_bills = recurring_items.map { |item|
        day = (item["day_of_month"] || item["due_day"] || item["next_due_date"]&.to_s&.slice(8, 2)).to_i rescue 0
        day = 1 if day <= 0 || day > 31
        {
          name: item["name"] || item["merchant"] || item["description"] || "Bill",
          amount: (item["amount"] || item["avg_amount"] || 0).to_f.abs,
          day: day,
          category: item["category"] || "Uncategorized"
        }
      }.select { |b| b[:amount] > 0 }.sort_by { |b| b[:day] }

      @fixed_monthly = @fixed_bills.sum { |b| b[:amount] }.round(2)
      @fixed_per_paycheck = (@fixed_monthly / @paychecks_per_month).round(2)

      # ---- Variable expenses from recent spending ----
      non_recurring_names = @fixed_bills.map { |b| b[:name].downcase }
      variable_txns = recent_expenses.reject { |t|
        name = (t["name"] || t["merchant"] || t["description"] || "").downcase
        non_recurring_names.any? { |rn| name.include?(rn) || rn.include?(name) }
      }

      months_with_data = recent_expenses.map { |t| t["transaction_date"]&.to_s&.slice(0, 7) }.compact.uniq
      months_count = [months_with_data.size, 1].max

      variable_monthly = variable_txns.sum { |t| t["amount"].to_f.abs } / months_count
      @variable_per_month = variable_monthly.round(2)
      @variable_per_paycheck = (@variable_per_month / @paychecks_per_month).round(2)

      # ---- Category breakdown of variable spending ----
      category_totals = {}
      variable_txns.each do |t|
        cat = t["category"] || t["budget_category"] || "Other"
        category_totals[cat] ||= 0
        category_totals[cat] += t["amount"].to_f.abs
      end
      @category_monthly = category_totals.transform_values { |v| (v / months_count).round(2) }
      @category_monthly = @category_monthly.sort_by { |_, v| -v }.to_h
      @category_per_paycheck = @category_monthly.transform_values { |v| (v / @paychecks_per_month).round(2) }

      # ---- Savings target (20% of paycheck or leftover) ----
      @savings_target_pct = 20
      @savings_target = (@avg_paycheck * @savings_target_pct / 100.0).round(2)

      # ---- Discretionary allowance ----
      @discretionary = [@avg_paycheck - @fixed_per_paycheck - @variable_per_paycheck - @savings_target, 0].max.round(2)

      # ---- Zero-based allocation ----
      @allocation = {
        fixed: { label: "Fixed Bills", amount: @fixed_per_paycheck, color: "#e53935", icon: "receipt_long" },
        variable: { label: "Variable Spending", amount: @variable_per_paycheck, color: "#fb8c00", icon: "shopping_cart" },
        savings: { label: "Savings", amount: @savings_target, color: "#2e7d32", icon: "savings" },
        discretionary: { label: "Discretionary", amount: @discretionary, color: "#1565c0", icon: "wallet" }
      }

      @total_allocated = @allocation.values.sum { |a| a[:amount] }.round(2)
      @unallocated = [@avg_paycheck - @total_allocated, 0].max.round(2)

      # ---- Bill timing: which bills come from which paycheck ----
      if @pay_frequency == "biweekly"
        # Assume paychecks on 1st and 15th for allocation purposes
        @paycheck_1_bills = @fixed_bills.select { |b| b[:day] <= 14 }
        @paycheck_2_bills = @fixed_bills.select { |b| b[:day] > 14 }
        @paycheck_1_fixed = @paycheck_1_bills.sum { |b| b[:amount] }.round(2)
        @paycheck_2_fixed = @paycheck_2_bills.sum { |b| b[:amount] }.round(2)

        # Per-paycheck variable split (proportional to fixed load)
        total_fixed = @paycheck_1_fixed + @paycheck_2_fixed
        if total_fixed > 0
          ratio_1 = @paycheck_1_fixed / total_fixed
          ratio_2 = @paycheck_2_fixed / total_fixed
        else
          ratio_1 = 0.5
          ratio_2 = 0.5
        end

        @paycheck_1_plan = {
          fixed: @paycheck_1_fixed,
          variable: (@variable_per_paycheck * (1 - ratio_1 * 0.3)).round(2),
          savings: (@savings_target * 0.5).round(2),
          discretionary: 0
        }
        @paycheck_1_plan[:discretionary] = [@avg_paycheck - @paycheck_1_plan[:fixed] - @paycheck_1_plan[:variable] - @paycheck_1_plan[:savings], 0].max.round(2)

        @paycheck_2_plan = {
          fixed: @paycheck_2_fixed,
          variable: (@variable_per_paycheck * (1 - ratio_2 * 0.3)).round(2),
          savings: (@savings_target * 0.5).round(2),
          discretionary: 0
        }
        @paycheck_2_plan[:discretionary] = [@avg_paycheck - @paycheck_2_plan[:fixed] - @paycheck_2_plan[:variable] - @paycheck_2_plan[:savings], 0].max.round(2)
      elsif @pay_frequency == "weekly"
        # Weekly: distribute bills across 4 weeks
        @weekly_bills = (1..4).map { |week|
          start_day = (week - 1) * 7 + 1
          end_day = week * 7
          bills = @fixed_bills.select { |b| b[:day] >= start_day && b[:day] <= end_day }
          { week: week, bills: bills, total: bills.sum { |b| b[:amount] }.round(2) }
        }
      end

      # ---- Buffer recommendation ----
      # Suggest buffer equal to largest single paycheck bill cluster plus 10%
      max_bill_cluster = if @pay_frequency == "biweekly"
        [@paycheck_1_fixed || 0, @paycheck_2_fixed || 0].max
      else
        @fixed_monthly
      end
      @buffer_amount = (max_bill_cluster * 1.1).round(2)
      @buffer_days = @pay_frequency == "biweekly" ? 3 : 5
      @buffer_reason = if @pay_frequency == "biweekly"
        "Cover timing mismatches when bills hit before your paycheck clears"
      else
        "Provide a cushion for variable bill amounts and timing gaps"
      end

      # ---- Typical income days for display ----
      income_day_counts = {}
      income_dates.each { |d| income_day_counts[d.day] = (income_day_counts[d.day] || 0) + 1 }
      @typical_pay_days = income_day_counts.sort_by { |_, c| -c }.first(3).map { |d, c| { day: d, count: c } }
    end

    def forecast_accuracy
      # Fetch transactions and budgets in parallel
      threads = {}
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(per_page: 1000) rescue nil
        if result.is_a?(Hash)
          result["transactions"] || []
        else
          Array(result)
        end
      }
      threads[:budgets] = Thread.new {
        result = budget_client.budgets rescue []
        result.is_a?(Hash) ? (result["budgets"] || []) : Array(result)
      }

      transactions = threads[:transactions].value rescue []
      transactions = Array(transactions)
      budgets_list = threads[:budgets].value rescue []
      budgets_list = Array(budgets_list)

      # Extract budget category limits from current budget
      budget_limits = {}  # { category_name => budgeted_amount }
      current_budget = budgets_list.first
      if current_budget.is_a?(Hash)
        categories = current_budget["categories"] || current_budget["budget_categories"] || []
        categories.each do |bc|
          cat_name = bc["name"] || bc["category"] || ""
          limit = bc["amount"].to_f rescue 0
          budget_limits[cat_name] = limit if cat_name.present? && limit > 0
        end
      end

      # Filter to expenses only and normalize
      expenses = transactions.select { |t| t["transaction_type"] != "income" }
      expenses.each { |t| t["_abs_amount"] = t["amount"].to_f.abs }

      # Group expenses by month and category
      now = Date.current
      six_months_ago = (now << 6).beginning_of_month
      recent_expenses = expenses.select { |t|
        d = Date.parse(t["transaction_date"].to_s) rescue nil
        d && d >= six_months_ago && d <= now
      }

      months_list = (0..5).map { |i| (now << i).strftime("%Y-%m") }.reverse
      monthly_cat_data = {}  # { category => { "2026-01" => total, ... } }
      monthly_totals = {}    # { "2026-01" => total }

      recent_expenses.each do |t|
        cat = t["category"].is_a?(String) && t["category"].present? ? t["category"] : "Uncategorized"
        month = t["transaction_date"].to_s.slice(0, 7) rescue nil
        next unless month && months_list.include?(month)

        monthly_cat_data[cat] ||= {}
        monthly_cat_data[cat][month] = (monthly_cat_data[cat][month] || 0) + t["_abs_amount"].to_f
        monthly_totals[month] = (monthly_totals[month] || 0) + t["_abs_amount"].to_f
      end

      # --- Monthly Accuracy: budget vs actual per month ---
      total_budgeted_monthly = budget_limits.values.sum
      @monthly_accuracy = months_list.map { |m|
        actual = monthly_totals[m] || 0
        if total_budgeted_monthly > 0
          deviation_pct = ((actual - total_budgeted_monthly) / total_budgeted_monthly * 100).round(1) rescue 0
          accuracy = [100 - deviation_pct.abs, 0].max.round(1)
        else
          deviation_pct = 0
          accuracy = 0
        end
        month_label = Date.parse("#{m}-01").strftime("%b %Y") rescue m
        { month: m, label: month_label, actual: actual.round(2), budgeted: total_budgeted_monthly.round(2), deviation_pct: deviation_pct, accuracy: accuracy }
      }

      # --- Category Accuracy ---
      @category_accuracy = []
      budget_limits.each do |cat_name, budgeted|
        next if budgeted <= 0
        actuals = months_list.map { |m| (monthly_cat_data[cat_name] || {})[m] || 0 }
        active_months = actuals.count { |v| v > 0 }
        avg_actual = active_months > 0 ? actuals.sum / active_months : 0

        deviation_pct = ((avg_actual - budgeted) / budgeted * 100).round(1) rescue 0
        accuracy = [100 - deviation_pct.abs, 0].max.round(1)
        grade = accuracy_grade(accuracy)

        # Volatility: standard deviation of monthly spending
        mean = actuals.sum / [actuals.size, 1].max.to_f
        variance = actuals.map { |v| (v - mean) ** 2 }.sum / [actuals.size, 1].max.to_f
        volatility = (Math.sqrt(variance) rescue 0).round(2)
        volatility_pct = mean > 0 ? (volatility / mean * 100).round(1) : 0

        # Utilization rate
        utilization = (avg_actual / budgeted * 100).round(1) rescue 0

        @category_accuracy << {
          category: cat_name,
          budgeted: budgeted.round(2),
          avg_actual: avg_actual.round(2),
          deviation_pct: deviation_pct,
          accuracy: accuracy,
          grade: grade,
          volatility: volatility,
          volatility_pct: volatility_pct,
          utilization: utilization,
          monthly_actuals: actuals
        }
      end
      @category_accuracy.sort_by! { |c| -c[:accuracy] }

      # --- Overall Accuracy Score (weighted by budget amount) ---
      total_weight = @category_accuracy.sum { |c| c[:budgeted] }
      @overall_accuracy = if total_weight > 0
        weighted = @category_accuracy.sum { |c| c[:accuracy] * c[:budgeted] }
        (weighted / total_weight).round(1)
      else
        0
      end
      @overall_grade = accuracy_grade(@overall_accuracy)

      # --- Over-budget categories (consistently over budget) ---
      @over_budget_categories = @category_accuracy.select { |c| c[:deviation_pct] > 5 }
        .sort_by { |c| -c[:deviation_pct] }

      # --- Under-budget categories (overestimated) ---
      @under_budget_categories = @category_accuracy.select { |c| c[:deviation_pct] < -15 }
        .sort_by { |c| c[:deviation_pct] }

      # --- Improvement Trend: compare first 3 months accuracy to last 3 months ---
      if months_list.size >= 6 && total_budgeted_monthly > 0
        first_half = months_list.first(3).map { |m|
          actual = monthly_totals[m] || 0
          [100 - ((actual - total_budgeted_monthly).abs / total_budgeted_monthly * 100), 0].max
        }
        second_half = months_list.last(3).map { |m|
          actual = monthly_totals[m] || 0
          [100 - ((actual - total_budgeted_monthly).abs / total_budgeted_monthly * 100), 0].max
        }
        first_avg = first_half.sum / [first_half.size, 1].max
        second_avg = second_half.sum / [second_half.size, 1].max
        @improvement_delta = (second_avg - first_avg).round(1)
        @is_improving = @improvement_delta > 2
      else
        @improvement_delta = 0
        @is_improving = false
      end

      # --- Surprise Expenses: large transactions likely unbudgeted ---
      all_budget_cats = budget_limits.keys.map(&:downcase)
      @surprise_expenses = recent_expenses.select { |t|
        cat = (t["category"] || "").downcase
        amt = t["_abs_amount"].to_f
        amt > 200 && !all_budget_cats.any? { |bc| cat.include?(bc) || bc.include?(cat) }
      }.sort_by { |t| -t["_abs_amount"].to_f }
        .first(10)
        .map { |t|
          {
            date: t["transaction_date"],
            description: t["description"] || t["name"] || "Unknown",
            category: t["category"] || "Uncategorized",
            amount: t["_abs_amount"].to_f.round(2)
          }
        }

      # --- Recommendations ---
      @recommendations = []
      @over_budget_categories.each do |c|
        suggested = (c[:avg_actual] * 1.1).round(2)
        @recommendations << {
          category: c[:category],
          type: :increase,
          message: "Increase budget from #{number_to_currency(c[:budgeted])} to #{number_to_currency(suggested)}",
          current: c[:budgeted],
          suggested: suggested
        }
      end
      @under_budget_categories.each do |c|
        suggested = (c[:avg_actual] * 1.15).round(2)
        @recommendations << {
          category: c[:category],
          type: :decrease,
          message: "Decrease budget from #{number_to_currency(c[:budgeted])} to #{number_to_currency(suggested)}",
          current: c[:budgeted],
          suggested: suggested
        }
      end

      # Chart data for monthly accuracy
      @chart_months = @monthly_accuracy
      @chart_max = [
        @monthly_accuracy.map { |m| [m[:actual], m[:budgeted]].max }.max || 1,
        1
      ].max
    end

    def spending_watchdog
      # Fetch data defensively
      raw_transactions = begin
        result = budget_client.transactions(per_page: 1000)
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      rescue => e
        Rails.logger.warn("Watchdog: transactions fetch failed: #{e.message}")
        []
      end

      @budgets = begin
        result = budget_client.budgets rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["budgets"] || result["data"] || []) : [])
      rescue => e
        Rails.logger.warn("Watchdog: budgets fetch failed: #{e.message}")
        []
      end

      @existing_alerts = begin
        result = budget_client.alerts rescue []
        result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["alerts"] || []) : [])
      rescue => e
        Rails.logger.warn("Watchdog: alerts fetch failed: #{e.message}")
        []
      end

      today = Date.current
      month_start = today.beginning_of_month
      days_elapsed = [(today - month_start).to_i, 1].max
      days_in_month = (month_start.end_of_month - month_start).to_i + 1
      month_fraction = days_elapsed.to_f / days_in_month

      # Only consider expense transactions
      transactions = raw_transactions.select { |t| t["transaction_type"] != "income" }
      all_transactions = transactions # keep for historical analysis

      # Current month transactions
      current_month_txns = transactions.select { |t|
        d = t["transaction_date"].to_s
        d >= month_start.to_s && d <= today.to_s
      }

      # Category spending this month
      category_spending = Hash.new(0.0)
      current_month_txns.each do |t|
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        category_spending[cat] += t["amount"].to_f
      end

      # Historical category averages (from all transactions, grouped by month)
      category_monthly = Hash.new { |h, k| h[k] = Hash.new(0.0) }
      transactions.each do |t|
        month_key = t["transaction_date"].to_s.slice(0, 7)
        next unless month_key
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        category_monthly[cat][month_key] += t["amount"].to_f
      end

      # Build budget lookup: category => budgeted amount
      budget_lookup = {}
      @budgets.each do |b|
        cats = b["categories"] || b["budget_categories"] || []
        cats.each do |bc|
          cat_name = bc["name"] || bc["category"] || ""
          items = bc["items"] || bc["budget_items"] || []
          items.each do |item|
            budget_lookup[cat_name] ||= 0
            budget_lookup[cat_name] += (item["budgeted"] || item["amount"] || 0).to_f
          end
          # Also check category-level budgeted amount
          if items.empty? && (bc["budgeted"].to_f > 0 || bc["amount"].to_f > 0)
            budget_lookup[cat_name] ||= 0
            budget_lookup[cat_name] += (bc["budgeted"] || bc["amount"] || 0).to_f
          end
        end
      end

      @alerts = []

      # === 1. BUDGET PACE ALERTS ===
      @pace_data = []
      budget_lookup.each do |cat, budgeted|
        next if budgeted <= 0
        spent = category_spending[cat] || 0
        projected = month_fraction > 0 ? (spent / month_fraction) : spent
        pace_pct = budgeted > 0 ? (projected / budgeted * 100).round(1) : 0
        days_until_exhausted = spent > 0 ? ((budgeted - spent) / (spent.to_f / days_elapsed)).round(1) : nil
        exhausted_date = days_until_exhausted && days_until_exhausted > 0 ? (today + days_until_exhausted.to_i) : nil

        @pace_data << {
          category: cat,
          budgeted: budgeted,
          spent: spent,
          projected: projected,
          pace_pct: pace_pct,
          days_until_exhausted: days_until_exhausted,
          exhausted_date: exhausted_date
        }

        if pace_pct > 120
          @alerts << {
            type: :budget_pace,
            severity: :danger,
            title: "#{cat} on pace to exceed budget by #{(pace_pct - 100).round(0)}%",
            message: "Spent #{number_to_currency(spent)} of #{number_to_currency(budgeted)} budget with #{days_in_month - days_elapsed} days remaining. Projected: #{number_to_currency(projected)}.",
            amount: projected - budgeted,
            category: cat,
            date: today
          }
        elsif pace_pct > 100
          @alerts << {
            type: :budget_pace,
            severity: :warning,
            title: "#{cat} slightly over pace",
            message: "Trending #{(pace_pct - 100).round(0)}% above budget. Spent #{number_to_currency(spent)} of #{number_to_currency(budgeted)}.",
            amount: projected - budgeted,
            category: cat,
            date: today
          }
        end
      end
      @pace_data.sort_by! { |p| -(p[:pace_pct] || 0) }

      # === 2. UNUSUAL SPENDING (>2 std deviations above category average) ===
      current_month_txns.each do |t|
        cat = t["category"] || t["budget_category"] || "Uncategorized"
        amount = t["amount"].to_f
        cat_txns = transactions.select { |tx|
          (tx["category"] || tx["budget_category"] || "Uncategorized") == cat
        }.map { |tx| tx["amount"].to_f }
        next if cat_txns.size < 3

        avg = cat_txns.sum / cat_txns.size
        variance = cat_txns.sum { |v| (v - avg) ** 2 } / cat_txns.size
        std_dev = Math.sqrt(variance)
        next if std_dev == 0

        z_score = (amount - avg) / std_dev
        if z_score > 2
          @alerts << {
            type: :unusual_spending,
            severity: z_score > 3 ? :danger : :warning,
            title: "Unusual #{cat} transaction: #{number_to_currency(amount)}",
            message: "This is #{z_score.round(1)}x standard deviations above your average of #{number_to_currency(avg)} for #{cat}.",
            amount: amount,
            category: cat,
            date: t["transaction_date"]
          }
        end
      end

      # === 3. NEW MERCHANT ALERTS ===
      historical_merchants = Set.new
      transactions.each do |t|
        d = t["transaction_date"].to_s
        merchant = (t["merchant"] || t["payee"] || "").strip.downcase
        next if merchant.empty?
        historical_merchants << merchant if d < month_start.to_s
      end

      current_month_txns.each do |t|
        merchant = (t["merchant"] || t["payee"] || "").strip
        next if merchant.empty?
        unless historical_merchants.include?(merchant.downcase)
          @alerts << {
            type: :new_merchant,
            severity: :info,
            title: "New merchant: #{merchant}",
            message: "First time spending at #{merchant}. Amount: #{number_to_currency(t['amount'].to_f)}.",
            amount: t["amount"].to_f,
            category: t["category"] || t["budget_category"] || "Uncategorized",
            date: t["transaction_date"]
          }
        end
      end

      # === 4. FREQUENCY ALERTS (high transaction frequency this week) ===
      this_week_start = today.beginning_of_week
      this_week_txns = transactions.select { |t| t["transaction_date"].to_s >= this_week_start.to_s && t["transaction_date"].to_s <= today.to_s }
      # Compare to average weekly count over last 3 months
      three_months_ago = (today - 90).to_s
      recent_txns = transactions.select { |t| t["transaction_date"].to_s >= three_months_ago && t["transaction_date"].to_s < this_week_start.to_s }
      weeks_count = [((this_week_start - (today - 90)).to_f / 7).ceil, 1].max
      avg_weekly = recent_txns.size.to_f / weeks_count

      if avg_weekly > 0 && this_week_txns.size > avg_weekly * 1.5
        @alerts << {
          type: :frequency,
          severity: :warning,
          title: "High transaction frequency this week",
          message: "#{this_week_txns.size} transactions this week vs your average of #{avg_weekly.round(0)} per week.",
          amount: this_week_txns.sum { |t| t["amount"].to_f },
          category: "All",
          date: today
        }
      end

      # === 5. LARGE TRANSACTION ALERTS (top 5% threshold) ===
      all_amounts = transactions.map { |t| t["amount"].to_f }.sort
      if all_amounts.size >= 10
        threshold_idx = (all_amounts.size * 0.95).to_i
        threshold = all_amounts[threshold_idx] || all_amounts.last
        current_month_txns.each do |t|
          amount = t["amount"].to_f
          next unless amount >= threshold
          @alerts << {
            type: :large_transaction,
            severity: :warning,
            title: "Large transaction: #{number_to_currency(amount)}",
            message: "#{t['merchant'] || t['payee'] || t['description'] || 'Unknown'} — this is in the top 5% of all your transactions.",
            amount: amount,
            category: t["category"] || t["budget_category"] || "Uncategorized",
            date: t["transaction_date"]
          }
        end
      end

      # === 6. RECURRING CHANGES (detect changes in recurring bill amounts) ===
      merchant_amounts = Hash.new { |h, k| h[k] = [] }
      transactions.each do |t|
        merchant = (t["merchant"] || t["payee"] || "").strip
        next if merchant.empty?
        merchant_amounts[merchant] << { amount: t["amount"].to_f, date: t["transaction_date"].to_s }
      end

      merchant_amounts.each do |merchant, entries|
        next if entries.size < 3
        sorted = entries.sort_by { |e| e[:date] }
        latest = sorted.last
        previous = sorted[0...-1].map { |e| e[:amount] }
        avg_prev = previous.sum / previous.size
        next if avg_prev == 0
        change_pct = ((latest[:amount] - avg_prev) / avg_prev * 100).round(1)
        if change_pct.abs > 15
          @alerts << {
            type: :recurring_change,
            severity: change_pct > 0 ? :warning : :info,
            title: "#{merchant} bill changed #{change_pct > 0 ? 'up' : 'down'} #{change_pct.abs}%",
            message: "Latest charge: #{number_to_currency(latest[:amount])} vs average #{number_to_currency(avg_prev)}.",
            amount: latest[:amount],
            category: "Recurring",
            date: latest[:date]
          }
        end
      end

      # === 7. CATEGORY BURN RATE ===
      @burn_rates = []
      budget_lookup.each do |cat, budgeted|
        next if budgeted <= 0
        spent = category_spending[cat] || 0
        remaining = budgeted - spent
        daily_rate = days_elapsed > 0 ? (spent.to_f / days_elapsed) : 0
        days_left = daily_rate > 0 ? (remaining / daily_rate).round(1) : nil
        exhausted_date = days_left && days_left > 0 ? (today + days_left.to_i) : nil
        pct_used = (spent / budgeted * 100).round(1)
        @burn_rates << {
          category: cat,
          budgeted: budgeted,
          spent: spent,
          remaining: remaining,
          daily_rate: daily_rate,
          days_left: days_left,
          exhausted_date: exhausted_date,
          pct_used: pct_used
        }
      end
      @burn_rates.sort_by! { |b| b[:days_left] || 999 }

      # === 8. NO-ACTIVITY ALERTS ===
      budget_lookup.each do |cat, budgeted|
        next if budgeted <= 0
        spent = category_spending[cat] || 0
        if spent == 0 && days_elapsed > 7
          @alerts << {
            type: :no_activity,
            severity: :info,
            title: "No spending in #{cat}",
            message: "#{cat} has a #{number_to_currency(budgeted)} budget but zero spending #{days_elapsed} days into the month. Transactions may be missing.",
            amount: 0,
            category: cat,
            date: today
          }
        end
      end

      # === 9. POSITIVE ALERTS (under budget) ===
      @positive_alerts = []
      budget_lookup.each do |cat, budgeted|
        next if budgeted <= 0
        spent = category_spending[cat] || 0
        projected = month_fraction > 0 ? (spent / month_fraction) : spent
        pace_pct = budgeted > 0 ? (projected / budgeted * 100).round(1) : 0
        if pace_pct < 70 && spent > 0
          savings = budgeted - projected
          @positive_alerts << {
            type: :positive,
            severity: :info,
            title: "#{cat} well under budget",
            message: "On pace to spend only #{number_to_currency(projected)} of #{number_to_currency(budgeted)} — saving #{number_to_currency(savings)}!",
            amount: savings,
            category: cat,
            date: today,
            pace_pct: pace_pct
          }
        end
      end
      @positive_alerts.sort_by! { |a| a[:pace_pct] || 0 }

      # Sort alerts: danger first, then warning, then info; then by recency
      severity_order = { danger: 0, warning: 1, info: 2 }
      @alerts.sort_by! { |a| [severity_order[a[:severity]] || 3, -(a[:date].to_s.tr("-", "").to_i)] }

      # Stats
      @danger_count = @alerts.count { |a| a[:severity] == :danger }
      @warning_count = @alerts.count { |a| a[:severity] == :warning }
      @info_count = @alerts.count { |a| a[:severity] == :info }
      @total_alerts = @alerts.size
      @good_news_count = @positive_alerts.size
    end

    private

    def score_to_grade(score)
      case score
      when 90..100 then "A"
      when 80..89 then "B"
      when 65..79 then "C"
      when 50..64 then "D"
      else "F"
      end
    end

    def accuracy_grade(accuracy)
      case accuracy
      when 90..Float::INFINITY then "A"
      when 80...90 then "B"
      when 65...80 then "C"
      when 50...65 then "D"
      else "F"
      end
    end

    def calculate_risk_score
      score = 50 # Start at 50

      # More months covered = lower risk
      score -= (@months_covered * 10).to_i.clamp(0, 30)

      # High expenses relative to income = higher risk
      if @avg_monthly_income > 0
        expense_ratio = @avg_monthly_expenses / @avg_monthly_income
        score += (expense_ratio > 0.8 ? 20 : expense_ratio > 0.6 ? 10 : 0)
      else
        score += 20
      end

      # Low savings rate = higher risk
      if @monthly_savings <= 0
        score += 15
      elsif @monthly_savings < @avg_monthly_expenses * 0.1
        score += 10
      end

      score.clamp(0, 100)
    end

    def estimate_payoff_months(debts, monthly_payment)
      return 0 if debts.empty? || monthly_payment <= 0

      balances = debts.map { |d| { balance: d["current_balance"].to_f, rate: d["interest_rate"].to_f, min: d["minimum_payment"].to_f } }
      months = 0
      max_months = 360

      while balances.any? { |b| b[:balance] > 0 } && months < max_months
        months += 1
        remaining_extra = monthly_payment - balances.sum { |b| b[:balance] > 0 ? b[:min] : 0 }

        balances.each do |b|
          next if b[:balance] <= 0
          interest = b[:balance] * b[:rate] / 100 / 12
          b[:balance] += interest
          payment = b[:min]
          b[:balance] -= payment
          b[:balance] = 0 if b[:balance] < 0
        end

        # Apply extra to highest-rate debt
        if remaining_extra > 0
          target = balances.select { |b| b[:balance] > 0 }.max_by { |b| b[:rate] }
          if target
            target[:balance] -= remaining_extra
            target[:balance] = 0 if target[:balance] < 0
          end
        end
      end

      months
    end

    def estimate_total_interest(debts, monthly_payment)
      return 0 if debts.empty? || monthly_payment <= 0

      balances = debts.map { |d| { balance: d["current_balance"].to_f, rate: d["interest_rate"].to_f, min: d["minimum_payment"].to_f } }
      total_interest = 0
      months = 0

      while balances.any? { |b| b[:balance] > 0 } && months < 360
        months += 1
        remaining_extra = monthly_payment - balances.sum { |b| b[:balance] > 0 ? b[:min] : 0 }

        balances.each do |b|
          next if b[:balance] <= 0
          interest = b[:balance] * b[:rate] / 100 / 12
          total_interest += interest
          b[:balance] += interest
          b[:balance] -= b[:min]
          b[:balance] = 0 if b[:balance] < 0
        end

        if remaining_extra > 0
          target = balances.select { |b| b[:balance] > 0 }.max_by { |b| b[:rate] }
          if target
            target[:balance] -= remaining_extra
            target[:balance] = 0 if target[:balance] < 0
          end
        end
      end

      total_interest.round(2)
    end

    def compute_single_payoff_months(balance, rate, payment)
      return 0 if balance <= 0 || payment <= 0
      b = balance
      months = 0
      while b > 0 && months < 600
        months += 1
        interest = b * rate / 100.0 / 12.0
        b += interest
        b -= payment
        b = 0 if b < 0.01
      end
      months
    end

    def compute_single_total_interest(balance, rate, payment)
      return 0 if balance <= 0 || payment <= 0
      b = balance
      total = 0
      months = 0
      while b > 0 && months < 600
        months += 1
        interest = b * rate / 100.0 / 12.0
        total += interest
        b += interest
        b -= payment
        b = 0 if b < 0.01
      end
      total.round(2)
    end

    def simulate_strategy(ordered_debts, total_payment)
      return { months: 0, total_interest: 0, milestones: [] } if ordered_debts.empty?
      balances = ordered_debts.map { |d|
        { name: d["name"] || "Unknown", balance: d["current_balance"].to_f, rate: d["interest_rate"].to_f, min: d["minimum_payment"].to_f }
      }
      months = 0
      total_interest = 0
      milestones = []

      while balances.any? { |b| b[:balance] > 0 } && months < 600
        months += 1
        active_mins = balances.select { |b| b[:balance] > 0 }.sum { |b| b[:min] }
        extra = [total_payment - active_mins, 0].max

        balances.each do |b|
          next if b[:balance] <= 0
          interest = b[:balance] * b[:rate] / 100.0 / 12.0
          total_interest += interest
          b[:balance] += interest
          b[:balance] -= b[:min]
          b[:balance] = 0 if b[:balance] < 0.01
        end

        # Apply extra to first active debt in priority order
        target = balances.find { |b| b[:balance] > 0 }
        if target && extra > 0
          target[:balance] -= extra
          target[:balance] = 0 if target[:balance] < 0.01
        end

        # Check for newly paid-off debts
        balances.each do |b|
          if b[:balance] <= 0 && !milestones.any? { |m| m[:name] == b[:name] }
            milestones << { name: b[:name], month: months, date: Date.current >> months }
          end
        end
      end

      { months: months, total_interest: total_interest.round(2), milestones: milestones }
    end

    def build_payoff_timeline(debts)
      return [] if debts.empty?
      total_payment = debts.sum { |d| d["minimum_payment"].to_f }
      balances = debts.map { |d|
        { name: d["name"] || "Unknown", balance: d["current_balance"].to_f, rate: d["interest_rate"].to_f, min: d["minimum_payment"].to_f, history: [d["current_balance"].to_f] }
      }
      months = 0
      max_months = [estimate_payoff_months(debts, total_payment), 360].min
      sample_interval = [max_months / 24, 1].max

      while balances.any? { |b| b[:balance] > 0 } && months < max_months
        months += 1
        active_mins = balances.select { |b| b[:balance] > 0 }.sum { |b| b[:min] }
        extra = [total_payment - active_mins, 0].max

        balances.each do |b|
          next if b[:balance] <= 0
          interest = b[:balance] * b[:rate] / 100.0 / 12.0
          b[:balance] += interest
          b[:balance] -= b[:min]
          b[:balance] = 0 if b[:balance] < 0.01
        end

        target = balances.select { |b| b[:balance] > 0 }.max_by { |b| b[:rate] }
        if target && extra > 0
          target[:balance] -= extra
          target[:balance] = 0 if target[:balance] < 0.01
        end

        if months % sample_interval == 0 || months == max_months || balances.none? { |b| b[:balance] > 0 }
          balances.each { |b| b[:history] << [b[:balance], 0].max.round(2) }
        end
      end

      balances.map { |b| { name: b[:name], history: b[:history] } }
    end
  end
end
