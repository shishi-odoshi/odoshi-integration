# frozen_string_literal: true

# Slow variant so chaos can reliably strike mid-execution (phase 4 kills the
# beam worker while jobs are claimed and in flight).
class SlowMarkerJob < ApplicationJob
  queue_as :default

  def perform(marker)
    sleep 2
    JobMarker.create!(source: "ruby", marker: marker)
  end
end
