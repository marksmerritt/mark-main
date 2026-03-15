class MarketSessionController < ApplicationController
  def show
    @sessions = [
      {
        name: "US Pre-Market",
        flag: "\u{1F1FA}\u{1F1F8}",
        open_hour: 4, open_min: 0,
        close_hour: 9, close_min: 30,
        color: "#1565c0",
        crosses_midnight: false
      },
      {
        name: "US Regular Hours",
        flag: "\u{1F1FA}\u{1F1F8}",
        open_hour: 9, open_min: 30,
        close_hour: 16, close_min: 0,
        color: "#2e7d32",
        crosses_midnight: false
      },
      {
        name: "US After Hours",
        flag: "\u{1F1FA}\u{1F1F8}",
        open_hour: 16, open_min: 0,
        close_hour: 20, close_min: 0,
        color: "#4527a0",
        crosses_midnight: false
      },
      {
        name: "London",
        flag: "\u{1F1EC}\u{1F1E7}",
        open_hour: 3, open_min: 0,
        close_hour: 11, close_min: 30,
        color: "#c62828",
        crosses_midnight: false
      },
      {
        name: "Tokyo",
        flag: "\u{1F1EF}\u{1F1F5}",
        open_hour: 19, open_min: 0,
        close_hour: 3, close_min: 0,
        color: "#e65100",
        crosses_midnight: true
      },
      {
        name: "Sydney",
        flag: "\u{1F1E6}\u{1F1FA}",
        open_hour: 17, open_min: 0,
        close_hour: 1, close_min: 0,
        color: "#00838f",
        crosses_midnight: true
      }
    ]

    @key_times = [
      { time: "4:00 AM ET", label: "Pre-Market Opens", icon: "brightness_5" },
      { time: "9:30 AM ET", label: "US Market Open (NYSE/NASDAQ)", icon: "play_circle" },
      { time: "9:45 AM ET", label: "Opening Range Complete (15 min)", icon: "timer" },
      { time: "10:00 AM ET", label: "First Hour Reversal Window", icon: "swap_vert" },
      { time: "11:30 AM ET", label: "London Close", icon: "schedule" },
      { time: "12:00 PM ET", label: "Lunch Lull Begins", icon: "restaurant" },
      { time: "2:00 PM ET", label: "Bond Market Close / Afternoon Push", icon: "trending_up" },
      { time: "3:50 PM ET", label: "MOC Imbalances Published", icon: "bar_chart" },
      { time: "4:00 PM ET", label: "US Market Close", icon: "stop_circle" },
      { time: "4:15 PM ET", label: "Options Expiry (daily/weekly)", icon: "event" },
      { time: "8:00 PM ET", label: "After Hours Close", icon: "nights_stay" }
    ]
  end
end
