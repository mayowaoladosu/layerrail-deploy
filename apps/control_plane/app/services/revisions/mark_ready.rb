module Revisions
  class MarkReady
    class EvidenceRejected < StandardError; end
    class InvalidRevisionState < StandardError; end
    class ReadinessConflict < StandardError; end

    Result = Data.define(:revision)

    def self.call(revision:, readiness:)
      new(revision:, readiness:).call
    end

    def initialize(revision:, readiness:)
      @revision = revision
      @readiness = JSON.parse(JSON.generate(readiness))
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @revision.lock!
        if @revision.status == "ready"
          raise ReadinessConflict unless @revision.readiness == @readiness

          return Result.new(revision: @revision)
        end
        raise InvalidRevisionState unless @revision.status == "candidate"
        raise EvidenceRejected unless @revision.build.evidence["scan_status"] == "passed"
        raise EvidenceRejected unless @readiness.is_a?(Hash) && @readiness["status"] == "passed"

        deployment = @revision.deployment
        %i[deploying verifying ready].each do |status|
          deployment = Deployments::Transition.call(
            deployment:,
            to: status,
            actor: nil,
            cause: "revision_#{status}",
            expected_lock_version: deployment.lock_version
          ).deployment
        end
        @revision.update!(status: :ready, readiness: @readiness, ready_at: Time.current)

        Result.new(revision: @revision)
      end
    end
  end
end
