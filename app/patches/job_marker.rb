# frozen_string_literal: true

# One row per executed marker job. `source` records which runtime ran it
# ("ruby" via IntegrationMarkerJob/SlowMarkerJob, "beam" via the Elixir
# handlers), so exactly-once and queue-routing assertions are plain SQL.
class JobMarker < ApplicationRecord
end
