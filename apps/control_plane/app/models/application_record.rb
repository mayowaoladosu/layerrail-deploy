class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_validation :assign_uuid_v7, on: :create

  private

  def assign_uuid_v7
    self.id ||= SecureRandom.uuid_v7 if has_attribute?(:id)
  end
end
