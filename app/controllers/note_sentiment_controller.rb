class NoteSentimentController < ApplicationController
  before_action :require_notes_connection

  POSITIVE_WORDS = %w[
    happy great excellent good love success achieve improve growth progress
    wonderful fantastic amazing perfect best brilliant outstanding superb
    glad pleased excited grateful proud confident strong powerful optimistic
    hopeful inspired
  ].freeze

  NEGATIVE_WORDS = %w[
    bad terrible awful hate fail problem issue worry stress difficult
    struggle pain loss mistake error wrong poor weak sad frustrated
    angry disappointed confused overwhelmed anxious afraid doubt regret
  ].freeze

  def show
    notes_result = begin
      notes_client.notes(per_page: 500)
    rescue => e
      Rails.logger.error("NoteSentiment notes fetch error: #{e.message}")
      []
    end

    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    notebooks_result = begin
      notes_client.notebooks
    rescue => e
      Rails.logger.error("NoteSentiment notebooks fetch error: #{e.message}")
      []
    end
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Analyze sentiment for each note
    positive_freq = Hash.new(0)
    negative_freq = Hash.new(0)

    @notes.each do |n|
      content = (n["content"] || n["body"] || "").to_s
      text = content.gsub(/<[^>]+>/, " ").gsub(/[#*_~`\[\]\(\)>]/, " ")
      words = text.downcase.scan(/[a-z']+/).select { |w| w.length > 1 }

      pos_count = 0
      neg_count = 0
      words.each do |w|
        if POSITIVE_WORDS.include?(w)
          pos_count += 1
          positive_freq[w] += 1
        elsif NEGATIVE_WORDS.include?(w)
          neg_count += 1
          negative_freq[w] += 1
        end
      end

      total_sentiment_words = pos_count + neg_count
      score = if total_sentiment_words > 0
        ((pos_count - neg_count).to_f / total_sentiment_words).round(3)
      else
        0.0
      end

      n["_sentiment_score"] = score
      n["_pos_count"] = pos_count
      n["_neg_count"] = neg_count
      n["_word_count"] = words.count
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
    end

    # Overall sentiment
    scored_notes = @notes.select { |n| n["_pos_count"] + n["_neg_count"] > 0 }
    @total_analyzed = @notes.count
    @avg_sentiment = if scored_notes.any?
      (scored_notes.sum { |n| n["_sentiment_score"] } / scored_notes.count.to_f).round(3)
    else
      0.0
    end

    # Counts
    @positive_count = @notes.count { |n| n["_sentiment_score"] > 0.1 }
    @negative_count = @notes.count { |n| n["_sentiment_score"] < -0.1 }
    @neutral_count = @total_analyzed - @positive_count - @negative_count

    @positive_pct = @total_analyzed > 0 ? (@positive_count.to_f / @total_analyzed * 100).round(1) : 0
    @negative_pct = @total_analyzed > 0 ? (@negative_count.to_f / @total_analyzed * 100).round(1) : 0

    # Most positive / negative notes
    @most_positive = @notes.sort_by { |n| -n["_sentiment_score"] }.first(5)
    @most_negative = @notes.sort_by { |n| n["_sentiment_score"] }.first(5)

    # Sentiment trend by month
    @sentiment_trend = {}
    @notes.select { |n| n["_created_date"] }.sort_by { |n| n["_created_date"] }.each do |n|
      month = n["_created_date"].strftime("%Y-%m")
      @sentiment_trend[month] ||= { scores: [], count: 0 }
      @sentiment_trend[month][:scores] << n["_sentiment_score"]
      @sentiment_trend[month][:count] += 1
    end
    @sentiment_trend_avg = {}
    @sentiment_trend.each do |month, data|
      avg = data[:scores].any? ? (data[:scores].sum / data[:scores].count.to_f).round(3) : 0
      @sentiment_trend_avg[month] = avg
    end

    # Sentiment distribution histogram
    @distribution = Hash.new(0)
    buckets = (-10..10).map { |i| (i * 0.1).round(1) }
    @notes.each do |n|
      bucket = (n["_sentiment_score"] * 10).round / 10.0
      bucket = [[-1.0, bucket].max, 1.0].min
      @distribution[bucket] += 1
    end

    # Sentiment by notebook
    @by_notebook = {}
    @notes.each do |n|
      nb = n.dig("notebook", "name") || "No Notebook"
      @by_notebook[nb] ||= { scores: [], count: 0 }
      @by_notebook[nb][:scores] << n["_sentiment_score"]
      @by_notebook[nb][:count] += 1
    end
    @notebook_sentiment = {}
    @by_notebook.each do |nb, data|
      avg = data[:scores].any? ? (data[:scores].sum / data[:scores].count.to_f).round(3) : 0
      @notebook_sentiment[nb] = { avg: avg, count: data[:count] }
    end
    @notebook_sentiment = @notebook_sentiment.sort_by { |_, v| -v[:avg] }.to_h

    # Sentiment by tag
    @tag_sentiment = {}
    @notes.each do |n|
      tags = n["tags"] || []
      tags.each do |tag|
        name = tag.is_a?(Hash) ? tag["name"] : tag.to_s
        @tag_sentiment[name] ||= { scores: [], count: 0 }
        @tag_sentiment[name][:scores] << n["_sentiment_score"]
        @tag_sentiment[name][:count] += 1
      end
    end
    @tag_sentiment_avg = {}
    @tag_sentiment.each do |tag, data|
      avg = data[:scores].any? ? (data[:scores].sum / data[:scores].count.to_f).round(3) : 0
      @tag_sentiment_avg[tag] = { avg: avg, count: data[:count] }
    end
    @tag_sentiment_avg = @tag_sentiment_avg.sort_by { |_, v| -v[:avg] }.to_h

    # Word mood clouds
    @positive_words_freq = positive_freq.sort_by { |_, v| -v }.first(20)
    @negative_words_freq = negative_freq.sort_by { |_, v| -v }.first(20)

  rescue => e
    Rails.logger.error("NoteSentiment error: #{e.message}")
    @notes = []
    @total_analyzed = 0
    @avg_sentiment = 0.0
    @positive_count = 0
    @negative_count = 0
    @neutral_count = 0
    @positive_pct = 0
    @negative_pct = 0
    @most_positive = []
    @most_negative = []
    @sentiment_trend_avg = {}
    @distribution = {}
    @notebook_sentiment = {}
    @tag_sentiment_avg = {}
    @positive_words_freq = []
    @negative_words_freq = []
    @error = e.message
  end
end
