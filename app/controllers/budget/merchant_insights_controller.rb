module Budget
  class MerchantInsightsController < ApplicationController
    before_action :require_budget_connection

    def index
      months = (params[:months] || 6).to_i
      @sort = params[:sort] || "total"
      @months = months

      threads = {}
      threads[:transactions] = Thread.new { budget_client.transactions(months: months, per_page: 1000) rescue {} }
      threads[:merchant_insights] = Thread.new { budget_client.merchant_insights(months: months) rescue {} }

      txn_result = threads[:transactions].value
      @transactions = if txn_result.is_a?(Hash)
                         txn_result["transactions"] || []
                       elsif txn_result.is_a?(Array)
                         txn_result
                       else
                         []
                       end

      insights_result = threads[:merchant_insights].value
      @api_insights = insights_result.is_a?(Hash) ? insights_result : {}

      build_merchant_analysis
    end

    private

    def build_merchant_analysis
      expenses = @transactions.select { |t| t["transaction_type"] == "expense" }

      # Group by merchant
      grouped = {}
      expenses.each do |t|
        merchant = t["merchant"].presence || "Unknown"
        grouped[merchant] ||= { transactions: [] }
        grouped[merchant][:transactions] << t
      end

      current_month = Date.current.beginning_of_month
      previous_months_start = current_month - @months.months

      @merchants = grouped.map do |name, data|
        txns = data[:transactions]
        amounts = txns.map { |t| t["amount"].to_f }
        dates = txns.map { |t| Date.parse(t["transaction_date"].to_s.slice(0, 10)) rescue nil }.compact.sort
        categories = txns.map { |t| t["category_name"].presence || "Uncategorized" }

        total = amounts.sum
        count = txns.count
        avg = count > 0 ? (total / count).round(2) : 0
        first_date = dates.first
        last_date = dates.last
        most_common_category = categories.tally.max_by { |_, v| v }&.first || "Uncategorized"

        # Top spending days of week
        day_totals = Hash.new(0)
        txns.each do |t|
          d = Date.parse(t["transaction_date"].to_s.slice(0, 10)) rescue nil
          next unless d
          day_totals[d.strftime("%A")] += t["amount"].to_f
        end
        top_days = day_totals.sort_by { |_, v| -v }.first(3).map(&:first)

        # Month-over-month trend
        monthly_totals = Hash.new(0)
        txns.each do |t|
          d = Date.parse(t["transaction_date"].to_s.slice(0, 10)) rescue nil
          next unless d
          key = d.strftime("%Y-%m")
          monthly_totals[key] += t["amount"].to_f
        end
        sorted_months = monthly_totals.sort_by(&:first)
        trend_pct = 0
        trend_direction = "flat"
        if sorted_months.length >= 2
          recent = sorted_months.last(2)
          prev_val = recent[0][1]
          curr_val = recent[1][1]
          if prev_val > 0
            trend_pct = ((curr_val - prev_val) / prev_val * 100).round(1)
            trend_direction = trend_pct > 5 ? "up" : trend_pct < -5 ? "down" : "flat"
          end
        end

        # Frequency classification
        if dates.length >= 2
          span_days = (dates.last - dates.first).to_i
          span_days = 1 if span_days == 0
          avg_gap = span_days.to_f / (dates.length - 1)
          frequency = if avg_gap <= 2
                        "daily"
                      elsif avg_gap <= 9
                        "weekly"
                      elsif avg_gap <= 18
                        "biweekly"
                      elsif avg_gap <= 45
                        "monthly"
                      elsif avg_gap <= 100
                        "quarterly"
                      else
                        "occasional"
                      end
        else
          frequency = "occasional"
        end

        # Is this a new merchant (first appeared in current month)?
        is_new = first_date && first_date >= current_month

        # Did merchant appear in current month?
        appeared_current = dates.any? { |d| d >= current_month }

        {
          name: name,
          total: total,
          count: count,
          avg: avg,
          first_date: first_date,
          last_date: last_date,
          category: most_common_category,
          top_days: top_days,
          trend_pct: trend_pct,
          trend_direction: trend_direction,
          frequency: frequency,
          is_new: is_new,
          appeared_current: appeared_current,
          monthly_totals: monthly_totals
        }
      end

      # Sort
      @merchants = case @sort
                   when "count"
                     @merchants.sort_by { |m| -m[:count] }
                   when "avg"
                     @merchants.sort_by { |m| -m[:avg] }
                   when "name"
                     @merchants.sort_by { |m| m[:name].downcase }
                   when "frequency"
                     freq_order = %w[daily weekly biweekly monthly quarterly occasional]
                     @merchants.sort_by { |m| freq_order.index(m[:frequency]) || 99 }
                   when "trend"
                     @merchants.sort_by { |m| -m[:trend_pct] }
                   else
                     @merchants.sort_by { |m| -m[:total] }
                   end

      # Overall stats
      @total_merchants = @merchants.count
      @total_spending = @merchants.sum { |m| m[:total] }
      @avg_per_merchant = @total_merchants > 0 ? (@total_spending / @total_merchants).round(2) : 0

      # Avg merchants per month
      merchant_months = Set.new
      expenses.each do |t|
        d = Date.parse(t["transaction_date"].to_s.slice(0, 10)) rescue nil
        next unless d
        merchant = t["merchant"].presence || "Unknown"
        merchant_months << "#{d.strftime('%Y-%m')}|#{merchant}"
      end
      month_keys = merchant_months.map { |mm| mm.split("|").first }.uniq
      @avg_merchants_per_month = month_keys.any? ? (merchant_months.count.to_f / month_keys.count).round(1) : 0

      # New merchants (first appeared in current month)
      @new_merchants = @merchants.select { |m| m[:is_new] }

      # Churned merchants (appeared in previous months but not current)
      @churned_merchants = @merchants.select { |m| !m[:appeared_current] && m[:first_date] && m[:first_date] < current_month }

      # Spending concentration (top 5 Pareto)
      top5_total = @merchants.sort_by { |m| -m[:total] }.first(5).sum { |m| m[:total] }
      @top5_concentration = @total_spending > 0 ? (top5_total / @total_spending * 100).round(1) : 0
    end
  end
end
