# frozen_string_literal: true

require "nokogiri"
require "dependabot/shared_helpers"
require "dependabot/gradle/file_parser/repositories_finder"
require "dependabot/gradle/update_checker"
require "dependabot/gradle/version"
require "dependabot/gradle/requirement"

module Dependabot
  module Gradle
    class UpdateChecker
      class VersionFinder
        GOOGLE_MAVEN_REPO = "https://maven.google.com"
        GRADLE_PLUGINS_REPO = "https://plugins.gradle.org/m2"
        TYPE_SUFFICES = %w(jre android java).freeze

        GRADLE_RANGE_REGEX = /[\(\[].*,.*[\)\]]/.freeze

        def initialize(dependency:, dependency_files:, credentials:,
                       ignored_versions:, raise_on_ignored: false,
                       security_advisories:)
          @dependency          = dependency
          @dependency_files    = dependency_files
          @credentials         = credentials
          @ignored_versions    = ignored_versions
          @raise_on_ignored    = raise_on_ignored
          @security_advisories = security_advisories
          @forbidden_urls      = []
        end

        def latest_version_details
          possible_versions = versions

          possible_versions = filter_prereleases(possible_versions)
          possible_versions = filter_date_based_versions(possible_versions)
          possible_versions = filter_version_types(possible_versions)
          possible_versions = filter_ignored_versions(possible_versions)

          possible_versions.last
        end

        def lowest_security_fix_version_details
          possible_versions = versions

          possible_versions = filter_prereleases(possible_versions)
          possible_versions = filter_date_based_versions(possible_versions)
          possible_versions = filter_version_types(possible_versions)
          possible_versions = filter_vulnerable_versions(possible_versions)
          possible_versions = filter_ignored_versions(possible_versions)
          possible_versions = filter_lower_versions(possible_versions)

          possible_versions.first
        end

        def versions
          version_details =
            repositories.map do |repository_details|
              url = repository_details.fetch("url")
              next google_version_details if url == GOOGLE_MAVEN_REPO

              dependency_metadata(repository_details).css("versions > version").
                select { |node| version_class.correct?(node.content) }.
                map { |node| version_class.new(node.content) }.
                map { |version| { version: version, source_url: url } }
            end.flatten.compact

          raise PrivateSourceAuthenticationFailure, forbidden_urls.first if version_details.none? && forbidden_urls.any?

          version_details.sort_by { |details| details.fetch(:version) }
        end

        private

        attr_reader :dependency, :dependency_files, :credentials,
                    :ignored_versions, :forbidden_urls, :security_advisories

        def filter_prereleases(possible_versions)
          return possible_versions if wants_prerelease?

          possible_versions.reject { |v| v.fetch(:version).prerelease? }
        end

        def filter_date_based_versions(possible_versions)
          return possible_versions if wants_date_based_version?

          possible_versions.
            reject { |v| v.fetch(:version) > version_class.new(1900) }
        end

        def filter_version_types(possible_versions)
          possible_versions.
            select { |v| matches_dependency_version_type?(v.fetch(:version)) }
        end

        def filter_ignored_versions(possible_versions)
          filtered = possible_versions

          ignored_versions.each do |req|
            ignore_req = Gradle::Requirement.new(parse_requirement_string(req))
            filtered =
              filtered.
              reject { |v| ignore_req.satisfied_by?(v.fetch(:version)) }
          end

          raise AllVersionsIgnored if @raise_on_ignored && filtered.empty? && possible_versions.any?

          filtered
        end

        def filter_vulnerable_versions(possible_versions)
          versions_array = possible_versions

          security_advisories.each do |advisory|
            versions_array =
              versions_array.
              reject { |v| advisory.vulnerable?(v.fetch(:version)) }
          end

          versions_array
        end

        def filter_lower_versions(possible_versions)
          possible_versions.select do |v|
            v.fetch(:version) > version_class.new(dependency.version)
          end
        end

        def parse_requirement_string(string)
          return string if string.match?(GRADLE_RANGE_REGEX)

          string.split(",").map(&:strip)
        end

        def wants_prerelease?
          return false unless dependency.version
          return false unless version_class.correct?(dependency.version)

          version_class.new(dependency.version).prerelease?
        end

        def wants_date_based_version?
          return false unless dependency.version
          return false unless version_class.correct?(dependency.version)

          version_class.new(dependency.version) >= version_class.new(100)
        end

        def google_version_details
          url = GOOGLE_MAVEN_REPO
          group_id, artifact_id = group_and_artifact_ids

          dependency_metadata_url = "#{GOOGLE_MAVEN_REPO}/"\
                                    "#{group_id.tr('.', '/')}/"\
                                    "group-index.xml"

          @google_version_details ||=
            begin
              response = Excon.get(
                dependency_metadata_url,
                idempotent: true,
                **SharedHelpers.excon_defaults
              )
              Nokogiri::XML(response.body)
            end

          xpath = "/#{group_id}/#{artifact_id}"
          return unless @google_version_details.at_xpath(xpath)

          @google_version_details.at_xpath(xpath).
            attributes.fetch("versions").
            value.split(",").
            select { |v| version_class.correct?(v) }.
            map { |v| version_class.new(v) }.
            map { |version| { version: version, source_url: url } }
        rescue Nokogiri::XML::XPath::SyntaxError
          nil
        end

        def dependency_metadata(repository_details)
          @dependency_metadata ||= {}
          @dependency_metadata[repository_details.hash] ||=
            begin
              response = Excon.get(
                dependency_metadata_url(repository_details.fetch("url")),
                user: repository_details.fetch("username"),
                password: repository_details.fetch("password"),
                idempotent: true,
                **SharedHelpers.excon_defaults
              )
              check_response(response, repository_details.fetch("url"))
              Nokogiri::XML(response.body)
            rescue URI::InvalidURIError
              Nokogiri::XML("")
            rescue Excon::Error::Socket, Excon::Error::Timeout,
                   Excon::Error::TooManyRedirects
              raise if central_repo_urls.include?(repository_details["url"])

              Nokogiri::XML("")
            end
        end

        def repository_urls
          plugin? ? plugin_repository_details : dependency_repository_details
        end

        def check_response(response, repository_url)
          return unless [401, 403].include?(response.status)
          return if @forbidden_urls.include?(repository_url)
          return if central_repo_urls.include?(repository_url)

          @forbidden_urls << repository_url
        end

        def repositories
          return @repositories if @repositories

          details = if plugin?
                      plugin_repository_details +
                        credentials_repository_details
                    else
                      dependency_repository_details +
                        credentials_repository_details
                    end

          @repositories =
            details.reject do |repo|
              next if repo["password"]

              # Reject this entry if an identical one with a password exists
              details.any? { |r| r["url"] == repo["url"] && r["password"] }
            end
        end

        def credentials_repository_details
          credentials.
            select { |cred| cred["type"] == "maven_repository" }.
            map do |cred|
            {
              "url" => cred.fetch("url").gsub(%r{/+$}, ""),
              "username" => cred.fetch("username", nil),
              "password" => cred.fetch("password", nil)
            }
          end
        end

        def dependency_repository_details
          requirement_files =
            dependency.requirements.
            map { |r| r.fetch(:file) }.
            map { |nm| dependency_files.find { |f| f.name == nm } }

          @dependency_repository_details ||=
            requirement_files.flat_map do |target_file|
              Gradle::FileParser::RepositoriesFinder.new(
                dependency_files: dependency_files,
                target_dependency_file: target_file
              ).repository_urls.
                map do |url|
                  { "url" => url, "username" => nil, "password" => nil }
                end
            end.uniq
        end

        def plugin_repository_details
          [{
            "url" => GRADLE_PLUGINS_REPO,
            "username" => nil,
            "password" => nil
          }] + dependency_repository_details
        end

        def matches_dependency_version_type?(comparison_version)
          return true unless dependency.version

          current_type = dependency.version.split(/[.\-]/).
                         find do |type|
                           TYPE_SUFFICES.
                             find { |s| type.include?(s) }
                         end

          version_type = comparison_version.to_s.split(/[.\-]/).
                         find do |type|
                           TYPE_SUFFICES.
                             find { |s| type.include?(s) }
                         end

          current_type == version_type
        end

        def pom
          filename = dependency.requirements.first.fetch(:file)
          dependency_files.find { |f| f.name == filename }
        end

        def dependency_metadata_url(repository_url)
          group_id, artifact_id = group_and_artifact_ids

          "#{repository_url}/"\
          "#{group_id.tr('.', '/')}/"\
          "#{artifact_id}/"\
          "maven-metadata.xml"
        end

        def group_and_artifact_ids
          if plugin?
            [dependency.name, "#{dependency.name}.gradle.plugin"]
          else
            dependency.name.split(":")
          end
        end

        def plugin?
          dependency.requirements.any? { |r| r.fetch(:groups) == ["plugins"] }
        end

        def central_repo_urls
          central_url_without_protocol =
            Gradle::FileParser::RepositoriesFinder::CENTRAL_REPO_URL.
            gsub(%r{^.*://}, "")

          %w(http:// https://).map { |p| p + central_url_without_protocol }
        end

        def version_class
          Gradle::Version
        end
      end
    end
  end
end
