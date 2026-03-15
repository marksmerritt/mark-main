module ApplicationHelper
  def pnl_class(value)
    value.to_f >= 0 ? "positive" : "negative"
  end

  def pnl_display(value)
    return content_tag(:span, "\u2014") if value.nil?

    tag.span number_to_currency(value), class: pnl_class(value)
  end

  def time_ago_short(time)
    return "" if time.nil?

    time = Time.parse(time) if time.is_a?(String)
    seconds = (Time.current - time).to_i

    case seconds
    when 0...60         then "#{seconds}s"
    when 60...3600      then "#{seconds / 60}m"
    when 3600...86_400  then "#{seconds / 3600}h"
    when 86_400...604_800   then "#{seconds / 86_400}d"
    when 604_800...2_592_000 then "#{seconds / 604_800}w"
    else "#{seconds / 2_592_000}mo"
    end
  end

  def badge_for(status)
    return "" if status.blank?

    tag.span status.capitalize, class: "badge badge-#{status}"
  end

  def mood_badge(mood)
    return "" if mood.blank?

    tag.span mood, class: "badge badge-mood"
  end

  def icon(name, opts = {})
    css = ["material-icons-outlined", opts[:class]].compact.join(" ")
    tag.span name, class: css
  end

  def outcome_badge(pnl)
    return "" if pnl.nil?

    pnl_val = pnl.to_f
    if pnl_val > 0
      tag.span "W", class: "outcome-badge outcome-win", title: "Winner"
    elsif pnl_val < 0
      tag.span "L", class: "outcome-badge outcome-loss", title: "Loser"
    else
      tag.span "BE", class: "outcome-badge outcome-breakeven", title: "Breakeven"
    end
  end

  # Normalize a value within an array to a 0-100 scale for radar charts
  def normalize_val(val, arr)
    min = arr.min.to_f
    max = arr.max.to_f
    return 50 if max == min
    ((val.to_f - min) / (max - min) * 100).round(1)
  end
end
