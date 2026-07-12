module Orchestrator
  class Mode
    def self.temporal?
      ENV.fetch("DEPLOYMENT_ORCHESTRATOR", "local") == "temporal"
    end
  end
end
