module Routing
  class Hostnames
    MAX_LABEL_BYTES = 63

    def self.immutable(deployment, domain: deploy_domain)
      "d-#{deployment.id}.#{domain}"
    end

    def self.environment(alias_record, domain: deploy_domain)
      raw_label = [
        alias_record.project.slug,
        alias_record.service.name.parameterize,
        alias_record.environment.slug
      ].join("-")
      identity = alias_record.id.to_s.delete("-")
      raise ArgumentError unless identity.match?(/\A[0-9a-f]{32}\z/)

      prefix = bounded_prefix(raw_label, MAX_LABEL_BYTES - identity.bytesize - 1)
      "#{prefix}-#{identity}.#{domain}"
    end

    def self.bounded_prefix(value, maximum)
      label = value.to_s.parameterize
      raise ArgumentError if label.blank?

      label.byteslice(0, maximum).to_s.sub(/-+\z/, "")
    end
    private_class_method :bounded_prefix

    def self.deploy_domain
      ENV.fetch("DEPLOY_DOMAIN", "localhost").to_s.downcase
    end
    private_class_method :deploy_domain
  end
end
