class WordFrequencyController < ApplicationController
  before_action :require_notes_connection

  include ActionView::Helpers::NumberHelper

  STOP_WORDS = %w[
    the a an is are was were be been being have has had do does did will would
    could should may might shall can and or but if then else when where which
    that this these those it its it's i me my we our us you your he him his
    she her they them their what who whom how why not no nor so too very just
    also about above after again all am any at before below between both by
    down during each few for from further get got had has here in into more
    most of off on once only other out over own same some such than to under
    until up while with there here been being does doing done from going goes
    gone having make made much many must need new now old only really still
    take through want well like even back one two three four five six seven
    eight nine ten first last long great little right big come end good high
    know let made part put say set try use way went
  ].freeze

  # Common English words (top ~500) for jargon detection
  COMMON_ENGLISH = (STOP_WORDS + %w[
    time people way year day thing man world life hand work place case week
    point company number group problem fact money area home water room mother
    country question city community family head house story lot school change
    state government book keep eye never next thought program business system
    interest side head house face child power often run give line move report
    door late night great team young level office order house small play field
    kind start attempt book hear often run word story sure eat watch far walk
    white begin seem talk indeed hold always music special move job carry step
    wait north south late cut learn hope live believe happen hold bring begin
    seem help show hear play found stand lose pay meet include continue start
    give run think see look find called left full along best upon door early
    however hard stay name write head read hand port large spell add land
    house line close act open turn move live write study hard learn plant
    cover food sun thought went without form feed though look move along main
    left read important watch might turn saw light stop felt start kind walk
    leave became please talk sure able real whole keep mean become tell bring
    word already think young help call give real might house between tell
  ]).flatten.uniq.freeze

  def show
    threads = {}
    threads[:notes] = Thread.new { notes_client.notes(per_page: 1000) }
    threads[:notebooks] = Thread.new { notes_client.notebooks rescue [] }

    notes_result = threads[:notes].value
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }
    notebooks_result = threads[:notebooks].value
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Extract all text content
    all_words = []
    all_sentences = []
    notebook_words = {}

    @notes.each do |n|
      content = (n["content"] || n["body"] || "").to_s
      # Strip HTML/markdown
      text = content.gsub(/<[^>]+>/, " ").gsub(/[#*_~`\[\]\(\)>]/, " ")
      words = text.downcase.scan(/[a-z']+/).select { |w| w.length > 1 }
      n["_words"] = words
      n["_word_count"] = words.count
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil

      all_words.concat(words)

      # Sentences for reading level
      sentences = text.split(/[.!?]+/).map(&:strip).reject(&:empty?)
      all_sentences.concat(sentences)

      # Words by notebook
      nb_name = n.dig("notebook", "name") || "No Notebook"
      notebook_words[nb_name] ||= []
      notebook_words[nb_name].concat(words)
    end

    # --- Global word frequency (excluding stop words) ---
    filtered_words = all_words.reject { |w| STOP_WORDS.include?(w) }
    word_freq = Hash.new(0)
    filtered_words.each { |w| word_freq[w] += 1 }
    @top_words = word_freq.sort_by { |_, v| -v }.first(50)

    # --- Total and unique ---
    @total_words = all_words.count
    @unique_words = all_words.uniq.count
    @vocabulary_richness = @total_words > 0 ? (@unique_words.to_f / @total_words).round(4) : 0

    # --- Bigram frequency ---
    bigrams = Hash.new(0)
    filtered_words.each_cons(2) do |a, b|
      bigrams["#{a} #{b}"] += 1
    end
    @top_bigrams = bigrams.sort_by { |_, v| -v }.first(30)

    # --- Word length distribution ---
    @word_lengths = Hash.new(0)
    all_words.each { |w| @word_lengths[w.length] += 1 }
    @word_lengths = @word_lengths.sort_by { |k, _| k }.to_h

    # --- Reading level (Flesch-Kincaid) ---
    total_sentences = [all_sentences.count, 1].max
    total_syllables = all_words.sum { |w| count_syllables(w) }
    avg_sentence_length = @total_words.to_f / total_sentences
    avg_syllables_per_word = @total_words > 0 ? total_syllables.to_f / @total_words : 0

    @fk_grade = (0.39 * avg_sentence_length + 11.8 * avg_syllables_per_word - 15.59).round(1)
    @fk_grade = [[@fk_grade, 0].max, 20].min
    @fk_ease = (206.835 - 1.015 * avg_sentence_length - 84.6 * avg_syllables_per_word).round(1)
    @fk_ease = [[@fk_ease, 0].max, 100].min

    @reading_level_label = case @fk_grade
    when 0..5 then "Elementary"
    when 5..8 then "Middle School"
    when 8..12 then "High School"
    when 12..16 then "College"
    else "Graduate"
    end

    # --- Jargon / technical terms ---
    jargon_freq = Hash.new(0)
    filtered_words.each do |w|
      jargon_freq[w] += 1 unless COMMON_ENGLISH.include?(w)
    end
    @jargon_words = jargon_freq.select { |_, v| v >= 3 }.sort_by { |_, v| -v }.first(30)

    # --- Word frequency by notebook (top 5 per notebook) ---
    @notebook_top_words = {}
    notebook_words.each do |nb, words|
      freq = Hash.new(0)
      words.reject { |w| STOP_WORDS.include?(w) }.each { |w| freq[w] += 1 }
      @notebook_top_words[nb] = freq.sort_by { |_, v| -v }.first(5)
    end
    @notebook_top_words = @notebook_top_words.sort_by { |_, v| -(v.sum { |_, c| c }) }.to_h

    # --- Word evolution over time ---
    @word_evolution = {}
    @notes.select { |n| n["_created_date"] }.sort_by { |n| n["_created_date"] }.each do |n|
      month = n["_created_date"].strftime("%Y-%m")
      @word_evolution[month] ||= { total: 0, unique: Set.new, words: [] }
      @word_evolution[month][:total] += n["_word_count"]
      words = (n["_words"] || []).reject { |w| STOP_WORDS.include?(w) }
      @word_evolution[month][:unique].merge(words)
      @word_evolution[month][:words].concat(words)
    end
    # Convert sets to counts and find top word per month
    @word_evolution_summary = {}
    @word_evolution.each do |month, data|
      freq = Hash.new(0)
      data[:words].each { |w| freq[w] += 1 }
      top_word = freq.max_by { |_, v| v }
      @word_evolution_summary[month] = {
        total: data[:total],
        unique: data[:unique].count,
        top_word: top_word ? top_word[0] : "-"
      }
    end

    # --- Stats for word cloud sizing ---
    @cloud_words = @top_words.first(30)
    @cloud_max = @cloud_words.any? ? @cloud_words.first[1].to_f : 1
    @cloud_min = @cloud_words.any? ? @cloud_words.last[1].to_f : 1
  rescue => e
    Rails.logger.error("WordFrequency error: #{e.message}")
    @notes = []
    @top_words = []
    @total_words = 0
    @unique_words = 0
    @vocabulary_richness = 0
    @top_bigrams = []
    @word_lengths = {}
    @fk_grade = 0
    @fk_ease = 0
    @reading_level_label = "N/A"
    @jargon_words = []
    @notebook_top_words = {}
    @word_evolution_summary = {}
    @cloud_words = []
    @cloud_max = 1
    @cloud_min = 1
    @error = e.message
  end

  private

  def count_syllables(word)
    return 1 if word.length <= 3
    word = word.downcase.gsub(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, "")
    word = word.sub(/^y/, "")
    vowel_groups = word.scan(/[aeiouy]+/)
    [vowel_groups.count, 1].max
  end
end
