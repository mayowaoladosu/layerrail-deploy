class EnvironmentPolicy < ApplicationPolicy
  def create?
    member_of_selected_organization? && context.role?(:owner, :admin)
  end

  def show?
    member_of_selected_organization?
  end

  def update?
    show? && context.role?(:owner, :admin)
  end

  def request_deletion?
    show? && context.role?(:owner) && record.kind_custom?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless context&.member?

      scope.joins(:project).where(projects: { organization_id: context.organization.id })
    end
  end
end
