# frozen_string_literal: true

# Harness HTTP surface. Every action runs inside the SUPERVISED web child, so
# enqueue exercises the production ActiveJob -> Solid Queue path, broadcast
# exercises Turbo -> Action Cable -> Solid Cable, and restart_jobs exercises
# the DESIGN §9 control path (Rails.supervisor.restart! over the supervision
# socket) from real app code. GET-only on purpose: this is a test harness.
class IntegrationController < ActionController::Base
  # GET /integration/enqueue?queue=elixir&count=20&prefix=p1e&job=marker|slow
  def enqueue
    klass = params[:job] == "slow" ? SlowMarkerJob : IntegrationMarkerJob
    queue = params.require(:queue)
    count = Integer(params.require(:count))
    prefix = params.require(:prefix)

    jobs = count.times.map { |i| klass.set(queue: queue).perform_later("#{prefix}-#{i}") }
    raise "enqueue returned false" unless jobs.all?

    render json: { enqueued: count, queue: queue, job: klass.name }
  end

  # GET /integration/broadcast?message=hello — synchronous Turbo broadcast
  # through the Solid Cable adapter (writes a solid_cable_messages row that
  # beam's cable server fans out to its WebSocket subscribers).
  def broadcast
    message = params.require(:message)
    Turbo::StreamsChannel.broadcast_append_to("integration", target: "messages", content: message)
    render json: { broadcast: message }
  end

  # GET /integration/signed_stream?name=integration — the exact signed stream
  # name turbo_stream_from would embed in a page, for the harness ws client.
  def signed_stream
    render plain: Turbo::StreamsChannel.signed_stream_name(params.fetch(:name, "integration"))
  end

  # GET /integration/restart_jobs — DESIGN §7/§9: restarting is a feature.
  # odoshi-resilience sends {"cmd":"restart","id":"jobs"} over the socket.
  def restart_jobs
    render json: {
      supervised: Rails.supervisor.supervised?,
      restarted: Rails.supervisor.restart!(:jobs)
    }
  end
end
