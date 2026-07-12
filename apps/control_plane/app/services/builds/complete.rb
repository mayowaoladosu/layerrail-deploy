module Builds
  class Complete
    class CompletionConflict < StandardError; end
    class EvidenceRejected < StandardError; end
    class InvalidBuildState < StandardError; end

    Result = Data.define(:build, :revision, :replayed)

    def self.call(build:, artifact_digest:, evidence:, region:, cell:, revision_id: nil)
      new(build:, artifact_digest:, evidence:, region:, cell:, revision_id:).call
    end

    def initialize(build:, artifact_digest:, evidence:, region:, cell:, revision_id:)
      @build = build
      @artifact_digest = artifact_digest.to_s
      @evidence = JSON.parse(JSON.generate(evidence))
      @region = region.to_s
      @cell = cell.to_s
      @revision_id = revision_id&.to_s
    end

    def call
      ApplicationRecord.transaction(requires_new: true) do
        @build.lock!
        if @build.status == "succeeded"
          revision = @build.revision
          unless @build.artifact_digest == @artifact_digest &&
              @build.evidence == @evidence &&
              revision&.region == @region &&
              revision&.cell == @cell &&
              (@revision_id.nil? || revision&.id == @revision_id)
            raise CompletionConflict
          end

          return Result.new(build: @build, revision:, replayed: true)
        end
        raise InvalidBuildState unless @build.status == "running"
        raise EvidenceRejected unless @evidence["scan_status"] == "passed"
        planned_revision_id = @build.evidence["planned_revision_id"]
        if @revision_id
          raise CompletionConflict unless Events::Envelope::UUID_PATTERN.match?(@revision_id)
          raise CompletionConflict if planned_revision_id && planned_revision_id != @revision_id
        end

        @build.update!(
          status: :succeeded,
          artifact_digest: @artifact_digest,
          evidence: @evidence,
          finished_at: Time.current
        )
        deployment = @build.deployment
        revision = Revision.create!(
          id: @revision_id,
          organization: deployment.organization,
          project: deployment.project,
          service: deployment.service,
          environment: deployment.environment,
          deployment:,
          build: @build,
          configuration_snapshot: deployment.configuration_snapshot,
          artifact_digest: @artifact_digest,
          runtime_policy_snapshot: deployment.runtime_policy_snapshot,
          status: :candidate,
          readiness: {},
          region: @region,
          cell: @cell
        )
        Deployments::Transition.call(
          deployment:,
          to: :scanning,
          actor: nil,
          cause: "build_completed",
          expected_lock_version: deployment.lock_version
        )

        Result.new(build: @build, revision:, replayed: false)
      end
    end
  end
end
