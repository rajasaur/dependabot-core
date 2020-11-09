# frozen_string_literal: true

require "excon"
require "dependabot/update_checkers"
require "dependabot/update_checkers/base"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module Elm
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      require_relative "update_checker/requirements_updater"
      require_relative "update_checker/elm_18_version_resolver"
      require_relative "update_checker/elm_19_version_resolver"

      def latest_version
        @latest_version ||= candidate_versions.max
      end

      # Overwrite the base class to allow multi-dependency update PRs for
      # dependencies for which we don't have a version.
      def can_update?(requirements_to_unlock:)
        if dependency.appears_in_lockfile?
          version_can_update?(requirements_to_unlock: requirements_to_unlock)
        elsif requirements_to_unlock == :none
          false
        elsif requirements_to_unlock == :own
          requirements_can_update?
        elsif requirements_to_unlock == :all
          updated_dependencies_after_full_unlock.any?
        end
      end

      def latest_resolvable_version
        @latest_resolvable_version ||=
          version_resolver.
          latest_resolvable_version(unlock_requirement: :own)
      end

      def latest_resolvable_version_with_no_unlock
        # Irrelevant, since Elm has a single dependency file (well, there's
        # also `exact-dependencies.json`, but it's not recommended that that
        # is committed).
        nil
      end

      def updated_requirements
        RequirementsUpdater.new(
          requirements: dependency.requirements,
          latest_resolvable_version: latest_resolvable_version
        ).updated_requirements
      end

      private

      def version_resolver
        @version_resolver ||=
          if dependency.requirements.any? { |r| r.fetch(:file) == "elm.json" }
            Elm19VersionResolver.new(
              dependency: dependency,
              dependency_files: dependency_files
            )
          else
            Elm18VersionResolver.new(
              dependency: dependency,
              dependency_files: dependency_files,
              candidate_versions: candidate_versions
            )
          end
      end

      def updated_dependencies_after_full_unlock
        version_resolver.updated_dependencies_after_full_unlock
      end

      def latest_version_resolvable_with_full_unlock?
        latest_version == version_resolver.
                          latest_resolvable_version(unlock_requirement: :all)
      end

      def candidate_versions
        filtered = all_versions.
                   reject { |v| ignore_reqs.any? { |r| r.satisfied_by?(v) } }

        raise AllVersionsIgnored if @raise_on_ignored && filtered.empty? && all_versions.any?

        filtered
      end

      def all_versions
        return @all_versions if @version_lookup_attempted

        @version_lookup_attempted = true

        response = Excon.get(
          "https://package.elm-lang.org/packages/#{dependency.name}/"\
          "releases.json",
          idempotent: true,
          **Dependabot::SharedHelpers.excon_defaults
        )

        return @all_versions = [] unless response.status == 200

        @all_versions =
          JSON.parse(response.body).
          keys.
          map { |v| version_class.new(v) }.
          sort
      end

      # Overwrite the base class's requirements_up_to_date? method to instead
      # check whether the latest version is allowed
      def requirements_up_to_date?
        return false unless latest_version

        dependency.requirements.
          map { |r| r.fetch(:requirement) }.
          map { |r| requirement_class.new(r) }.
          all? { |r| r.satisfied_by?(latest_version) }
      end

      def ignore_reqs
        # Note: we use Gem::Requirement here because ignore conditions will
        # be passed as Ruby ranges
        ignored_versions.map { |req| Gem::Requirement.new(req.split(",")) }
      end
    end
  end
end

Dependabot::UpdateCheckers.register("elm", Dependabot::Elm::UpdateChecker)
