module Budget
  class ReportsController < ApplicationController
    before_action :require_budget_connection

    def spending
      month = (params[:month] || Date.current.month).to_i
      year = (params[:year] || Date.current.year).to_i

      threads = {}
      threads[:categories] = Thread.new { budget_client.spending_by_category(month: month, year: year) }
      threads[:trends] = Thread.new { budget_client.spending_trends(months: 6) }
      threads[:overview] = Thread.new { budget_client.budget_overview(month: month, year: year) }

      @categories = threads[:categories].value
      @trends = threads[:trends].value
      @overview = threads[:overview].value
      @month = month
      @year = year
    end

    def net_worth
      threads = {}
      threads[:net_worth] = Thread.new { budget_client.net_worth }
      threads[:timeline] = Thread.new { budget_client.net_worth_timeline }
      @net_worth = threads[:net_worth].value
      @timeline = threads[:timeline].value
    end

    def income_vs_expenses
      months = (params[:months] || 12).to_i
      @data = budget_client.income_vs_expenses(months: months)
    end

    def merchants
      months = (params[:months] || 3).to_i
      @data = budget_client.merchant_insights(months: months)
      @months = months
    end

    def insights
      month = (params[:month] || Date.current.month).to_i
      year = (params[:year] || Date.current.year).to_i
      @data = budget_client.spending_insights(month: month, year: year)
      @month = month
      @year = year
    end

    def forecast
      month = (params[:month] || Date.current.month).to_i
      year = (params[:year] || Date.current.year).to_i
      @data = budget_client.forecast(month: month, year: year)
      @month = month
      @year = year
    end

    def take_snapshot
      budget_client.take_net_worth_snapshot
      redirect_to budget_reports_net_worth_path, notice: "Net worth snapshot saved."
    end

    def digest
      month = (params[:month] || Date.current.month).to_i
      year = (params[:year] || Date.current.year).to_i
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview(month: month, year: year) }
      threads[:categories] = Thread.new { budget_client.spending_by_category(month: month, year: year) }
      threads[:forecast] = Thread.new { budget_client.forecast(month: month, year: year) }
      threads[:debt] = Thread.new { budget_client.debt_overview }
      threads[:net_worth] = Thread.new { budget_client.net_worth }
      threads[:goals] = Thread.new { budget_client.goals(status: "active") }
      @overview = threads[:overview].value
      @categories = threads[:categories].value
      @forecast = threads[:forecast].value
      @debt = threads[:debt].value
      @net_worth = threads[:net_worth].value
      @goals = threads[:goals].value
      @goals = [] unless @goals.is_a?(Array)
      @month = month
      @year = year
    end

    def year_over_year
      month = (params[:month] || Date.current.month).to_i
      year = (params[:year] || Date.current.year).to_i
      @data = budget_client.year_over_year(month: month, year: year)
      @month = month
      @year = year
    end

    def comparison
      @month1 = (params[:month1] || Date.current.month).to_i
      @year1 = (params[:year1] || Date.current.year).to_i
      prev = Date.new(@year1, @month1, 1) - 1.month
      @month2 = (params[:month2] || prev.month).to_i
      @year2 = (params[:year2] || prev.year).to_i

      @data = budget_client.budget_comparison(
        month1: @month1, year1: @year1,
        month2: @month2, year2: @year2
      )
    end

    def cash_flow
      months = (params[:months] || 6).to_i
      threads = {}
      threads[:cash_flow] = Thread.new { budget_client.cash_flow(months: months) }
      threads[:overview] = Thread.new { budget_client.budget_overview }
      @data = threads[:cash_flow].value
      @overview = threads[:overview].value
      @months = months
    end

    def spending_velocity
      @month = (params[:month] || Date.current.month).to_i
      @year = (params[:year] || Date.current.year).to_i
      @month_start = Date.new(@year, @month, 1)
      @month_end = @month_start.end_of_month
      @today = Date.current
      @day_of_month = [@today.day, @month_end.day].min
      @total_days = @month_end.day
      @days_remaining = [(@month_end - @today).to_i, 0].max
      @pct_through_month = (@day_of_month.to_f / @total_days * 100).round(1)

      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview(month: @month, year: @year) rescue {} }
      threads[:categories] = Thread.new { budget_client.spending_by_category(month: @month, year: @year) rescue {} }
      threads[:transactions] = Thread.new {
        budget_client.transactions(month: @month, year: @year, per_page: 500) rescue {}
      }
      threads[:prev_overview] = Thread.new {
        prev = @month_start - 1.month
        budget_client.budget_overview(month: prev.month, year: prev.year) rescue {}
      }

      overview = threads[:overview].value
      @overview = overview.is_a?(Hash) ? overview : {}
      cat_result = threads[:categories].value
      @categories = cat_result.is_a?(Hash) ? (cat_result["categories"] || []) : (cat_result.is_a?(Array) ? cat_result : [])

      txn_result = threads[:transactions].value
      transactions = if txn_result.is_a?(Hash)
                       txn_result["transactions"] || []
                     elsif txn_result.is_a?(Array)
                       txn_result
                     else
                       []
                     end

      prev_overview = threads[:prev_overview].value
      @prev_overview = prev_overview.is_a?(Hash) ? prev_overview : {}

      # Budget and spending totals
      @total_budgeted = @overview["total_budgeted"].to_f
      @total_spent = @overview["total_spent"].to_f
      @total_remaining = @total_budgeted - @total_spent
      @budget_used_pct = @total_budgeted > 0 ? (@total_spent / @total_budgeted * 100).round(1) : 0

      # Daily spending rate
      @daily_rate = @day_of_month > 0 ? (@total_spent / @day_of_month).round(2) : 0
      @ideal_daily_rate = @total_days > 0 ? (@total_budgeted / @total_days).round(2) : 0
      @projected_spend = @daily_rate * @total_days
      @projected_over_under = @total_budgeted - @projected_spend

      # Velocity status
      @velocity_ratio = @ideal_daily_rate > 0 ? (@daily_rate / @ideal_daily_rate).round(2) : 0
      @velocity_status = if @velocity_ratio <= 0.85 then "Under Budget"
                         elsif @velocity_ratio <= 1.05 then "On Track"
                         elsif @velocity_ratio <= 1.20 then "Watch Closely"
                         else "Over Budget"
                         end
      @velocity_color = case @velocity_status
                        when "Under Budget" then "var(--positive)"
                        when "On Track" then "#1a73e8"
                        when "Watch Closely" then "#f9ab00"
                        else "var(--negative)"
                        end

      # Daily spending accumulation for chart
      @daily_spending = {}
      transactions.select { |t| t["transaction_type"] == "expense" }.each do |t|
        date = t["transaction_date"].to_s.slice(0, 10)
        next unless date.present?
        day = Date.parse(date).day rescue nil
        next unless day
        @daily_spending[day] = (@daily_spending[day] || 0) + t["amount"].to_f
      end

      # Build cumulative curve
      @cumulative = []
      running = 0
      (1..@total_days).each do |d|
        running += @daily_spending[d].to_f
        @cumulative << { day: d, spent: running.round(2) } if d <= @day_of_month
      end

      # Safe daily spend for remainder
      @safe_daily_spend = @days_remaining > 0 ? (@total_remaining / @days_remaining).round(2) : 0

      # Category velocity
      @category_velocity = @categories.map { |cat|
        budgeted = cat["budgeted"].to_f
        spent = cat["spent"].to_f
        pct_used = budgeted > 0 ? (spent / budgeted * 100).round(1) : 0
        pace = pct_used - @pct_through_month
        {
          name: cat["name"],
          budgeted: budgeted,
          spent: spent,
          remaining: budgeted - spent,
          pct_used: pct_used,
          pace: pace.round(1),
          status: pace > 15 ? "over" : pace > 0 ? "watch" : "under"
        }
      }.sort_by { |c| -(c[:pct_used]) }

      # Previous month comparison
      @prev_spent = @prev_overview["total_spent"].to_f
      @prev_budgeted = @prev_overview["total_budgeted"].to_f
      @mom_change = @prev_spent > 0 ? ((@total_spent - @prev_spent) / @prev_spent * 100).round(1) : 0
    end

    def annual_review
      @year = (params[:year] || Date.current.year).to_i

      threads = {}
      threads[:income_expenses] = Thread.new { budget_client.income_vs_expenses(months: 12) rescue {} }
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }
      threads[:nw_timeline] = Thread.new { budget_client.net_worth_timeline rescue {} }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:goals] = Thread.new { budget_client.goals rescue [] }
      threads[:transactions] = Thread.new {
        budget_client.transactions(year: @year, per_page: 2000) rescue {}
      }
      threads[:recurring] = Thread.new { budget_client.recurring_transactions rescue [] }

      ie_data = threads[:income_expenses].value
      ie_data = {} unless ie_data.is_a?(Hash)
      @months = ie_data["months"] || ie_data["data"] || []
      @months = [] unless @months.is_a?(Array)

      @net_worth = threads[:net_worth].value || {}
      @nw_timeline = threads[:nw_timeline].value || {}

      debt_result = threads[:debt].value
      @debts = if debt_result.is_a?(Hash)
                 debt_result["debt_accounts"] || debt_result["debts"] || []
               elsif debt_result.is_a?(Array)
                 debt_result
               else
                 []
               end

      goals_result = threads[:goals].value
      @goals = goals_result.is_a?(Array) ? goals_result : []

      txn_result = threads[:transactions].value
      @transactions = if txn_result.is_a?(Hash)
                        txn_result["transactions"] || []
                      elsif txn_result.is_a?(Array)
                        txn_result
                      else
                        []
                      end

      recurring_result = threads[:recurring].value
      @recurring = if recurring_result.is_a?(Array)
                     recurring_result
                   elsif recurring_result.is_a?(Hash)
                     recurring_result["recurring_transactions"] || recurring_result["items"] || []
                   else
                     []
                   end

      # Annual totals
      @total_income = @months.sum { |m| m["income"].to_f }
      @total_expenses = @months.sum { |m| m["expenses"].to_f }
      @total_saved = @total_income - @total_expenses
      @savings_rate = @total_income > 0 ? (@total_saved / @total_income * 100).round(1) : 0
      @avg_monthly_income = @months.any? ? (@total_income / @months.count).round(2) : 0
      @avg_monthly_expense = @months.any? ? (@total_expenses / @months.count).round(2) : 0

      # Best and worst months
      @best_month = @months.max_by { |m| m["income"].to_f - m["expenses"].to_f }
      @worst_month = @months.min_by { |m| m["income"].to_f - m["expenses"].to_f }

      # Merchant spending breakdown
      @top_merchants = {}
      @transactions.each do |t|
        next unless t["transaction_type"] == "expense"
        merchant = t["merchant"].presence || "Unknown"
        @top_merchants[merchant] ||= { total: 0, count: 0 }
        @top_merchants[merchant][:total] += t["amount"].to_f
        @top_merchants[merchant][:count] += 1
      end
      @top_merchants = @top_merchants.sort_by { |_, d| -d[:total] }.first(10).to_h

      # Monthly spending trend for chart
      @monthly_data = @months.map { |m|
        { month: m["month"] || m["label"], income: m["income"].to_f, expenses: m["expenses"].to_f }
      }

      # Goals summary
      @completed_goals = @goals.count { |g| g["status"] == "completed" }
      @active_goals = @goals.count { |g| g["status"] == "active" }
      @total_goal_progress = @goals.sum { |g| g["current_amount"].to_f }

      # Recurring cost
      freq_mult = { "weekly" => 52, "biweekly" => 26, "monthly" => 12, "quarterly" => 4, "annually" => 1 }
      @annual_recurring = @recurring.sum { |r| r["amount"].to_f * (freq_mult[r["frequency"]] || 12) }

      # Debt paid down
      @total_debt = @debts.sum { |d| d["current_balance"].to_f }
      @total_original_debt = @debts.sum { |d| d["original_balance"].to_f }
      @debt_paid = @total_original_debt - @total_debt
    end

    def subscription_audit
      threads = {}
      threads[:recurring] = Thread.new { budget_client.recurring_transactions rescue [] }
      threads[:summary] = Thread.new { budget_client.recurring_summary rescue {} }

      result = threads[:recurring].value
      @items = result.is_a?(Array) ? result : (result.is_a?(Hash) ? (result["recurring_transactions"] || result["items"] || []) : [])
      @summary = threads[:summary].value
      @summary = {} unless @summary.is_a?(Hash)

      freq_multiplier = { "weekly" => 52, "biweekly" => 26, "monthly" => 12, "quarterly" => 4, "annually" => 1 }

      @audit_items = @items.map do |item|
        mult = freq_multiplier[item["frequency"]] || 12
        annual = item["amount"].to_f * mult
        monthly = annual / 12.0
        {
          id: item["id"],
          name: item["name"],
          merchant: item["merchant"],
          amount: item["amount"].to_f,
          frequency: item["frequency"],
          category: item["category_name"],
          annual: annual,
          monthly: monthly,
          next_due: item["next_due"]
        }
      end.sort_by { |i| -i[:annual] }

      @total_annual = @audit_items.sum { |i| i[:annual] }
      @total_monthly = @total_annual / 12.0

      # Cost tiers
      @tiers = {
        high: @audit_items.select { |i| i[:monthly] >= 50 },
        medium: @audit_items.select { |i| i[:monthly] >= 15 && i[:monthly] < 50 },
        low: @audit_items.select { |i| i[:monthly] < 15 }
      }

      # Category breakdown
      @by_category = @audit_items.group_by { |i| i[:category] || "Uncategorized" }
        .transform_values { |items| { count: items.count, annual: items.sum { |i| i[:annual] } } }
        .sort_by { |_, v| -v[:annual] }
    end

    def category_drill
      @category = params[:category].presence || "All"
      @months_back = (params[:months] || 6).to_i

      threads = {}
      threads[:transactions] = Thread.new {
        budget_client.transactions(months: @months_back, per_page: 2000) rescue {}
      }
      threads[:categories] = Thread.new {
        budget_client.spending_by_category(month: Date.current.month, year: Date.current.year) rescue {}
      }

      txn_result = threads[:transactions].value
      all_transactions = if txn_result.is_a?(Hash)
                           txn_result["transactions"] || []
                         elsif txn_result.is_a?(Array)
                           txn_result
                         else
                           []
                         end

      cat_result = threads[:categories].value
      categories = if cat_result.is_a?(Hash)
                     cat_result["categories"] || []
                   elsif cat_result.is_a?(Array)
                     cat_result
                   else
                     []
                   end

      # Collect all category names for the filter dropdown
      @all_categories = all_transactions
        .filter_map { |t| t["category_name"].presence }
        .uniq
        .sort

      # Filter transactions to category
      transactions = if @category == "All"
                       all_transactions.select { |t| t["transaction_type"] == "expense" }
                     else
                       all_transactions.select { |t|
                         t["transaction_type"] == "expense" && t["category_name"] == @category
                       }
                     end

      @total_spent = transactions.sum { |t| t["amount"].to_f }
      @transaction_count = transactions.count
      @avg_transaction = @transaction_count > 0 ? (@total_spent / @transaction_count).round(2) : 0

      # Monthly breakdown
      @monthly = {}
      transactions.each do |t|
        date = t["transaction_date"].to_s.slice(0, 7) # "YYYY-MM"
        next unless date.present?
        @monthly[date] ||= { total: 0, count: 0, transactions: [] }
        @monthly[date][:total] += t["amount"].to_f
        @monthly[date][:count] += 1
        @monthly[date][:transactions] << t
      end
      @monthly = @monthly.sort.to_h
      @monthly.each { |_, d| d[:total] = d[:total].round(2) }

      # Trend direction
      if @monthly.count >= 2
        values = @monthly.values.map { |d| d[:total] }
        first_half = values[0...values.count / 2]
        second_half = values[values.count / 2..]
        first_avg = first_half.any? ? first_half.sum / first_half.count : 0
        second_avg = second_half.any? ? second_half.sum / second_half.count : 0
        @trend_pct = first_avg > 0 ? ((second_avg - first_avg) / first_avg * 100).round(1) : 0
        @trend_direction = @trend_pct > 5 ? "increasing" : (@trend_pct < -5 ? "decreasing" : "stable")
      end

      # Top merchants in this category
      @top_merchants = {}
      transactions.each do |t|
        merchant = t["merchant"].presence || t["description"].presence || "Unknown"
        @top_merchants[merchant] ||= { total: 0, count: 0 }
        @top_merchants[merchant][:total] += t["amount"].to_f
        @top_merchants[merchant][:count] += 1
      end
      @top_merchants = @top_merchants
        .sort_by { |_, d| -d[:total] }
        .first(15)
        .map { |name, d| { name: name, total: d[:total].round(2), count: d[:count], avg: (d[:total] / d[:count]).round(2) } }

      # Day of week distribution
      @by_day = Hash.new(0)
      transactions.each do |t|
        date = Date.parse(t["transaction_date"]) rescue nil
        next unless date
        @by_day[date.strftime("%A")] += t["amount"].to_f
      end
      @by_day = @by_day.transform_values { |v| v.round(2) }

      # Largest transactions
      @largest = transactions.sort_by { |t| -t["amount"].to_f }.first(10)

      # Budget vs actual (if specific category)
      if @category != "All"
        cat_info = categories.find { |c| c["name"] == @category }
        @budgeted = cat_info ? cat_info["budgeted"].to_f : 0
        @category_spent = cat_info ? cat_info["spent"].to_f : @total_spent
        @pct_used = @budgeted > 0 ? (@category_spent / @budgeted * 100).round(1) : 0
      end

      # Average monthly spend
      @avg_monthly = @monthly.any? ? (@monthly.values.sum { |d| d[:total] } / @monthly.count).round(2) : 0
      @max_month = @monthly.max_by { |_, d| d[:total] }
      @min_month = @monthly.min_by { |_, d| d[:total] }
    end

    def income_tracker
      @months_back = (params[:months] || 12).to_i

      threads = {}
      threads[:ie] = Thread.new { budget_client.income_vs_expenses(months: @months_back) rescue {} }
      threads[:transactions] = Thread.new {
        budget_client.transactions(months: @months_back, per_page: 2000) rescue {}
      }
      threads[:overview] = Thread.new { budget_client.budget_overview rescue {} }
      threads[:recurring] = Thread.new { budget_client.recurring_transactions rescue [] }

      ie_result = threads[:ie].value
      ie_data = ie_result.is_a?(Hash) ? ie_result : {}
      @months_data = ie_data["months"] || ie_data["data"] || []
      @months_data = [] unless @months_data.is_a?(Array)

      txn_result = threads[:transactions].value
      all_transactions = if txn_result.is_a?(Hash)
                           txn_result["transactions"] || []
                         elsif txn_result.is_a?(Array)
                           txn_result
                         else
                           []
                         end

      @overview = threads[:overview].value
      @overview = {} unless @overview.is_a?(Hash)

      recurring_result = threads[:recurring].value
      @recurring = if recurring_result.is_a?(Array)
                     recurring_result
                   elsif recurring_result.is_a?(Hash)
                     recurring_result["recurring_transactions"] || recurring_result["items"] || []
                   else
                     []
                   end

      # Income transactions only
      income_txns = all_transactions.select { |t| t["transaction_type"] == "income" }

      # Totals
      @total_income = income_txns.sum { |t| t["amount"].to_f }
      @total_expenses = all_transactions
        .select { |t| t["transaction_type"] == "expense" }
        .sum { |t| t["amount"].to_f }
      @income_count = income_txns.count
      @savings = @total_income - @total_expenses
      @savings_rate = @total_income > 0 ? (@savings / @total_income * 100).round(1) : 0

      # Monthly income chart data
      @monthly_income = {}
      income_txns.each do |t|
        month = t["transaction_date"].to_s.slice(0, 7)
        next unless month.present?
        @monthly_income[month] ||= { total: 0, sources: Hash.new(0) }
        @monthly_income[month][:total] += t["amount"].to_f
        source = t["merchant"].presence || t["description"].presence || "Other"
        @monthly_income[month][:sources][source] += t["amount"].to_f
      end
      @monthly_income = @monthly_income.sort.to_h

      @avg_monthly_income = @monthly_income.any? ?
        (@monthly_income.values.sum { |d| d[:total] } / @monthly_income.count).round(2) : 0

      # Income sources breakdown
      @income_sources = {}
      income_txns.each do |t|
        source = t["merchant"].presence || t["description"].presence || "Other"
        @income_sources[source] ||= { total: 0, count: 0, months: Set.new }
        @income_sources[source][:total] += t["amount"].to_f
        @income_sources[source][:count] += 1
        month = t["transaction_date"].to_s.slice(0, 7)
        @income_sources[source][:months] << month if month.present?
      end
      @income_sources = @income_sources
        .sort_by { |_, d| -d[:total] }
        .map { |name, d|
          frequency = if d[:months].count >= @months_back * 0.8
                        "Regular"
                      elsif d[:months].count >= 3
                        "Recurring"
                      else
                        "One-time"
                      end
          {
            name: name,
            total: d[:total].round(2),
            count: d[:count],
            avg: (d[:total] / d[:count]).round(2),
            months_active: d[:months].count,
            frequency: frequency,
            monthly_avg: d[:months].any? ? (d[:total] / d[:months].count).round(2) : 0
          }
        }

      # Recurring income
      @recurring_income = @recurring.select { |r|
        r["transaction_type"] == "income" || r["type"] == "income"
      }
      freq_mult = { "weekly" => 52, "biweekly" => 26, "monthly" => 12, "quarterly" => 4, "annually" => 1 }
      @annual_recurring_income = @recurring_income.sum { |r|
        r["amount"].to_f * (freq_mult[r["frequency"]] || 12)
      }
      @monthly_recurring_income = @annual_recurring_income / 12.0

      # Income stability (coefficient of variation)
      if @monthly_income.count >= 3
        incomes = @monthly_income.values.map { |d| d[:total] }
        mean = incomes.sum / incomes.count
        stddev = Math.sqrt(incomes.map { |i| (i - mean) ** 2 }.sum / incomes.count)
        @income_cv = mean > 0 ? (stddev / mean * 100).round(1) : 0
        @income_stability = if @income_cv < 10
                               "Very Stable"
                             elsif @income_cv < 25
                               "Stable"
                             elsif @income_cv < 50
                               "Variable"
                             else
                               "Highly Variable"
                             end
      end

      # Best / worst income months
      @best_income_month = @monthly_income.max_by { |_, d| d[:total] }
      @worst_income_month = @monthly_income.min_by { |_, d| d[:total] }

      # YoY income change (if 12+ months of data)
      if @months_data.count >= 12
        recent_6 = @months_data.last(6).sum { |m| m["income"].to_f }
        prior_6 = @months_data[-12..-7]&.sum { |m| m["income"].to_f } || 0
        @yoy_change = prior_6 > 0 ? ((recent_6 - prior_6) / prior_6 * 100).round(1) : 0
      end
    end

    def net_worth_details
      threads = {}
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }
      threads[:timeline] = Thread.new { budget_client.net_worth_timeline rescue {} }
      threads[:debt] = Thread.new { budget_client.debt_overview rescue {} }
      threads[:goals] = Thread.new { budget_client.goals rescue [] }

      nw = threads[:net_worth].value
      @net_worth = nw.is_a?(Hash) ? nw : {}

      tl = threads[:timeline].value
      @timeline = tl.is_a?(Hash) ? tl : {}
      @snapshots = (@timeline["snapshots"] || @timeline["timeline"] || [])
      @snapshots = [] unless @snapshots.is_a?(Array)

      debt_result = threads[:debt].value
      @debts = if debt_result.is_a?(Hash)
                 debt_result["debt_accounts"] || debt_result["debts"] || []
               elsif debt_result.is_a?(Array)
                 debt_result
               else
                 []
               end

      goals_result = threads[:goals].value
      @goals = goals_result.is_a?(Array) ? goals_result : []

      # Net worth summary
      @total_assets = @net_worth["total_assets"].to_f
      @total_liabilities = @net_worth["total_liabilities"].to_f
      @net_worth_amount = @total_assets - @total_liabilities
      @assets = @net_worth["assets"] || []
      @assets = [] unless @assets.is_a?(Array)
      @liabilities = @net_worth["liabilities"] || @debts

      # Net worth change from timeline
      if @snapshots.count >= 2
        latest = @snapshots.last
        previous = @snapshots[-2]
        @nw_change = (latest["net_worth"].to_f - previous["net_worth"].to_f).round(2)
        @nw_change_pct = previous["net_worth"].to_f > 0 ?
          ((@nw_change / previous["net_worth"].to_f) * 100).round(1) : 0

        first = @snapshots.first
        @nw_all_time_change = (latest["net_worth"].to_f - first["net_worth"].to_f).round(2)
      end

      # Debt-to-asset ratio
      @debt_to_asset = @total_assets > 0 ? (@total_liabilities / @total_assets * 100).round(1) : 0

      # Goal contributions to net worth
      @goals_total = @goals.sum { |g| g["effective_current_amount"].to_f }
      @goals_target = @goals.sum { |g| g["effective_target_amount"].to_f }
    end

    def bill_tracker
      threads = {}
      threads[:recurring] = Thread.new { budget_client.recurring_transactions rescue [] }
      threads[:transactions] = Thread.new { budget_client.transactions(months: 12, per_page: 2000) rescue {} }

      recurring_result = threads[:recurring].value
      @items = if recurring_result.is_a?(Array)
                 recurring_result
               elsif recurring_result.is_a?(Hash)
                 recurring_result["recurring_transactions"] || recurring_result["items"] || []
               else
                 []
               end

      txn_result = threads[:transactions].value
      all_transactions = if txn_result.is_a?(Hash)
                           txn_result["transactions"] || []
                         elsif txn_result.is_a?(Array)
                           txn_result
                         else
                           []
                         end

      expenses = all_transactions.select { |t| t["transaction_type"] == "expense" }

      # Build merchant spending averages for recent 6 months vs prior 6 months
      now = Date.current
      six_months_ago = now - 6.months
      twelve_months_ago = now - 12.months

      merchant_periods = {}
      expenses.each do |t|
        date = Date.parse(t["transaction_date"]) rescue nil
        next unless date
        merchant = (t["merchant"].presence || t["description"].presence || "").downcase.strip
        next if merchant.blank?
        merchant_periods[merchant] ||= { recent: [], prior: [] }
        if date >= six_months_ago
          merchant_periods[merchant][:recent] << t["amount"].to_f
        elsif date >= twelve_months_ago
          merchant_periods[merchant][:prior] << t["amount"].to_f
        end
      end

      # Category classification
      essential_keywords = %w[rent mortgage electric gas water sewer trash insurance
        medical doctor pharmacy childcare tuition loan payment tax property]
      luxury_keywords = %w[spa golf club resort wine premium vip first-class]

      freq_multiplier = { "weekly" => 52, "biweekly" => 26, "monthly" => 12, "quarterly" => 4, "annually" => 1 }

      @bills = @items.map do |item|
        mult = freq_multiplier[item["frequency"]] || 12
        monthly = item["amount"].to_f * mult / 12.0
        annual = item["amount"].to_f * mult
        name = item["name"] || ""
        category_name = (item["category_name"] || "").downcase
        name_lower = name.downcase

        # Classify essential / discretionary / luxury
        classification = if essential_keywords.any? { |kw| name_lower.include?(kw) || category_name.include?(kw) }
                           "essential"
                         elsif luxury_keywords.any? { |kw| name_lower.include?(kw) || category_name.include?(kw) }
                           "luxury"
                         else
                           "discretionary"
                         end

        # Price change detection
        merchant_key = (item["merchant"].presence || item["name"] || "").downcase.strip
        periods = merchant_periods[merchant_key]
        price_change_pct = 0
        old_avg = 0
        new_avg = 0
        if periods && periods[:recent].any? && periods[:prior].any?
          old_avg = (periods[:prior].sum / periods[:prior].count).round(2)
          new_avg = (periods[:recent].sum / periods[:recent].count).round(2)
          price_change_pct = old_avg > 0 ? ((new_avg - old_avg) / old_avg * 100).round(1) : 0
        end

        # Negotiation score (0-100)
        score = 0
        score += 25 if classification == "discretionary"
        score += 35 if classification == "luxury"
        score += 20 if price_change_pct > 5   # price went up
        score += 10 if price_change_pct > 15   # price went up a lot
        score += 15 if annual > 500            # high cost
        score += 10 if annual > 1000
        # Long tenure bonus: if we have prior period data, user has been paying 6+ months
        score += 10 if periods && periods[:prior].any?
        score = [score, 100].min

        # Bill type for tips
        bill_type = if name_lower.match?(/internet|broadband|fiber|comcast|xfinity|spectrum|att|at&t/)
                      "internet"
                    elsif name_lower.match?(/insurance|geico|allstate|progressive|state farm/)
                      "insurance"
                    elsif name_lower.match?(/phone|mobile|cell|verizon|tmobile|t-mobile|sprint/)
                      "phone"
                    elsif name_lower.match?(/netflix|hulu|disney|hbo|spotify|apple music|youtube|streaming|paramount|peacock/)
                      "streaming"
                    elsif name_lower.match?(/gym|fitness|peloton|planet|crossfit/)
                      "gym"
                    elsif name_lower.match?(/electric|gas|water|utility|power|energy/)
                      "utility"
                    elsif name_lower.match?(/cable|satellite|directv|dish/)
                      "cable"
                    elsif name_lower.match?(/rent|mortgage|hoa/)
                      "housing"
                    elsif name_lower.match?(/loan|credit|debt/)
                      "loan"
                    else
                      "other"
                    end

        {
          id: item["id"],
          name: name,
          merchant: item["merchant"],
          amount: item["amount"].to_f,
          frequency: item["frequency"],
          category: item["category_name"],
          classification: classification,
          monthly: monthly.round(2),
          annual: annual.round(2),
          price_change_pct: price_change_pct,
          old_avg: old_avg,
          new_avg: new_avg,
          negotiation_score: score,
          bill_type: bill_type,
          next_due: item["next_due"]
        }
      end.sort_by { |b| -b[:negotiation_score] }

      # Summary stats
      @total_annual_cost = @bills.sum { |b| b[:annual] }
      @total_monthly_cost = @total_annual_cost / 12.0

      # Top negotiation candidates: bills scoring 30+ that aren't essential housing/loan
      negotiable = @bills.select { |b| b[:negotiation_score] >= 30 && !%w[housing loan].include?(b[:bill_type]) }
      @negotiation_potential = (negotiable.sum { |b| b[:annual] } * 0.15).round(2)

      # Price increases
      @price_increases = @bills.select { |b| b[:price_change_pct] > 2 }.sort_by { |b| -b[:price_change_pct] }

      # Cancellation candidates: discretionary or luxury with low monthly cost or low frequency use
      @cancellation_candidates = @bills.select { |b|
        b[:classification] != "essential" && b[:negotiation_score] >= 20
      }.sort_by { |b| -b[:annual] }

      # Negotiation tips by bill type
      @negotiation_tips = {
        "internet" => [
          "Call and mention competitor pricing — providers often have retention deals.",
          "Ask about promotional rates for existing customers.",
          "Consider downgrading speed if you don't need the highest tier.",
          "Bundle or unbundle services depending on which saves more."
        ],
        "insurance" => [
          "Shop around annually — loyalty rarely pays with insurance.",
          "Bundle home and auto for multi-policy discounts.",
          "Raise your deductible to lower premiums (if you have an emergency fund).",
          "Ask about discounts: safe driver, paperless, autopay, alumni groups."
        ],
        "phone" => [
          "Compare MVNOs (Mint, Visible, Cricket) — same networks, lower prices.",
          "Call and ask for loyalty/retention discounts.",
          "Review your data usage — you might be overpaying for unused data.",
          "Consider prepaid plans if you're out of contract."
        ],
        "streaming" => [
          "Rotate services instead of subscribing to all simultaneously.",
          "Check for annual plans — often 15-20% cheaper than monthly.",
          "Share family plans with household members.",
          "Look for bundled deals (e.g., Disney+/Hulu/ESPN+)."
        ],
        "gym" => [
          "Negotiate at signup — month-end and January are best times.",
          "Ask about corporate or group discounts.",
          "Consider freezing instead of canceling if you'll return.",
          "Compare with budget gyms or home workout alternatives."
        ],
        "utility" => [
          "Enroll in budget billing to smooth out seasonal spikes.",
          "Check for low-income assistance programs or senior discounts.",
          "Audit energy usage — smart thermostats pay for themselves quickly.",
          "Compare electricity providers if your state allows choice."
        ],
        "cable" => [
          "Threaten to cancel — retention departments offer the best deals.",
          "Cut the cord: streaming bundles often cost less than cable.",
          "Negotiate every year when your promotional rate expires.",
          "Return rented equipment and buy your own modem/router."
        ],
        "other" => [
          "Always ask: 'Is there a discount available?' — many companies have unadvertised deals.",
          "Set a calendar reminder to review each bill annually.",
          "Check if your credit card offers statement credits for subscriptions.",
          "Use services like Trim or Rocket Money to find forgotten subscriptions."
        ]
      }

      @bills_with_increases_count = @price_increases.count
    end

    def spending_patterns
      @months_back = (params[:months] || 3).to_i

      txn_result = budget_client.transactions(months: @months_back, per_page: 2000) rescue {}
      all_transactions = if txn_result.is_a?(Hash)
                           txn_result["transactions"] || []
                         elsif txn_result.is_a?(Array)
                           txn_result
                         else
                           []
                         end

      expenses = all_transactions.select { |t| t["transaction_type"] == "expense" }
      @total_spent = expenses.sum { |t| t["amount"].to_f }
      @transaction_count = expenses.count

      # Day of week spending
      @by_day = {}
      %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].each { |d| @by_day[d] = { total: 0, count: 0 } }
      expenses.each do |t|
        date = Date.parse(t["transaction_date"]) rescue nil
        next unless date
        day = date.strftime("%A")
        @by_day[day][:total] += t["amount"].to_f
        @by_day[day][:count] += 1
      end
      @by_day.each { |_, d| d[:avg] = d[:count] > 0 ? (d[:total] / d[:count]).round(2) : 0; d[:total] = d[:total].round(2) }
      @biggest_spend_day = @by_day.max_by { |_, d| d[:total] }&.first
      @smallest_spend_day = @by_day.select { |_, d| d[:total] > 0 }.min_by { |_, d| d[:total] }&.first

      # Weekend vs weekday
      weekday_txns = expenses.select { |t| d = Date.parse(t["transaction_date"]) rescue nil; d && !d.saturday? && !d.sunday? }
      weekend_txns = expenses.select { |t| d = Date.parse(t["transaction_date"]) rescue nil; d && (d.saturday? || d.sunday?) }
      @weekday_total = weekday_txns.sum { |t| t["amount"].to_f }.round(2)
      @weekend_total = weekend_txns.sum { |t| t["amount"].to_f }.round(2)
      @weekday_avg = weekday_txns.any? ? (@weekday_total / weekday_txns.count).round(2) : 0
      @weekend_avg = weekend_txns.any? ? (@weekend_total / weekend_txns.count).round(2) : 0

      # Time-based spending (by week number within month)
      @by_week_of_month = { "Week 1" => 0, "Week 2" => 0, "Week 3" => 0, "Week 4+" => 0 }
      expenses.each do |t|
        date = Date.parse(t["transaction_date"]) rescue nil
        next unless date
        week = case date.day
               when 1..7 then "Week 1"
               when 8..14 then "Week 2"
               when 15..21 then "Week 3"
               else "Week 4+"
               end
        @by_week_of_month[week] += t["amount"].to_f
      end
      @by_week_of_month.transform_values! { |v| v.round(2) }

      # Transaction size distribution
      @size_buckets = {
        "Under $10" => { count: 0, total: 0 },
        "$10-$25" => { count: 0, total: 0 },
        "$25-$50" => { count: 0, total: 0 },
        "$50-$100" => { count: 0, total: 0 },
        "$100-$250" => { count: 0, total: 0 },
        "$250+" => { count: 0, total: 0 }
      }
      expenses.each do |t|
        amt = t["amount"].to_f
        bucket = case amt
                 when 0...10 then "Under $10"
                 when 10...25 then "$10-$25"
                 when 25...50 then "$25-$50"
                 when 50...100 then "$50-$100"
                 when 100...250 then "$100-$250"
                 else "$250+"
                 end
        @size_buckets[bucket][:count] += 1
        @size_buckets[bucket][:total] += amt
      end
      @size_buckets.each { |_, d| d[:total] = d[:total].round(2); d[:pct] = @transaction_count > 0 ? (d[:count].to_f / @transaction_count * 100).round(1) : 0 }

      # Spending velocity: daily spending over time
      @daily_spending = {}
      expenses.each do |t|
        date = t["transaction_date"].to_s.slice(0, 10)
        next unless date.present?
        @daily_spending[date] = (@daily_spending[date] || 0) + t["amount"].to_f
      end
      @daily_spending.transform_values! { |v| v.round(2) }
      @daily_spending = @daily_spending.sort.to_h

      @avg_daily = @daily_spending.any? ? (@daily_spending.values.sum / @daily_spending.count).round(2) : 0
      @max_day = @daily_spending.max_by { |_, v| v }
      @zero_spend_days = if @daily_spending.count >= 2
                           first = Date.parse(@daily_spending.keys.first)
                           last = Date.parse(@daily_spending.keys.last)
                           total_days = (last - first).to_i + 1
                           total_days - @daily_spending.count
                         else
                           0
                         end

      # Repeat merchant analysis
      merchant_counts = {}
      expenses.each do |t|
        merchant = t["merchant"].presence || t["description"].presence
        next unless merchant
        merchant_counts[merchant] ||= { count: 0, total: 0, dates: [] }
        merchant_counts[merchant][:count] += 1
        merchant_counts[merchant][:total] += t["amount"].to_f
        merchant_counts[merchant][:dates] << t["transaction_date"]
      end
      @repeat_merchants = merchant_counts
        .select { |_, d| d[:count] >= 3 }
        .sort_by { |_, d| -d[:count] }
        .first(10)
        .map { |name, d| { name: name, count: d[:count], total: d[:total].round(2), avg: (d[:total] / d[:count]).round(2) } }

      # Spending insights
      @patterns = []
      if @weekend_avg > @weekday_avg * 1.3
        @patterns << { icon: "weekend", text: "You spend #{((@weekend_avg / @weekday_avg - 1) * 100).round(0)}% more per transaction on weekends ($#{@weekend_avg} avg vs $#{@weekday_avg} weekday).", type: "info" }
      end
      if @biggest_spend_day && @smallest_spend_day
        @patterns << { icon: "calendar_month", text: "#{@biggest_spend_day}s are your biggest spending day ($#{@by_day[@biggest_spend_day][:total]}), while #{@smallest_spend_day}s are the lightest ($#{@by_day[@smallest_spend_day][:total]}).", type: "info" }
      end
      if @zero_spend_days > 0 && @daily_spending.count > 0
        pct = (@zero_spend_days.to_f / (@daily_spending.count + @zero_spend_days) * 100).round(0)
        @patterns << { icon: "savings", text: "You had #{@zero_spend_days} zero-spend days (#{pct}% of the period). No-spend days are a great savings habit!", type: "positive" }
      end
      small_pct = @size_buckets["Under $10"][:pct]
      if small_pct > 40
        @patterns << { icon: "coffee", text: "#{small_pct}% of your transactions are under $10. Small purchases add up — they total $#{@size_buckets['Under $10'][:total]}.", type: "warning" }
      end
    end
  end
end
