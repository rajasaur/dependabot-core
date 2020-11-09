# frozen_string_literal: true

require "toml-rb"
require "dependabot/update_checkers"
require "dependabot/update_checkers/base"

module Dependabot
  module Dep
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      require_relative "update_checker/file_preparer"
      require_relative "update_checker/latest_version_finder"
      require_relative "update_checker/requirements_updater"
      require_relative "update_checker/version_resolver"

      def latest_version
        @latest_version ||=
          LatestVersionFinder.new(
            dependency: dependency,
            dependency_files: dependency_files,
            credentials: credentials,
            ignored_versions: ignored_versions
          ).latest_version
      end

      def latest_resolvable_version
        # We don't yet support updating indirect dependencies for dep
        return dependency.version unless dependency.top_level?

        @latest_resolvable_version ||=
          if modules_dependency?
            latest_version
          elsif git_dependency?
            latest_resolvable_version_for_git_dependency
          else
            latest_resolvable_released_version(unlock_requirement: true)
          end
      end

      def latest_resolvable_version_with_no_unlock
        # We don't yet support updating indirect dependencies for dep
        return dependency.version unless dependency.top_level?

        @latest_resolvable_version_with_no_unlock ||=
          if git_dependency?
            latest_resolvable_commit_with_unchanged_git_source
          else
            latest_resolvable_released_version(unlock_requirement: false)
          end
      end

      def updated_requirements
        @updated_requirements ||=
          RequirementsUpdater.new(
            requirements: dependency.requirements,
            updated_source: updated_source,
            update_strategy: requirements_update_strategy,
            latest_version: latest_version&.to_s,
            latest_resolvable_version: latest_resolvable_version&.to_s
          ).updated_requirements
      end

      def requirements_update_strategy
        # If passed in as an option (in the base class) honour that option
        return @requirements_update_strategy.to_sym if @requirements_update_strategy

        # Otherwise, widen ranges for libraries and bump versions for apps
        library? ? :widen_ranges : :bump_versions
      end

      private

      def latest_version_resolvable_with_full_unlock?
        # Full unlock checks aren't implemented for Go (yet)
        false
      end

      def updated_dependencies_after_full_unlock
        raise NotImplementedError
      end

      # Override the base class's check for whether this is a git dependency,
      # since not all dep git dependencies have a SHA version (sometimes their
      # version is the tag)
      def existing_version_is_sha?
        return git_dependency? if dependency.top_level?

        super
      end

      def library?
        dependency_files.none? { |f| f.type == "package_main" }
      end

      def latest_resolvable_version_for_git_dependency
        return latest_version if modules_dependency?

        latest_release =
          begin
            latest_resolvable_released_version(unlock_requirement: true)
          rescue SharedHelpers::HelperSubprocessFailed => e
            raise unless e.message.include?("Solving failure")
          end

        # If there's a resolvable release that includes the current pinned
        # ref or that the current branch is behind, we switch to that release.
        return latest_release if git_branch_or_ref_in_release?(latest_release)

        # Otherwise, if the gem isn't pinned, the latest version is just the
        # latest commit for the specified branch.
        return latest_resolvable_commit_with_unchanged_git_source unless git_commit_checker.pinned?

        # If the dependency is pinned to a tag that looks like a version then
        # we want to update that tag.
        if git_commit_checker.pinned_ref_looks_like_version? &&
           latest_git_tag_is_resolvable?
          new_tag = git_commit_checker.local_tag_for_latest_version
          return version_from_tag(new_tag)
        end

        # If the dependency is pinned to a tag that doesn't look like a
        # version then there's nothing we can do.
        nil
      end

      def version_from_tag(tag)
        # To compare with the current version we either use the commit SHA
        # (if that's what the parser picked up) of the tag name.
        return tag&.fetch(:commit_sha) if dependency.version&.match?(/^[0-9a-f]{40}$/)

        tag&.fetch(:tag)
      end

      def latest_resolvable_commit_with_unchanged_git_source
        return @latest_resolvable_commit_with_unchanged_git_source if @commit_lookup_attempted

        @commit_lookup_attempted = true
        @latest_resolvable_commit_with_unchanged_git_source ||=
          begin
            prepared_files = FilePreparer.new(
              dependency_files: dependency_files,
              dependency: dependency,
              unlock_requirement: false,
              remove_git_source: false,
              latest_allowable_version: latest_version
            ).prepared_dependency_files

            VersionResolver.new(
              dependency: dependency,
              dependency_files: prepared_files,
              credentials: credentials
            ).latest_resolvable_version
          end
      rescue SharedHelpers::HelperSubprocessFailed => e
        # This should rescue resolvability errors in future
        raise unless e.message.include?("Solving failure")
      end

      def latest_resolvable_released_version(unlock_requirement:)
        @latest_resolvable_released_version ||= {}
        @latest_resolvable_released_version[unlock_requirement] ||=
          begin
            prepared_files = FilePreparer.new(
              dependency_files: dependency_files,
              dependency: dependency,
              unlock_requirement: unlock_requirement,
              remove_git_source: git_dependency?,
              latest_allowable_version: latest_version
            ).prepared_dependency_files

            VersionResolver.new(
              dependency: dependency,
              dependency_files: prepared_files,
              credentials: credentials
            ).latest_resolvable_version
          end
      end

      def latest_git_tag_is_resolvable?
        return @git_tag_resolvable if @latest_git_tag_is_resolvable_checked

        @latest_git_tag_is_resolvable_checked = true

        return false if git_commit_checker.local_tag_for_latest_version.nil?

        replacement_tag = git_commit_checker.local_tag_for_latest_version

        prepared_files = FilePreparer.new(
          dependency: dependency,
          dependency_files: dependency_files,
          unlock_requirement: false,
          remove_git_source: false,
          replacement_git_pin: replacement_tag.fetch(:tag)
        ).prepared_dependency_files

        VersionResolver.new(
          dependency: dependency,
          dependency_files: prepared_files,
          credentials: credentials
        ).latest_resolvable_version

        @git_tag_resolvable = true
      rescue SharedHelpers::HelperSubprocessFailed => e
        # This should rescue resolvability errors in future
        raise unless e.message.include?("Solving failure")

        @git_tag_resolvable = false
      end

      def updated_source
        # Never need to update source, unless a git_dependency
        return dependency_source_details unless git_dependency?

        # Source becomes `nil` if switching to default rubygems
        return default_source if should_switch_source_from_ref_to_release?

        # Update the git tag if updating a pinned version
        if git_commit_checker.pinned_ref_looks_like_version? &&
           latest_git_tag_is_resolvable?
          new_tag = git_commit_checker.local_tag_for_latest_version
          return dependency_source_details.merge(ref: new_tag.fetch(:tag))
        end

        # Otherwise return the original source
        dependency_source_details
      end

      def dependency_source_details
        sources =
          dependency.requirements.map { |r| r.fetch(:source) }.uniq.compact

        raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1

        sources.first
      end

      def should_switch_source_from_ref_to_release?
        return false unless git_dependency?
        return false if latest_resolvable_version_for_git_dependency.nil?

        Gem::Version.correct?(latest_resolvable_version_for_git_dependency)
      end

      def modules_dependency?
        # If dep is being used then we use that to determine the latest
        # version we can update to (since it will have resolvability
        # requirements, whereas Go modules won't)
        !dependency_in_gopkg_lock?
      end

      def dependency_in_gopkg_lock?
        lockfile = dependency_files.find { |f| f.name == "Gopkg.lock" }
        return false unless lockfile

        parsed_file(lockfile).fetch("projects", []).any? do |details|
          details.fetch("name") == dependency.name
        end
      end

      def git_dependency?
        git_commit_checker.git_dependency?
      end

      def default_source
        return { type: "default", source: dependency.name } if modules_dependency?

        original_declaration =
          parsed_file(manifest).
          values_at(*Dep::FileParser::REQUIREMENT_TYPES).
          flatten.compact.
          find { |d| d["name"] == dependency.name }

        {
          type: "default",
          source:
            original_declaration&.fetch("source", nil) || dependency.name
        }
      end

      def git_branch_or_ref_in_release?(release)
        return false unless release

        git_commit_checker.branch_or_ref_in_release?(release)
      end

      def parsed_file(file)
        @parsed_file ||= {}
        @parsed_file[file.name] ||= TomlRB.parse(file.content)
      end

      def manifest
        @manifest ||= dependency_files.find { |f| f.name == "Gopkg.toml" }
      end

      def git_commit_checker
        @git_commit_checker ||=
          GitCommitChecker.new(
            dependency: dependency,
            credentials: credentials,
            ignored_versions: ignored_versions
          )
      end
    end
  end
end

Dependabot::UpdateCheckers.register("dep", Dependabot::Dep::UpdateChecker)
