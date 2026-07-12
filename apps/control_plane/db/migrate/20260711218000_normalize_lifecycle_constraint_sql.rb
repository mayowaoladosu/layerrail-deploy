class NormalizeLifecycleConstraintSql < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :builds, name: "builds_lifecycle_consistent"
    add_check_constraint :builds,
      "(status = 'running' AND artifact_digest IS NULL AND finished_at IS NULL) OR " \
        "(status = 'succeeded' AND artifact_digest IS NOT NULL AND finished_at IS NOT NULL) OR " \
        "((status = 'failed' OR status = 'canceled') AND artifact_digest IS NULL AND finished_at IS NOT NULL)",
      name: "builds_lifecycle_consistent"

    remove_check_constraint :revisions, name: "revisions_lifecycle_consistent"
    add_check_constraint :revisions,
      "(status = 'candidate' AND ready_at IS NULL) OR " \
        "((status = 'ready' OR status = 'retired') AND ready_at IS NOT NULL)",
      name: "revisions_lifecycle_consistent"
  end

  def down
    remove_check_constraint :builds, name: "builds_lifecycle_consistent"
    add_check_constraint :builds,
      "(status = 'running' AND artifact_digest IS NULL AND finished_at IS NULL) OR " \
        "(status = 'succeeded' AND artifact_digest IS NOT NULL AND finished_at IS NOT NULL) OR " \
        "(status IN ('failed', 'canceled') AND artifact_digest IS NULL AND finished_at IS NOT NULL)",
      name: "builds_lifecycle_consistent"

    remove_check_constraint :revisions, name: "revisions_lifecycle_consistent"
    add_check_constraint :revisions,
      "(status = 'candidate' AND ready_at IS NULL) OR (status IN ('ready', 'retired') AND ready_at IS NOT NULL)",
      name: "revisions_lifecycle_consistent"
  end
end
