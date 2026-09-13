defmodule BeamRunner.Handlers do
  @moduledoc """
  Elixir handlers backing the harness ActiveJob classes. Each execution
  inserts a `job_markers` row tagged source="beam" into the app's PRIMARY
  database — the observable side effect the harness asserts routing and
  exactly-once against (the Ruby jobs write source="ruby").
  """

  def insert_marker(marker) do
    {:ok, _} =
      Postgrex.query(
        BeamRunner.PrimaryDB,
        "INSERT INTO job_markers (source, marker) VALUES ('beam', $1)",
        [marker]
      )

    :ok
  end

  defmodule Marker do
    @moduledoc "Elixir twin of IntegrationMarkerJob."
    @behaviour OtpRailsBeam.Queue.Handler

    @impl true
    def perform([marker]), do: BeamRunner.Handlers.insert_marker(marker)
  end

  defmodule SlowMarker do
    @moduledoc "Elixir twin of SlowMarkerJob — slow enough for chaos to strike mid-flight."
    @behaviour OtpRailsBeam.Queue.Handler

    @impl true
    def perform([marker]) do
      Process.sleep(2_000)
      BeamRunner.Handlers.insert_marker(marker)
    end
  end
end
