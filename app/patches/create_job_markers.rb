# frozen_string_literal: true

class CreateJobMarkers < ActiveRecord::Migration[8.0]
  def change
    create_table :job_markers do |t|
      t.string :source, null: false # "ruby" | "beam"
      t.string :marker, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    # Deliberately NO unique index on [source, marker]: a double execution
    # must surface as a duplicate row the assertions can count, not as a
    # constraint violation inside the worker.
    add_index :job_markers, :marker
  end
end
