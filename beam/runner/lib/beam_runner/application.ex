defmodule BeamRunner.Application do
  @moduledoc """
  Starts one beam role per container:

    * ROLE=queue — `OtpRailsBeam.Queue` on the designated "elixir" queue of
      the Rails app's Solid Queue database, plus a Postgrex connection to the
      PRIMARY database where the marker handlers record side effects.
    * ROLE=cable — `OtpRailsBeam.Cable` serving the ActionCable v1 protocol
      from the Solid Cable database, sharing the app's SECRET_KEY_BASE so
      Turbo-signed stream names verify.

  `start_permanent` (prod) means an exhausted internal supervisor takes the
  node down, and beam/start.sh respawns it — the platform-as-final-supervisor
  layer.
  """

  use Application

  @impl true
  def start(_type, _args) do
    role = System.fetch_env!("ROLE")

    Supervisor.start_link(children(role),
      strategy: :one_for_one,
      name: BeamRunner.Supervisor
    )
  end

  defp children("queue") do
    [
      {Postgrex, Keyword.merge(db(System.get_env("PRIMARY_DB", "app_production")),
         name: BeamRunner.PrimaryDB,
         pool_size: 2
       )},
      {OtpRailsBeam.Queue,
       db: db(System.get_env("QUEUE_DB", "app_production_queue")),
       queues: ["elixir"],
       handlers: %{
         "IntegrationMarkerJob" => BeamRunner.Handlers.Marker,
         "SlowMarkerJob" => BeamRunner.Handlers.SlowMarker
       },
       # Match the app's accelerated Solid Queue liveness settings
       # (process_heartbeat_interval 3s / process_alive_threshold 15s).
       heartbeat_interval_ms: 3_000,
       batch_size: 3}
    ]
  end

  defp children("cable") do
    [
      {OtpRailsBeam.Cable,
       port: String.to_integer(System.get_env("CABLE_PORT", "28080")),
       ip: {0, 0, 0, 0},
       db: db(System.get_env("CABLE_DB", "app_production_cable")),
       secret_key_base: System.fetch_env!("SECRET_KEY_BASE")}
    ]
  end

  defp children(other), do: raise("unknown ROLE #{inspect(other)} (want queue|cable)")

  defp db(database) do
    [
      hostname: System.get_env("DB_HOST", "postgres"),
      username: System.get_env("DB_USER", "postgres"),
      password: System.get_env("DB_PASSWORD", "postgres"),
      database: database
    ]
  end
end
