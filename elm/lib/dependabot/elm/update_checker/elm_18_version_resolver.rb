# frozen_string_literal: true

require "open3"
require "dependabot/shared_helpers"
require "dependabot/errors"
require "dependabot/elm/file_parser"
require "dependabot/elm/update_checker"
require "dependabot/elm/update_checker/cli_parser"
require "dependabot/elm/update_checker/requirements_updater"
require "dependabot/elm/requirement"

module Dependabot
  module Elm
    class UpdateChecker
      class Elm18VersionResolver
        class UnrecoverableState < StandardError; end

        def initialize(dependency:, dependency_files:, candidate_versions:)
          @dependency = dependency
          @dependency_files = dependency_files
          @candidate_versions = candidate_versions
        end

        def latest_resolvable_version(unlock_requirement:)
          raise "Invalid unlock setting: #{unlock_requirement}" unless %i(none own all).include?(unlock_requirement)

          # Elm has no lockfile, so we will never create an update PR if
          # unlock requirements are `none`. Just return the current version.
          return current_version if unlock_requirement == :none

          # Otherwise, we gotta check a few conditions to see if bumping
          # wouldn't also bump other deps in elm-package.json
          candidate_versions.sort.reverse_each do |version|
            return version if can_update?(version, unlock_requirement)
          end

          # Fall back to returning the dependency's current version, which is
          # presumed to be resolvable
          current_version
        end

        def updated_dependencies_after_full_unlock
          version = latest_resolvable_version(unlock_requirement: :all)
          deps_after_install = fetch_install_metadata(target_version: version)

          original_dependency_details.map do |original_dep|
            new_version = deps_after_install.fetch(original_dep.name)

            old_reqs = original_dep.requirements.map do |req|
              requirement_class.new(req[:requirement])
            end

            next if old_reqs.all? { |req| req.satisfied_by?(new_version) }

            new_requirements =
              RequirementsUpdater.new(
                requirements: original_dep.requirements,
                latest_resolvable_version: new_version.to_s
              ).updated_requirements

            Dependency.new(
              name: original_dep.name,
              version: new_version.to_s,
              requirements: new_requirements,
              previous_version: original_dep.version,
              previous_requirements: original_dep.requirements,
              package_manager: original_dep.package_manager
            )
          end.compact
        end

        private

        attr_reader :dependency, :dependency_files, :candidate_versions

        def can_update?(version, unlock_requirement)
          deps_after_install = fetch_install_metadata(target_version: version)

          result = check_install_result(deps_after_install, version)

          # If the install was clean then we can definitely update
          return true if result == :clean_bump

          # Otherwise, we can still update if the result was a forced full
          # unlock and we're allowed to unlock other requirements
          return false unless unlock_requirement == :all

          result == :forced_full_unlock_bump
        end

        def check_install_result(deps_after_install, target_version)
          # This can go one of 5 ways:
          # 1) We bump our dep and no other dep is bumped
          # 2) We bump our dep and another dep is bumped too
          #    Scenario: NoRedInk/datetimepicker bump to 3.0.2 also
          #              bumps elm-css to 14
          # 3) We bump our dep but actually elm-package doesn't bump it
          #    Scenario: elm-css bump to 14 but datetimepicker is at 3.0.1
          # 4) We bump our dep but elm-package just says
          #    "Packages configured successfully!"
          #    Narrator: they weren't
          #    Scenario: impossible dependency (i.e. elm-css 999.999.999)
          #              a <= v < b where a is greater than latest version
          # 5) We bump our dep but elm-package blows up (not handled here)
          #    Scenario: rtfeldman/elm-css 14 && rtfeldman/hashed-class 1.0.0
          #              I'm not sure what's different from this scenario
          #              to 3), why it blows up instead of just rolling
          #              elm-css back to version 9 which is what
          #              hashed-class requires

          # 4) We bump our dep but elm-package just says
          #    "Packages configured successfully!"
          return :empty_elm_stuff_bug if deps_after_install.empty?

          version_after_install = deps_after_install.fetch(dependency.name)

          # 3) We bump our dep but actually elm-package doesn't bump it
          return :downgrade_bug if version_after_install < target_version

          other_top_level_deps_bumped =
            original_dependency_details.
            reject { |dep| dep.name == dependency.name }.
            select do |dep|
              reqs = dep.requirements.map { |r| r.fetch(:requirement) }
              reqs = reqs.map { |r| requirement_class.new(r) }
              reqs.any? { |r| !r.satisfied_by?(deps_after_install[dep.name]) }
            end

          # 2) We bump our dep and another dep is bumped
          return :forced_full_unlock_bump if other_top_level_deps_bumped.any?

          # 1) We bump our dep and no other dep is bumped
          :clean_bump
        end

        def fetch_install_metadata(target_version:)
          @install_cache ||= {}
          @install_cache[target_version.to_s] ||=
            SharedHelpers.in_a_temporary_directory do
              write_temporary_dependency_files(target_version: target_version)

              # Elm package install outputs a preview of the actions to be
              # performed. We can use this preview to calculate whether it
              # would do anything funny
              command = "yes n | elm-package install"
              response = run_shell_command(command)

              deps_after_install = CliParser.decode_install_preview(response)

              deps_after_install
            rescue SharedHelpers::HelperSubprocessFailed => e
              # 5) We bump our dep but elm-package blows up
              handle_elm_package_errors(e)
            end
        end

        def run_shell_command(command)
          start = Time.now
          stdout, process = Open3.capture2e(command)
          time_taken = Time.now - start

          # Raise an error with the output from the shell session if Elm
          # returns a non-zero status
          return stdout if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        def handle_elm_package_errors(error)
          if error.message.include?("I cannot find a set of packages that " \
                                    "works with your constraints")
            raise Dependabot::DependencyFileNotResolvable, error.message
          end

          if error.message.include?("You are using Elm 0.18.0, but")
            raise Dependabot::DependencyFileNotResolvable, error.message
          end

          # I don't know any other errors
          raise error
        end

        def write_temporary_dependency_files(target_version:)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)

            File.write(
              path,
              updated_elm_package_content(file.content, target_version)
            )
          end
        end

        def updated_elm_package_content(content, version)
          json = JSON.parse(content)

          new_requirement = RequirementsUpdater.new(
            requirements: dependency.requirements,
            latest_resolvable_version: version.to_s
          ).updated_requirements.first[:requirement]

          json["dependencies"][dependency.name] = new_requirement
          JSON.dump(json)
        end

        def original_dependency_details
          @original_dependency_details ||=
            Elm::FileParser.new(
              dependency_files: dependency_files,
              source: nil
            ).parse
        end

        def current_version
          return unless dependency.version

          version_class.new(dependency.version)
        end

        def version_class
          Elm::Version
        end

        def requirement_class
          Elm::Requirement
        end
      end
    end
  end
end
