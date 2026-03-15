module BudgetHelper
  def budget_progress_class(percentage)
    case percentage.to_f
    when 0..50 then "progress-safe"
    when 50..80 then "progress-warning"
    when 80..100 then "progress-caution"
    else "progress-over"
    end
  end

  def budget_month_name(month, year = nil)
    date = Date.new(year || Date.current.year, month, 1)
    date.strftime("%B %Y")
  end

  def debt_type_label(type)
    {
      "credit_card" => "Credit Card",
      "student_loan" => "Student Loan",
      "car_loan" => "Car Loan",
      "personal_loan" => "Personal Loan",
      "mortgage" => "Mortgage",
      "medical" => "Medical",
      "other" => "Other"
    }[type] || type&.titleize
  end

  def frequency_label(freq)
    {
      "weekly" => "Weekly",
      "biweekly" => "Bi-weekly",
      "monthly" => "Monthly",
      "quarterly" => "Quarterly",
      "annually" => "Annually"
    }[freq] || freq&.titleize
  end

  def calendar_bills_for_date(items, date)
    items.select do |item|
      next false unless item["next_due"].present?
      due = Date.parse(item["next_due"]) rescue nil
      next false unless due

      case item["frequency"]
      when "weekly"
        date.wday == due.wday
      when "biweekly"
        date.wday == due.wday && ((date - due).to_i % 14).zero?
      when "monthly"
        date.day == due.day
      when "quarterly"
        date.day == due.day && ((date.month - due.month) % 3).zero?
      when "annually"
        date.day == due.day && date.month == due.month
      else
        date == due
      end
    end
  end

  def zero_based_indicator(budget)
    remaining = budget["remaining"].to_f
    if remaining.abs < 0.01
      content_tag(:span, "Zero-Based", class: "badge badge-success")
    elsif remaining > 0
      content_tag(:span, "#{number_to_currency(remaining)} unassigned", class: "badge badge-warning")
    else
      content_tag(:span, "#{number_to_currency(remaining.abs)} over", class: "badge badge-danger")
    end
  end

  def financial_health_score(overview:, budget:, debt:, net_worth:, recurring:)
    score = 0

    # Savings rate (0-25 points)
    savings_rate = overview&.dig("savings_rate").to_f
    score += if savings_rate >= 20 then 25
             elsif savings_rate >= 10 then 15
             elsif savings_rate >= 5 then 10
             elsif savings_rate > 0 then 5
             else 0
             end

    # Budget adherence (0-25 points)
    income = overview&.dig("budget_income").to_f
    spent = overview&.dig("total_spent").to_f
    if income > 0
      overage = ((spent - income) / income) * 100
      score += if overage <= 0 then 25
               elsif overage <= 10 then 15
               else 5
               end
    end

    # Debt-to-income ratio (0-25 points)
    total_debt_payments = debt&.dig("total_minimum_payments").to_f
    if income > 0
      dti = (total_debt_payments / income) * 100
      score += if total_debt_payments == 0 then 25
               elsif dti < 20 then 20
               elsif dti <= 35 then 15
               elsif dti <= 50 then 10
               else 5
               end
    elsif total_debt_payments == 0
      score += 25
    end

    # Emergency fund coverage (0-25 points)
    monthly_expenses = spent > 0 ? spent : recurring&.dig("total_monthly").to_f
    assets = net_worth&.dig("assets").to_f
    liabilities = net_worth&.dig("liabilities").to_f
    liquid_assets = assets - liabilities

    if monthly_expenses > 0 && assets > 0
      months_covered = liquid_assets / monthly_expenses
      score += if months_covered >= 6 then 25
               elsif months_covered >= 3 then 20
               elsif months_covered >= 1 then 15
               elsif months_covered > 0 then 5
               else 0
               end
    end

    [score, 100].min
  end

  def health_score_label(score)
    case score
    when 90..100 then "Excellent"
    when 70..89  then "Good"
    when 50..69  then "Fair"
    when 30..49  then "Needs Work"
    else              "Critical"
    end
  end

  def health_score_color(score)
    case score
    when 90..100 then "var(--positive)"
    when 70..89  then "var(--success, #22c55e)"
    when 50..69  then "var(--warning, #f59e0b)"
    when 30..49  then "#f97316"
    else              "var(--negative)"
    end
  end
end
