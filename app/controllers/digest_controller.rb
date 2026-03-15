class DigestController < ApplicationController
  include ActionView::Helpers::NumberHelper

  def show
    @week_offset = params[:week].to_i
    @week_start = Date.current.beginning_of_week(:monday) - @week_offset.weeks
    @week_end = @week_start + 6.days

    threads = {}

    if api_token.present?
      threads[:weekly] = Thread.new {
        api_client.api_weekly_summary(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s
        )
      }
      threads[:trades] = Thread.new {
        result = api_client.trades(
          start_date: @week_start.to_s,
          end_date: (@week_end + 1.day).to_s,
          per_page: 100,
          status: "closed"
        )
        result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      }
      threads[:journal] = Thread.new {
        result = api_client.journal_entries(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s
        )
        result.is_a?(Hash) ? (result["journal_entries"] || []) : Array(result)
      }
      threads[:prev_weekly] = Thread.new {
        prev_start = @week_start - 1.week
        prev_end = @week_end - 1.week
        api_client.api_weekly_summary(
          start_date: prev_start.to_s,
          end_date: prev_end.to_s
        )
      }
    end

    if notes_api_token.present?
      threads[:notes] = Thread.new {
        result = notes_client.notes(per_page: 50, sort: "updated_at_desc")
        all = result.is_a?(Hash) ? (result["notes"] || []) : Array(result)
        all.select { |n|
          updated = n["updated_at"] || n["created_at"]
          next false unless updated
          date = Date.parse(updated.to_s) rescue nil
          date && date >= @week_start && date <= @week_end
        }
      }
    end

    if budget_api_token.present?
      threads[:budget] = Thread.new {
        budget_client.budget_overview(
          month: @week_start.month,
          year: @week_start.year
        )
      }
      threads[:transactions] = Thread.new {
        result = budget_client.transactions(
          start_date: @week_start.to_s,
          end_date: @week_end.to_s,
          per_page: 200
        )
        result.is_a?(Hash) ? (result["transactions"] || []) : Array(result)
      }
    end

    @weekly_stats = threads[:weekly]&.value || {}
    @week_trades = threads[:trades]&.value || []
    @journal_entries = threads[:journal]&.value || []
    @prev_weekly = threads[:prev_weekly]&.value || {}
    @week_notes = threads[:notes]&.value || []
    @budget_overview = threads[:budget]&.value || {}
    @week_transactions = threads[:transactions]&.value || []

    compute_highlights
  end

  private

  def compute_highlights
    @highlights = []

    if @weekly_stats.present? && !@weekly_stats["error"]
      pnl = @weekly_stats["total_pnl"].to_f
      trades = @weekly_stats["total_trades"].to_i
      win_rate = @weekly_stats["win_rate"].to_f

      if pnl > 0
        @highlights << { icon: "trending_up", type: "positive", text: "Profitable week: #{number_to_currency(pnl)} across #{trades} trades" }
      elsif trades > 0
        @highlights << { icon: "trending_down", type: "negative", text: "Tough week: #{number_to_currency(pnl)} across #{trades} trades" }
      end

      if win_rate >= 60 && trades >= 3
        @highlights << { icon: "stars", type: "positive", text: "Strong #{win_rate}% win rate this week" }
      end

      prev_pnl = @prev_weekly["total_pnl"].to_f
      if prev_pnl != 0 && pnl != 0
        improvement = ((pnl - prev_pnl) / prev_pnl.abs * 100).round(1)
        if improvement > 20
          @highlights << { icon: "arrow_upward", type: "positive", text: "P&L improved #{improvement}% vs last week" }
        end
      end
    end

    if @journal_entries.count >= 5
      @highlights << { icon: "auto_stories", type: "info", text: "#{@journal_entries.count} journal entries — strong journaling discipline" }
    end

    if @week_notes.count >= 3
      @highlights << { icon: "description", type: "info", text: "#{@week_notes.count} notes created or updated" }
    end

    if @week_transactions.any?
      total_spent = @week_transactions.select { |t| t["transaction_type"] != "income" }.sum { |t| t["amount"].to_f }
      if total_spent > 0
        @highlights << { icon: "payments", type: "neutral", text: "#{number_to_currency(total_spent)} spent across #{@week_transactions.count} transactions" }
      end
    end
  end
end
