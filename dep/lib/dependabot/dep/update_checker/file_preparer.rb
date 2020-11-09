# frozen_string_literal: true

require "toml-rb"
require "dependabot/dependency_file"
require "dependabot/dep/file_parser"
require "dependabot/dep/update_checker"

module Dependabot
  module Dep
    class UpdateChecker
      # This class takes a set of dependency files and prepares them for use
      # in Dep::UpdateChecker.
      class FilePreparer
        def initialize(dependency_files:, dependency:,
                       remove_git_source: false,
                       unlock_requirement: true,
                       replacement_git_pin: nil,
                       latest_allowable_version: nil)
          @dependency_files         = dependency_files
          @dependency               = dependency
          @unlock_requirement       = unlock_requirement
          @remove_git_source        = remove_git_source
          @replacement_git_pin      = replacement_git_pin
          @latest_allowable_version = latest_allowable_version
        end

        def prepared_dependency_files
          files = []

          files << manifest_for_update_check
          files << lockfile if lockfile

          files
        end

        private

        attr_reader :dependency_files, :dependency, :replacement_git_pin,
                    :latest_allowable_version

        def unlock_requirement?
          @unlock_requirement
        end

        def remove_git_source?
          @remove_git_source
        end

        def replace_git_pin?
          !replacement_git_pin.nil?
        end

        def manifest_for_update_check
          DependencyFile.new(
            name: manifest.name,
            content: manifest_content_for_update_check(manifest),
            directory: manifest.directory
          )
        end

        def manifest_content_for_update_check(file)
          content = file.content

          content = remove_git_source(content) if remove_git_source?
          content = replace_git_pin(content) if replace_git_pin?
          content = replace_version_constraint(content, file.name)
          content = add_fsnotify_override(content)

          content
        end

        def remove_git_source(content)
          parsed_manifest = TomlRB.parse(content)

          Dep::FileParser::REQUIREMENT_TYPES.each do |type|
            (parsed_manifest[type] || []).each do |details|
              next unless details["name"] == dependency.name

              details.delete("revision")
              details.delete("branch")
            end
          end

          TomlRB.dump(parsed_manifest)
        end

        def replace_git_pin(content)
          parsed_manifest = TomlRB.parse(content)

          Dep::FileParser::REQUIREMENT_TYPES.each do |type|
            (parsed_manifest[type] || []).each do |details|
              next unless details["name"] == dependency.name

              raise "Invalid details! #{details}" if details["branch"]

              if details["version"]
                details["version"] = replacement_git_pin
              else
                details["revision"] = replacement_git_pin
              end
            end
          end

          TomlRB.dump(parsed_manifest)
        end

        # Note: We don't need to care about formatting in this method, since
        # we're only using the manifest to find the latest resolvable version
        def replace_version_constraint(content, filename)
          parsed_manifest = TomlRB.parse(content)

          Dep::FileParser::REQUIREMENT_TYPES.each do |type|
            (parsed_manifest[type] || []).each do |details|
              next unless details["name"] == dependency.name
              next if details["revision"] || details["branch"]
              next if replacement_git_pin

              updated_req = temporary_requirement_for_resolution(filename)

              details["version"] = updated_req
            end
          end

          TomlRB.dump(parsed_manifest)
        end

        # A dep bug means we have to specify a source for gopkg.in/fsnotify.v1
        # or we get `panic: version queue is empty` errors
        def add_fsnotify_override(content)
          parsed_manifest = TomlRB.parse(content)

          overrides = parsed_manifest.fetch("override", [])
          dep_name = "gopkg.in/fsnotify.v1"

          override = overrides.find { |s| s["name"] == dep_name }
          if override.nil?
            override = { "name" => dep_name }
            overrides << override
          end

          override["source"] = "gopkg.in/fsnotify/fsnotify.v1" unless override["source"]

          parsed_manifest["override"] = overrides
          TomlRB.dump(parsed_manifest)
        end

        def temporary_requirement_for_resolution(filename)
          original_req = dependency.requirements.
                         find { |r| r.fetch(:file) == filename }&.
                         fetch(:requirement)

          lower_bound_req =
            if original_req && !unlock_requirement?
              original_req
            else
              ">= #{lower_bound_version}"
            end

          unless latest_allowable_version &&
                 version_class.correct?(latest_allowable_version) &&
                 version_class.new(latest_allowable_version) >=
                 version_class.new(lower_bound_version)
            return lower_bound_req
          end

          lower_bound_req + ", <= #{latest_allowable_version}"
        end

        # rubocop:disable Metrics/PerceivedComplexity
        def lower_bound_version
          @lower_bound_version ||=
            if version_from_lockfile
              version_from_lockfile
            else
              version_from_requirement =
                dependency.requirements.map { |r| r.fetch(:requirement) }.
                compact.
                flat_map { |req_str| requirement_class.new(req_str) }.
                flat_map(&:requirements).
                reject { |req_array| req_array.first.start_with?("<") }.
                map(&:last).
                max&.to_s

              version_from_requirement || 0
            end
        end
        # rubocop:enable Metrics/PerceivedComplexity

        def version_from_lockfile
          return unless lockfile

          TomlRB.parse(lockfile.content).
            fetch("projects", []).
            find { |p| p["name"] == dependency.name }&.
            fetch("version", nil)&.
            sub(/^v?/, "")
        end

        def version_class
          Utils.version_class_for_package_manager(dependency.package_manager)
        end

        def requirement_class
          Utils.requirement_class_for_package_manager(
            dependency.package_manager
          )
        end

        def manifest
          @manifest ||= dependency_files.find { |f| f.name == "Gopkg.toml" }
        end

        def lockfile
          @lockfile ||= dependency_files.find { |f| f.name == "Gopkg.lock" }
        end
      end
    end
  end
end
