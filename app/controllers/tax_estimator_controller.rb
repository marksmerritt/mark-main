class TaxEstimatorController < ApplicationController
  before_action :require_api_connection

  include ActionView::Helpers::NumberHelper

  def show
    @year = (params[:year] || Date.current.year).to_i
    year_start = "#{@year}-01-01"
    year_end = "#{@year}-12-31"

    threads = {}
    threads[:trades] = Thread.new {
      result = api_client.trades(per_page: 5000, status: "closed")
      all = result.is_a?(Hash) ? (result["trades"] || []) : Array(result)
      all.select { |t|
        exit_date = (t["exit_time"] || "").to_s.slice(0, 10)
        exit_date >= year_start && exit_date <= year_end
      }
    }

    @trades = threads[:trades].value

    # Filing status & income params
    @filing_status = params[:filing_status] || "single"
    @other_income = (params[:other_income] || 0).to_f
    @deductions = (params[:deductions] || standard_deduction(@filing_status)).to_f

    # Classify trades by holding period
    @short_term = []
    @long_term = []

    @trades.each do |t|
      pnl = t["pnl"].to_f
      entry_time = t["entry_time"].present? ? (Time.parse(t["entry_time"]) rescue nil) : nil
      exit_time = t["exit_time"].present? ? (Time.parse(t["exit_time"]) rescue nil) : nil

      if entry_time && exit_time
        days_held = ((exit_time - entry_time) / 86400).to_i
        if days_held > 365
          @long_term << t.merge("days_held" => days_held)
        else
          @short_term << t.merge("days_held" => days_held)
        end
      else
        # Default to short-term if can't determine
        @short_term << t.merge("days_held" => nil)
      end
    end

    @short_term_pnl = @short_term.sum { |t| t["pnl"].to_f }
    @long_term_pnl = @long_term.sum { |t| t["pnl"].to_f }
    @total_trading_pnl = @short_term_pnl + @long_term_pnl
    @total_fees = @trades.sum { |t| t["fees"].to_f }

    # Losses and carryover
    @net_gains = @total_trading_pnl
    @loss_deduction = if @net_gains < 0
      [3000, @net_gains.abs].min
    else
      0
    end
    @carryover_loss = @net_gains < 0 ? [0, @net_gains.abs - 3000].max : 0

    # Tax calculation
    @taxable_income = @other_income + [@short_term_pnl, 0].max - @deductions
    @taxable_income = [@taxable_income, 0].max

    @short_term_tax = calculate_tax(@taxable_income, @filing_status)
    @base_tax = calculate_tax([@other_income - @deductions, 0].max, @filing_status)
    @marginal_trading_tax = @short_term_tax - @base_tax

    # Long-term capital gains tax
    @lt_tax = calculate_lt_gains_tax([@long_term_pnl, 0].max, @taxable_income, @filing_status)

    @estimated_total_tax = @marginal_trading_tax + @lt_tax
    @effective_rate = @total_trading_pnl > 0 ? (@estimated_total_tax / @total_trading_pnl * 100).round(1) : 0
    @after_tax_pnl = @total_trading_pnl - @estimated_total_tax

    # Monthly P&L for tax planning
    @monthly_pnl = {}
    @trades.each do |t|
      month = (t["exit_time"] || "").to_s.slice(0, 7)
      next unless month.present?
      @monthly_pnl[month] ||= { short: 0, long: 0 }
      days = t["days_held"]
      if days && days > 365
        @monthly_pnl[month][:long] += t["pnl"].to_f
      else
        @monthly_pnl[month][:short] += t["pnl"].to_f
      end
    end

    # Top winners/losers for tax-loss harvesting awareness
    @biggest_winners = @trades.sort_by { |t| -t["pnl"].to_f }.first(5)
    @biggest_losers = @trades.sort_by { |t| t["pnl"].to_f }.first(5).select { |t| t["pnl"].to_f < 0 }

    # Wash sale warning candidates (losses followed by same symbol within 30 days)
    @wash_sale_warnings = []
    loss_trades = @trades.select { |t| t["pnl"].to_f < 0 }.sort_by { |t| t["exit_time"] || "" }
    loss_trades.each do |lt|
      exit_d = Date.parse(lt["exit_time"]) rescue nil
      next unless exit_d
      # Check if same symbol was bought within 30 days
      same_sym = @trades.select { |t|
        t["symbol"] == lt["symbol"] && t["id"] != lt["id"] &&
        t["entry_time"].present? && ((Date.parse(t["entry_time"]) rescue nil)&.between?(exit_d - 30, exit_d + 30))
      }
      if same_sym.any?
        @wash_sale_warnings << { symbol: lt["symbol"], loss: lt["pnl"].to_f, date: lt["exit_time"]&.to_s&.slice(0, 10) }
      end
    end
    @wash_sale_warnings.uniq! { |w| [w[:symbol], w[:date]] }
  end

  private

  def standard_deduction(filing_status)
    case filing_status
    when "married" then 29_200
    when "head_of_household" then 21_900
    else 14_600
    end
  end

  # 2024 federal brackets (simplified)
  def calculate_tax(income, filing_status)
    brackets = case filing_status
               when "married"
                 [[23_200, 0.10], [94_300, 0.12], [201_050, 0.22], [383_900, 0.24], [487_450, 0.32], [731_200, 0.35], [Float::INFINITY, 0.37]]
               when "head_of_household"
                 [[16_550, 0.10], [63_100, 0.12], [100_500, 0.22], [191_950, 0.24], [243_725, 0.32], [609_350, 0.35], [Float::INFINITY, 0.37]]
               else # single
                 [[11_600, 0.10], [47_150, 0.12], [100_525, 0.22], [191_950, 0.24], [243_725, 0.32], [609_350, 0.35], [Float::INFINITY, 0.37]]
               end

    tax = 0
    prev_limit = 0
    remaining = income

    brackets.each do |limit, rate|
      bracket_size = limit - prev_limit
      taxable_in_bracket = [remaining, bracket_size].min
      tax += taxable_in_bracket * rate
      remaining -= taxable_in_bracket
      prev_limit = limit
      break if remaining <= 0
    end

    tax.round(2)
  end

  def calculate_lt_gains_tax(gains, income, filing_status)
    thresholds = case filing_status
                 when "married" then [89_250, 553_850]
                 when "head_of_household" then [59_750, 523_050]
                 else [47_025, 518_900]
                 end

    if income <= thresholds[0]
      0
    elsif income <= thresholds[1]
      (gains * 0.15).round(2)
    else
      (gains * 0.20).round(2)
    end
  end
end
