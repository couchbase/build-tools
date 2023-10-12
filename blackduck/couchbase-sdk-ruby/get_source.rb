#!/usr/bin/env ruby
# frozen_string_literal: true

# This script fetches the source package for Couchbase Ruby SDK from
# rubygems.org and unpacks them to "couchbase-ruby-sdk" directory.

require "net/http"
require "digest/sha2"
require "json"
require "fileutils"
require "rubygems/package"
require "pp"

# the version that will be used in the report
VERSION = ARGV[0] || "main"

# the SHA1 or branch name that will be used to rebuild sources into .gem file
# if rubygems.org does not have the source package for the given version
RELEASE = ARGV[1] || VERSION

WORKSPACE = Dir.pwd
# the directory, where the sources will be unpacked to
SOURCE_DIR = File.join(WORKSPACE, "couchbase-ruby-client")

# The script will try to pull couchbase-RELEASE.gem from rubygems.org,
# and if it doesn't exist, it will try to pull RELEASE commit from the git
# repository and build couchbase.gem from it.

def sha256(filename)
  Digest::SHA256.file(filename).hexdigest
end

# Lightweight implementation of the rubygems API
class API
  def initialize
    @client = Net::HTTP.start("rubygems.org", 443, use_ssl: true)
  end

  def versions
    request = Net::HTTP::Get.new("/api/v1/versions/couchbase.json")
    request["accept"] = "application/json"
    response = @client.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      abort "Could not get versions from rubygems.org: #{response.code} #{response.message}\n" \
            "#{response.body}"
    end
    JSON.parse(response.body)
  end

  def download(release)
    version_number = release["number"]
    filename = File.join(WORKSPACE, "couchbase-#{version_number}.gem")
    return filename if File.exist?(filename) && sha256(filename) == release["sha"]

    request = Net::HTTP::Get.new("/downloads/couchbase-#{version_number}.gem")
    response = @client.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      abort "Could not download version #{version_number} from rubygems.org: #{response.code} #{response.message}"
    end
    File.write(filename, response.body)
    filename
  end
end

def run(*args)
  args = args.compact.map(&:to_s)
  cmd_line = args.join(" ")
  puts cmd_line
  system(*args) || abort("command returned non-zero status: #{cmd_line}")
end

def pull_sources_and_build_gem(commit)
  FileUtils.rm_rf(SOURCE_DIR, verbose: true)
  run("git clone https://github.com/couchbase/couchbase-ruby-client #{SOURCE_DIR}")
  Dir.chdir(SOURCE_DIR) do
    run("git checkout #{commit}")
    run("git submodule update --init --recursive")
    run("./bin/setup")
    run("bundle exec rake build")
  end
  filename = File.join(WORKSPACE, "couchbase-#{commit}.gem")
  FileUtils.cp(Dir["#{SOURCE_DIR}/pkg/couchbase-*.gem"].first, filename)
  FileUtils.rm_rf(SOURCE_DIR, verbose: true)
  filename
end

rubygems = API.new

release = rubygems.versions.find { |v| v["number"] == RELEASE }
gem_file =
  if release
    puts "Found version #{RELEASE} on rubygems: #{release.pretty_inspect}"
    rubygems.download(release)
  else
    puts "Version #{RELEASE} does not exist on rubygems, will checkout git repository and rebuild .gem file"
    pull_sources_and_build_gem(RELEASE)
  end
source_dir = gem_file.sub(/\.gem$/, "")
FileUtils.rm_rf(source_dir, verbose: true)
run("gem unpack #{gem_file}")
package = Gem::Package.new(gem_file)
FileUtils.rm_rf(SOURCE_DIR, verbose: true)
FileUtils.mv(source_dir, SOURCE_DIR, verbose: true)
Dir.chdir(SOURCE_DIR) do
  File.write("couchbase.gemspec", package.spec.to_ruby)
  File.write("Gemfile", "source 'https://rubygems.org'\ngemspec")
  run("bundle install") # generate Gemfile.lock to get HIGH accuracy, as .gemspec gives only LOW
end
FileUtils.rm_rf(gem_file, verbose: true)
