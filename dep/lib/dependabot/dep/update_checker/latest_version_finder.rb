# frozen_string_literal: true

require "excon"
require "toml-rb"

require "dependabot/source"
require "dependabot/dep/update_checker"
require "dependabot/git_commit_checker"
require "dependabot/dep/path_converter"

module Dependabot
  module Dep
    class UpdateChecker
      class LatestVersionFinder
        def initialize(dependency:, dependency_files:, credentials:,
                       ignored_versions:)
          @dependency       = dependency
          @dependency_files = dependency_files
          @credentials      = credentials
          @ignored_versions = ignored_versions
        end

        def latest_version
          @latest_version ||=
            if git_dependency? then latest_version_for_git_dependency
            else latest_release_tag_version
            end
        end

        private

        attr_reader :dependency, :dependency_files, :credentials,
                    :ignored_versions

        def latest_release_tag_version
          return @latest_release_tag_version if @latest_release_tag_lookup_attempted

          @latest_release_tag_lookup_attempted = true

          latest_release_str = fetch_latest_release_tag&.sub(/^v?/, "")
          return unless latest_release_str
          return unless version_class.correct?(latest_release_str)

          @latest_release_tag_version =
            version_class.new(latest_release_str)
        end

        def fetch_latest_release_tag
          # If this is a git dependency then getting the latest tag is trivial
          if git_dependency?
            return git_commit_checker.
                   local_tag_for_latest_version&.fetch(:tag)
          end

          # If not, we need to find the URL for the source code.
          path = dependency.requirements.
                 map { |r| r.dig(:source, :source) }.compact.first
          path ||= dependency.name

          source_url = git_source(path)
          return unless source_url

          # Given a source, we want to find the latest tag. Piggy-back off the
          # logic in GitCommitChecker to do so.
          git_dep = Dependency.new(
            name: dependency.name,
            version: dependency.version,
            requirements: [{
              file: "Gopkg.toml",
              groups: [],
              requirement: nil,
              source: { type: "git", url: source_url, ref: nil, branch: nil }
            }],
            package_manager: dependency.package_manager
          )

          GitCommitChecker.
            new(dependency: git_dep, credentials: credentials).
            local_tag_for_latest_version&.fetch(:tag)
        end

        def latest_version_for_git_dependency
          latest_release = latest_release_tag_version

          # If there's been a release that includes the current pinned ref or
          # that the current branch is behind, we switch to that release.
          return latest_release if branch_or_ref_in_release?(latest_release)

          # Otherwise, if the gem isn't pinned, the latest version is just the
          # latest commit for the specified branch.
          return git_commit_checker.head_commit_for_current_branch unless git_commit_checker.pinned?

          # If the dependency is pinned to a tag that looks like a version
          # then we want to update that tag.
          if git_commit_checker.pinned_ref_looks_like_version?
            latest_tag = git_commit_checker.local_tag_for_latest_version
            return version_from_tag(latest_tag)
          end

          # If the dependency is pinned to a tag that doesn't look like a
          # version then there's nothing we can do.
          nil
        end

        def git_source(path)
          Dependabot::Dep::PathConverter.git_url_for_path(path)
        end

        def version_from_tag(tag)
          # To compare with the current version we either use the commit SHA
          # (if that's what the parser picked up) of the tag name.
          return tag&.fetch(:commit_sha) if dependency.version&.match?(/^[0-9a-f]{40}$/)

          tag&.fetch(:tag)
        end

        def branch_or_ref_in_release?(release)
          return false unless release

          git_commit_checker.branch_or_ref_in_release?(release)
        end

        def git_dependency?
          git_commit_checker.git_dependency?
        end

        def git_commit_checker
          @git_commit_checker ||=
            GitCommitChecker.new(
              dependency: dependency,
              credentials: credentials,
              ignored_versions: ignored_versions
            )
        end

        def parsed_file(file)
          @parsed_file ||= {}
          @parsed_file[file.name] ||= TomlRB.parse(file.content)
        end

        def version_class
          Utils.version_class_for_package_manager(dependency.package_manager)
        end

        def manifest
          @manifest ||= dependency_files.find { |f| f.name == "Gopkg.toml" }
          raise "No Gopkg.lock!" unless @manifest

          @manifest
        end

        def lockfile
          @lockfile = dependency_files.find { |f| f.name == "Gopkg.lock" }
          raise "No Gopkg.lock!" unless @lockfile

          @lockfile
        end
      end
    end
  end
end
