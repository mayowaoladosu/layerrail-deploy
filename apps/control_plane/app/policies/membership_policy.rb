class MembershipPolicy < ApplicationPolicy
  def show?
    member_of_selected_organization?
  end

  def create?
    manageable?
  end

  def update?
    manageable?
  end

  def destroy?
    manageable?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless context&.member?

      scope.where(organization_id: context.organization.id)
    end
  end

  private

  def manageable?
    return false unless show?
    return false if record.owner?
    return true if context.role?(:owner)

    context.role?(:admin)
  end
end
