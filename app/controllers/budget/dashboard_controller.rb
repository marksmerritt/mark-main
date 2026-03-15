module Budget
  class DashboardController < ApplicationController
    include BudgetHelper
    before_action :require_budget_connection

    def calendar
      @month = (params[:month] || Date.current.month).to_i
      @year = (params[:year] || Date.current.year).to_i
      threads = {}
      threads[:recurring] = Thread.new { budget_client.recurring_transactions(active: "true") }
      threads[:goals] = Thread.new { budget_client.goals(status: "active") }
      threads[:challenges] = Thread.new { budget_client.savings_challenges(status: "active") }
      threads[:transactions] = Thread.new { budget_client.transactions(month: @month, year: @year) }
      @recurring = threads[:recurring].value
      @recurring = [] unless @recurring.is_a?(Array)
      @goals = threads[:goals].value
      @goals = [] unless @goals.is_a?(Array)
      @challenges = threads[:challenges].value
      @challenges = @challenges.is_a?(Array) ? @challenges : (@challenges.is_a?(Hash) ? (@challenges["challenges"] || []) : [])
      txn_result = threads[:transactions].value
      @transactions = txn_result.is_a?(Hash) ? (txn_result["transactions"] || []) : (txn_result.is_a?(Array) ? txn_result : [])
    end

    def allocate
      threads = {}
      threads[:budget] = Thread.new { budget_client.current_budget }
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }
      @budget = threads[:budget].value
      @funds = threads[:funds].value
      @funds = [] unless @funds.is_a?(Array)
      @paycheck = params[:amount].to_f
      @items = []
      if @budget.is_a?(Hash) && @budget["categories"].is_a?(Array)
        @budget["categories"].each do |cat|
          (cat["items"] || []).each do |item|
            remaining = item["remaining"].to_f
            @items << {
              category: cat["name"],
              name: item["name"],
              planned: item["planned_amount"].to_f,
              spent: item["actual_spent"].to_f,
              remaining: remaining
            }
          end
        end
      end
    end

    def apply_allocation
      amount = params[:paycheck_amount].to_f
      if amount <= 0
        redirect_to budget_calendar_path, alert: "Enter a valid paycheck amount."
        return
      end
      result = budget_client.create_transaction(
        amount: amount,
        description: params[:description].presence || "Paycheck",
        merchant: params[:merchant].presence || "Employer",
        transaction_type: "income",
        transaction_date: (params[:date].presence || Date.current).to_s,
        status: "cleared"
      )
      if result["id"]
        # Contribute to funds if specified
        (params[:fund_contributions] || {}).each do |fund_id, contrib_amount|
          next if contrib_amount.to_f.zero?
          budget_client.contribute_to_fund(fund_id, contrib_amount.to_f, note: "From paycheck")
        end
        redirect_to budget_dashboard_path, notice: "Paycheck of #{ActionController::Base.helpers.number_to_currency(amount)} recorded."
      else
        redirect_to budget_allocate_path(amount: amount), alert: "Failed to record: #{result['errors']&.join(', ') || result['message']}"
      end
    end

    def savings
      threads = {}
      threads[:funds] = Thread.new { budget_client.funds }
      threads[:goals] = Thread.new { budget_client.goals }
      threads[:challenges] = Thread.new { budget_client.savings_challenges }
      threads[:net_worth] = Thread.new { budget_client.net_worth rescue {} }

      fund_result = threads[:funds].value
      @funds = fund_result.is_a?(Array) ? fund_result : (fund_result.is_a?(Hash) ? (fund_result["funds"] || []) : [])

      goal_result = threads[:goals].value
      @goals = goal_result.is_a?(Array) ? goal_result : (goal_result.is_a?(Hash) ? (goal_result["goals"] || []) : [])

      challenge_result = threads[:challenges].value
      @challenges = challenge_result.is_a?(Array) ? challenge_result : (challenge_result.is_a?(Hash) ? (challenge_result["challenges"] || []) : [])

      @net_worth = threads[:net_worth].value
      @net_worth = {} unless @net_worth.is_a?(Hash)

      # Aggregate stats
      @total_saved = @funds.sum { |f| f["current_amount"].to_f }
      @total_goal_target = @goals.sum { |g| g["target_amount"].to_f }
      @total_goal_progress = @goals.sum { |g| g["current_amount"].to_f }
      @active_goals = @goals.count { |g| g["status"] == "active" }
      @completed_goals = @goals.count { |g| g["status"] == "completed" }
      @active_challenges = @challenges.count { |c| c["status"] == "active" }
      @total_challenge_saved = @challenges.sum { |c| c["current_amount"].to_f }

      @overall_saved = @total_saved + @total_goal_progress + @total_challenge_saved
    end

    def financial_calendar
      @month = (params[:month] || Date.current.month).to_i
      @year = (params[:year] || Date.current.year).to_i
      @start_date = Date.new(@year, @month, 1)
      @end_date = @start_date.end_of_month

      threads = {}
      threads[:transactions] = Thread.new { budget_client.transactions(month: @month, year: @year, per_page: 500) }
      threads[:recurring] = Thread.new { budget_client.recurring_transactions(active: "true") }
      threads[:goals] = Thread.new { budget_client.goals(status: "active") }
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }

      txn_result = threads[:transactions].value
      @transactions = txn_result.is_a?(Hash) ? (txn_result["transactions"] || []) : (txn_result.is_a?(Array) ? txn_result : [])

      @recurring = threads[:recurring].value
      @recurring = [] unless @recurring.is_a?(Array)

      goal_result = threads[:goals].value
      @goals = goal_result.is_a?(Array) ? goal_result : (goal_result.is_a?(Hash) ? (goal_result["goals"] || []) : [])

      fund_result = threads[:funds].value
      @funds = fund_result.is_a?(Array) ? fund_result : (fund_result.is_a?(Hash) ? (fund_result["funds"] || []) : [])

      # Build calendar_data keyed by day number
      @calendar_data = Hash.new { |h, k| h[k] = [] }

      # Transactions (actual income/expenses)
      @transactions.each do |txn|
        date = Date.parse(txn["transaction_date"]) rescue nil
        next unless date && date.month == @month && date.year == @year
        is_income = txn["transaction_type"] == "income"
        @calendar_data[date.day] << {
          type: is_income ? "income" : "expense",
          name: txn["merchant"].presence || txn["description"] || "Transaction",
          amount: txn["amount"].to_f,
          color: is_income ? "var(--positive, #22c55e)" : "var(--negative, #ef4444)"
        }
      end

      # Recurring bills
      (@start_date..@end_date).each do |date|
        calendar_bills_for_date(@recurring, date).each do |bill|
          @calendar_data[date.day] << {
            type: "bill",
            name: bill["name"] || bill["description"] || "Bill",
            amount: bill["amount"].to_f,
            color: "var(--primary, #6366f1)"
          }
        end
      end

      # Goals with deadlines this month
      @goals.each do |goal|
        next unless goal["target_date"].present?
        target = Date.parse(goal["target_date"]) rescue nil
        next unless target && target.month == @month && target.year == @year
        @calendar_data[target.day] << {
          type: "goal",
          name: goal["name"] || "Goal",
          amount: goal["remaining_amount"].to_f,
          color: "var(--purple, #a855f7)"
        }
      end

      # Fund contribution targets (funds with target dates this month)
      @funds.each do |fund|
        next unless fund["target_date"].present?
        target = Date.parse(fund["target_date"]) rescue nil
        next unless target && target.month == @month && target.year == @year
        remaining = fund["target_amount"].to_f - fund["current_amount"].to_f
        next if remaining <= 0
        @calendar_data[target.day] << {
          type: "goal",
          name: "Fund: #{fund['name']}",
          amount: remaining,
          color: "var(--purple, #a855f7)"
        }
      end

      # Monthly summary
      total_income = @transactions.select { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
      total_expenses = @transactions.reject { |t| t["transaction_type"] == "income" }.sum { |t| t["amount"].to_f }
      total_bills = 0
      (@start_date..@end_date).each do |date|
        total_bills += calendar_bills_for_date(@recurring, date).sum { |b| b["amount"].to_f }
      end

      @monthly_summary = {
        total_income: total_income,
        total_expenses: total_expenses,
        total_bills: total_bills,
        net: total_income - total_expenses - total_bills
      }
    end

    def index
      threads = {}
      threads[:overview] = Thread.new { budget_client.budget_overview(month: Date.current.month, year: Date.current.year) }
      threads[:budget] = Thread.new { budget_client.current_budget }
      threads[:debt] = Thread.new { budget_client.debt_overview }
      threads[:recurring] = Thread.new { budget_client.recurring_summary }
      threads[:net_worth] = Thread.new { budget_client.net_worth }
      threads[:funds] = Thread.new { budget_client.funds(status: "active") }
      threads[:trends] = Thread.new { budget_client.spending_trends(months: 6) }
      threads[:nw_timeline] = Thread.new { budget_client.net_worth_timeline rescue [] }
      threads[:recurring_items] = Thread.new { budget_client.recurring_transactions(active: "true") }
      threads[:categories] = Thread.new { budget_client.spending_by_category(month: Date.current.month, year: Date.current.year) }
      threads[:forecast] = Thread.new { budget_client.forecast(month: Date.current.month, year: Date.current.year) }
      threads[:alerts] = Thread.new { budget_client.alerts(unread: true) }
      threads[:recent_txns] = Thread.new {
        budget_client.transactions(
          start_date: (Date.current - 90.days).to_s,
          end_date: Date.current.to_s,
          per_page: 500,
          transaction_type: "expense"
        ) rescue {}
      }

      @overview = threads[:overview].value
      @budget = threads[:budget].value
      @debt = threads[:debt].value
      @recurring = threads[:recurring].value
      @net_worth = threads[:net_worth].value
      @funds = threads[:funds].value
      @trends = threads[:trends].value
      @recurring_items = threads[:recurring_items].value
      @categories = threads[:categories].value
      @forecast = threads[:forecast].value
      @alerts = threads[:alerts].value
      @nw_timeline = threads[:nw_timeline].value
      txn_result = threads[:recent_txns].value
      txns = txn_result.is_a?(Hash) ? (txn_result["transactions"] || []) : (txn_result.is_a?(Array) ? txn_result : [])
      @daily_spending = {}
      txns.each do |txn|
        date = txn["transaction_date"]
        next unless date.present?
        @daily_spending[date] ||= 0
        @daily_spending[date] += txn["amount"].to_f
      end
    end
  end
end
