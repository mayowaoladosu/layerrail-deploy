class StabilizeMembershipRoleConstraint < ActiveRecord::Migration[8.1]
  ROLES = %w[owner admin member].freeze

  def up
    remove_check_constraint :memberships, name: "memberships_role_allowed"
    add_check_constraint :memberships,
      role_expression,
      name: "memberships_role_allowed"
  end

  def down
    remove_check_constraint :memberships, name: "memberships_role_allowed"
    add_check_constraint :memberships,
      "role IN ('owner', 'admin', 'member')",
      name: "memberships_role_allowed"
  end

  private

  def role_expression
    ROLES.map { |role| "role = #{connection.quote(role)}" }.join(" OR ")
  end
end
