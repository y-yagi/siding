# frozen_string_literal: true

require "digest"
require "rbconfig"

module Siding
  class ProjectKey
    # Long enough that a collision is not a practical concern, short enough that the socket path
    # built from it stays inside the platform's ~100-byte sockaddr_un limit.
    DIGEST_LENGTH = 12

    attr_reader :app_root, :uid, :tool_version, :ruby_version, :app_env

    def self.for(app_root, env: ENV)
      new(
        app_root: app_root,
        uid: Process.uid,
        tool_version: Siding::VERSION,
        ruby_version: RUBY_VERSION,
        app_env: app_env_from(env)
      )
    end

    def self.app_env_from(env)
      value = env["RAILS_ENV"] || env["RACK_ENV"]
      value.nil? || value.empty? ? "development" : value
    end

    def initialize(app_root:, uid:, tool_version:, ruby_version:, app_env:)
      @app_root = File.realpath(app_root)
      @uid = uid
      @tool_version = tool_version
      @ruby_version = ruby_version
      @app_env = app_env
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(fields.join("\0"))[0, DIGEST_LENGTH]
    end

    def label
      "#{File.basename(app_root)}-#{app_env}-#{digest}"
    end

    def fields
      [app_root, uid.to_s, tool_version, ruby_version, app_env]
    end

    def ==(other)
      other.is_a?(ProjectKey) && fields == other.fields
    end
    alias eql? ==

    def hash
      fields.hash
    end

    def to_s = label

    def inspect
      "#<#{self.class} #{label} root=#{app_root} uid=#{uid} tool=#{tool_version} ruby=#{ruby_version}>"
    end
  end
end
