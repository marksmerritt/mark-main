class WritingPromptsController < ApplicationController
  before_action :require_notes_connection

  def show
    notes_result = notes_client.notes(per_page: 500) rescue []
    @notes = notes_result.is_a?(Hash) ? (notes_result["notes"] || []) : Array(notes_result)
    @notes = @notes.select { |n| n.is_a?(Hash) }

    notebooks_result = notes_client.notebooks rescue []
    @notebooks = notebooks_result.is_a?(Array) ? notebooks_result : (notebooks_result.is_a?(Hash) ? (notebooks_result["notebooks"] || []) : [])

    # Enrich notes with word count and parsed dates
    @notes.each do |n|
      content = n["content"] || n["body"] || ""
      n["_word_count"] = content.split(/\s+/).reject(&:blank?).count
      n["_created_date"] = Date.parse(n["created_at"] || n["updated_at"] || "") rescue nil
      n["_updated_date"] = Date.parse(n["updated_at"] || n["created_at"] || "") rescue nil
    end

    # Extract topics from tags
    @tag_topics = {}
    @notes.each do |n|
      tags = n["tags"] || []
      tags.each do |tag|
        name = tag.is_a?(Hash) ? tag["name"] : tag.to_s
        next if name.blank?
        @tag_topics[name] ||= { count: 0, notes: [] }
        @tag_topics[name][:count] += 1
        @tag_topics[name][:notes] << n
      end
    end
    @top_tags = @tag_topics.sort_by { |_, v| -v[:count] }.first(15).to_h

    # Extract content keywords (significant words from titles)
    title_words = {}
    @notes.each do |n|
      title = n["title"] || ""
      title.split(/[\s\-_\/,.:;!?]+/).each do |word|
        w = word.downcase.strip
        next if w.length < 4
        next if %w[the and for with from that this have been which about into their when will more than also note notes untitled].include?(w)
        title_words[w] ||= 0
        title_words[w] += 1
      end
    end
    @content_keywords = title_words.sort_by { |_, v| -v }.first(20).map(&:first)

    # Notes by notebook
    @notes_by_notebook = {}
    @notes.each do |n|
      nb_name = n.dig("notebook", "name") || "No Notebook"
      nb_id = n.dig("notebook", "id") || n["notebook_id"]
      @notes_by_notebook[nb_name] ||= { id: nb_id, notes: [], last_date: nil }
      @notes_by_notebook[nb_name][:notes] << n
      d = n["_created_date"]
      if d && (@notes_by_notebook[nb_name][:last_date].nil? || d > @notes_by_notebook[nb_name][:last_date])
        @notes_by_notebook[nb_name][:last_date] = d
      end
    end

    # Neglected notebooks (no notes in 2+ weeks)
    today = Date.current
    @neglected_notebooks = @notes_by_notebook.select do |name, data|
      data[:last_date] && (today - data[:last_date]).to_i >= 14
    end.sort_by { |_, d| d[:last_date] }.to_h

    # Longest gap between notes per notebook
    @longest_gap = 0
    @neglected_notebooks.each do |_, data|
      gap = (today - data[:last_date]).to_i
      @longest_gap = gap if gap > @longest_gap
    end

    # Recent notes (last 14 days) for continuation prompts
    @recent_notes = @notes
      .select { |n| n["_created_date"] && (today - n["_created_date"]).to_i <= 14 }
      .sort_by { |n| n["created_at"] || "" }
      .reverse
      .first(20)

    # Short notes that could be expanded
    @expandable_notes = @notes
      .select { |n| n["_word_count"].to_i.between?(10, 150) }
      .sort_by { |n| n["created_at"] || "" }
      .reverse
      .first(10)

    # Generate all prompts
    @prompts = []
    generate_reflection_prompts
    generate_continuation_prompts
    generate_connection_prompts
    generate_challenge_prompts
    generate_daily_prompts
    generate_seasonal_prompts
    generate_creative_prompts

    # Prompt of the Day (deterministic based on date)
    seed = today.to_s.bytes.sum + today.year * 366 + today.yday
    if @prompts.any?
      @prompt_of_the_day = @prompts[seed % @prompts.length]
    else
      @prompt_of_the_day = {
        text: "Start your writing journey today. Open a new note and write about whatever comes to mind.",
        category: "creative",
        difficulty: "easy",
        estimated_time: "5 min",
        related_notes: []
      }
    end

    # Categorize prompts
    @categorized = {}
    @prompts.each do |p|
      cat = p[:category]
      @categorized[cat] ||= []
      @categorized[cat] << p
    end

    # Stats
    @total_prompts = @prompts.count
  end

  private

  def generate_reflection_prompts
    # Based on popular tags/topics
    @top_tags.first(5).each do |tag_name, data|
      @prompts << {
        text: "Reflect on your journey with \"#{tag_name}\". What has changed since you first started writing about it?",
        category: "reflection",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: data[:notes].first(3).map { |n| { id: n["id"], title: n["title"] || "Untitled" } }
      }
    end

    # Based on content keywords
    @content_keywords.first(3).each do |keyword|
      @prompts << {
        text: "You've written about \"#{keyword}\" multiple times. What's the most important insight you've gained?",
        category: "reflection",
        difficulty: "medium",
        estimated_time: "10 min",
        related_notes: []
      }
    end

    # General reflection prompts
    if @notes.any?
      oldest = @notes.min_by { |n| n["created_at"] || "9999" }
      if oldest
        @prompts << {
          text: "Look back at your earliest note (\"#{oldest['title'] || 'Untitled'}\"). How has your thinking evolved since then?",
          category: "reflection",
          difficulty: "medium",
          estimated_time: "15 min",
          related_notes: [{ id: oldest["id"], title: oldest["title"] || "Untitled" }]
        }
      end

      most_words = @notes.max_by { |n| n["_word_count"] }
      if most_words && most_words["_word_count"].to_i > 100
        @prompts << {
          text: "Your longest note is \"#{most_words['title'] || 'Untitled'}\" (#{most_words['_word_count']} words). What made this topic so compelling?",
          category: "reflection",
          difficulty: "easy",
          estimated_time: "10 min",
          related_notes: [{ id: most_words["id"], title: most_words["title"] || "Untitled" }]
        }
      end
    end

    @prompts << {
      text: "What have you learned this week that you want to remember a year from now?",
      category: "reflection",
      difficulty: "easy",
      estimated_time: "10 min",
      related_notes: []
    }

    @prompts << {
      text: "Write about a belief you held strongly that has since changed. What caused the shift?",
      category: "reflection",
      difficulty: "hard",
      estimated_time: "20 min",
      related_notes: []
    }
  end

  def generate_continuation_prompts
    @expandable_notes.first(5).each do |note|
      @prompts << {
        text: "Your note \"#{note['title'] || 'Untitled'}\" is only #{note['_word_count']} words. Expand on it -- what details or context could you add?",
        category: "continuation",
        difficulty: "easy",
        estimated_time: "10 min",
        related_notes: [{ id: note["id"], title: note["title"] || "Untitled" }]
      }
    end

    @recent_notes.first(3).each do |note|
      @prompts << {
        text: "You recently wrote \"#{note['title'] || 'Untitled'}\". Write a follow-up: what has happened since?",
        category: "continuation",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: [{ id: note["id"], title: note["title"] || "Untitled" }]
      }
    end

    if @notes.count >= 5
      @prompts << {
        text: "Review your last 5 notes and write a summary that connects their themes together.",
        category: "continuation",
        difficulty: "hard",
        estimated_time: "20 min",
        related_notes: @recent_notes.first(5).map { |n| { id: n["id"], title: n["title"] || "Untitled" } }
      }
    end
  end

  def generate_connection_prompts
    notebook_names = @notes_by_notebook.keys.reject { |k| k == "No Notebook" }

    if notebook_names.length >= 2
      # Suggest connections between different notebooks
      pairs = notebook_names.combination(2).to_a.shuffle(random: Random.new(Date.current.yday)).first(3)
      pairs.each do |a, b|
        @prompts << {
          text: "Find a connection between your \"#{a}\" and \"#{b}\" notebooks. Write about how these topics relate.",
          category: "connection",
          difficulty: "hard",
          estimated_time: "20 min",
          related_notes: []
        }
      end
    end

    # Tag-based connections
    tag_names = @top_tags.keys
    if tag_names.length >= 2
      pairs = tag_names.first(6).combination(2).to_a.shuffle(random: Random.new(Date.current.yday + 100)).first(3)
      pairs.each do |a, b|
        @prompts << {
          text: "How do \"#{a}\" and \"#{b}\" intersect in your thinking? Write about the overlap.",
          category: "connection",
          difficulty: "medium",
          estimated_time: "15 min",
          related_notes: []
        }
      end
    end

    @prompts << {
      text: "Pick two random notes and write about an unexpected connection between them.",
      category: "connection",
      difficulty: "hard",
      estimated_time: "20 min",
      related_notes: []
    }
  end

  def generate_challenge_prompts
    keyword = @content_keywords.first || "a topic you care about"

    @prompts << {
      text: "Write 500 words about #{keyword} without stopping to edit. Let the ideas flow.",
      category: "challenge",
      difficulty: "medium",
      estimated_time: "25 min",
      related_notes: []
    }

    @prompts << {
      text: "Explain #{@content_keywords[1] || 'your main interest'} to a 10-year-old in simple terms.",
      category: "challenge",
      difficulty: "hard",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "Write a note using exactly 100 words. No more, no less. Topic: what you're most excited about right now.",
      category: "challenge",
      difficulty: "hard",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "Write for 10 minutes without stopping. Don't delete anything. Stream of consciousness.",
      category: "challenge",
      difficulty: "easy",
      estimated_time: "10 min",
      related_notes: []
    }

    @prompts << {
      text: "Take your shortest recent note and rewrite it as if it were the introduction to a book.",
      category: "challenge",
      difficulty: "hard",
      estimated_time: "20 min",
      related_notes: @expandable_notes.first(1).map { |n| { id: n["id"], title: n["title"] || "Untitled" } }
    }

    @prompts << {
      text: "Write a note arguing the opposite of something you believe strongly.",
      category: "challenge",
      difficulty: "hard",
      estimated_time: "25 min",
      related_notes: []
    }

    @prompts << {
      text: "Summarize everything you know about #{@content_keywords[2] || 'your favorite subject'} in exactly 3 paragraphs.",
      category: "challenge",
      difficulty: "medium",
      estimated_time: "15 min",
      related_notes: []
    }
  end

  def generate_daily_prompts
    now = Time.current
    hour = now.hour
    wday = now.wday

    if hour < 12
      @prompts << {
        text: "Morning check-in: What are your top 3 priorities today? What does success look like by tonight?",
        category: "daily",
        difficulty: "easy",
        estimated_time: "5 min",
        related_notes: []
      }
      @prompts << {
        text: "Write your morning pages: clear your mind by writing down everything you're thinking right now.",
        category: "daily",
        difficulty: "easy",
        estimated_time: "15 min",
        related_notes: []
      }
    else
      @prompts << {
        text: "Evening review: What went well today? What would you do differently?",
        category: "daily",
        difficulty: "easy",
        estimated_time: "10 min",
        related_notes: []
      }
      @prompts << {
        text: "Write a short gratitude note: list 3 things from today that you're thankful for.",
        category: "daily",
        difficulty: "easy",
        estimated_time: "5 min",
        related_notes: []
      }
    end

    case wday
    when 1 # Monday
      @prompts << {
        text: "Monday planning: Write out your goals for this week and how you'll achieve them.",
        category: "daily",
        difficulty: "easy",
        estimated_time: "10 min",
        related_notes: []
      }
    when 5 # Friday
      @prompts << {
        text: "Friday review: Summarize your week. What did you accomplish? What surprised you?",
        category: "daily",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: []
      }
    when 0, 6 # Weekend
      @prompts << {
        text: "Weekend deep think: Pick a topic you've been wanting to explore and give it a full, uninterrupted write-up.",
        category: "daily",
        difficulty: "medium",
        estimated_time: "30 min",
        related_notes: []
      }
    end

    @prompts << {
      text: "What's one thing you learned today that you didn't know yesterday?",
      category: "daily",
      difficulty: "easy",
      estimated_time: "5 min",
      related_notes: []
    }
  end

  def generate_seasonal_prompts
    today = Date.current
    month = today.month
    day = today.day

    # End of month
    if day >= 25
      @prompts << {
        text: "Month-end review: Look back at #{today.strftime('%B')}. What were the highlights? What would you change?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "20 min",
        related_notes: []
      }
    end

    # Start of month
    if day <= 5
      @prompts << {
        text: "New month, fresh start. Write your intentions for #{today.strftime('%B')}. What will you focus on?",
        category: "seasonal",
        difficulty: "easy",
        estimated_time: "10 min",
        related_notes: []
      }
    end

    # End of quarter
    if [3, 6, 9, 12].include?(month) && day >= 20
      quarter = (month / 3.0).ceil
      @prompts << {
        text: "Q#{quarter} retrospective: Review the past 3 months. What were your biggest wins and lessons?",
        category: "seasonal",
        difficulty: "hard",
        estimated_time: "30 min",
        related_notes: []
      }
    end

    # Start of quarter
    if [1, 4, 7, 10].include?(month) && day <= 7
      quarter = (month / 3.0).ceil
      @prompts << {
        text: "Q#{quarter} planning: What are your top 3 goals for this quarter? How will you measure progress?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "20 min",
        related_notes: []
      }
    end

    # Year-end
    if month == 12 && day >= 15
      @prompts << {
        text: "Year-end reflection: Write about the person you were in January vs. who you are now. What changed?",
        category: "seasonal",
        difficulty: "hard",
        estimated_time: "30 min",
        related_notes: []
      }
      @prompts << {
        text: "Write a letter to your future self. What do you hope #{today.year + 1} brings?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "20 min",
        related_notes: []
      }
    end

    # New Year
    if month == 1 && day <= 15
      @prompts << {
        text: "New year energy: What's the one thing you want to be known for by the end of #{today.year}?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: []
      }
    end

    # Mid-year
    if month == 6 && day >= 15 && day <= 30
      @prompts << {
        text: "Mid-year check-in: You're halfway through #{today.year}. Are you on track? What needs to change?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "20 min",
        related_notes: []
      }
    end

    # Spring
    if month.between?(3, 5)
      @prompts << {
        text: "Spring renewal: What old habits or ideas are you ready to let go of? What new ones do you want to cultivate?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: []
      }
    end

    # Summer
    if month.between?(6, 8)
      @prompts << {
        text: "Summer energy: What project or idea are you most excited to work on while the days are long?",
        category: "seasonal",
        difficulty: "easy",
        estimated_time: "10 min",
        related_notes: []
      }
    end

    # Fall
    if month.between?(9, 11)
      @prompts << {
        text: "Autumn reflection: As the year winds down, what have been the most meaningful experiences so far?",
        category: "seasonal",
        difficulty: "medium",
        estimated_time: "15 min",
        related_notes: []
      }
    end

    # Winter
    if month == 12 || month.between?(1, 2)
      @prompts << {
        text: "Winter introspection: Use this quieter season to write about something you've been avoiding thinking about.",
        category: "seasonal",
        difficulty: "hard",
        estimated_time: "20 min",
        related_notes: []
      }
    end
  end

  def generate_creative_prompts
    @prompts << {
      text: "Write a letter to yourself from 5 years in the future. What advice would future-you give?",
      category: "creative",
      difficulty: "medium",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "Describe your ideal day in vivid detail, from morning to night. What makes it perfect?",
      category: "creative",
      difficulty: "easy",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "Write about a conversation you wish you'd had. What would you say? What would they say?",
      category: "creative",
      difficulty: "medium",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "If you could master any skill overnight, what would it be and why? How would it change your life?",
      category: "creative",
      difficulty: "easy",
      estimated_time: "10 min",
      related_notes: []
    }

    @prompts << {
      text: "Write a mini-essay titled \"Things I Know to Be True.\" List and elaborate on your core beliefs.",
      category: "creative",
      difficulty: "medium",
      estimated_time: "20 min",
      related_notes: []
    }

    @prompts << {
      text: "Describe a place that no longer exists but was important to you. Capture it in words before the memory fades.",
      category: "creative",
      difficulty: "medium",
      estimated_time: "15 min",
      related_notes: []
    }

    @prompts << {
      text: "Write about something small that happened today that most people would overlook. Why did it matter?",
      category: "creative",
      difficulty: "easy",
      estimated_time: "10 min",
      related_notes: []
    }

    @prompts << {
      text: "Create a \"user manual\" for yourself. How do you work best? What should people know about you?",
      category: "creative",
      difficulty: "hard",
      estimated_time: "25 min",
      related_notes: []
    }
  end
end
