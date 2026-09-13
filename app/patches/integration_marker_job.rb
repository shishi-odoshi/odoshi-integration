# frozen_string_literal: true

# The shared test ActiveJob: whichever runtime executes it writes a marker row
# tagged with itself. Enqueued to "default" it runs here (Solid Queue Ruby
# worker); enqueued to "elixir" it runs in beam's handler for this class name.
class IntegrationMarkerJob < ApplicationJob
  queue_as :default

  def perform(marker)
    JobMarker.create!(source: "ruby", marker: marker)
  end
end
