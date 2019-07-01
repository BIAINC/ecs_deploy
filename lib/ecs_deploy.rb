# frozen_string_literal: true

require 'ecs_deploy/version'
require 'ecs_deploy/configuration'

require 'aws-sdk-ecs'
require 'logger'
require 'terminal-table'
require 'paint'

module EcsDeploy
  def self.logger
    @logger ||= Logger.new(STDOUT).tap do |l|
      l.level = Logger.const_get(config.log_level.to_s.upcase)
    end
  end

  def self.config
    @config ||= Configuration.new
  end

  def self.configure
    if block_given?
      yield config
      @logger = nil
    end
  end
end

require 'ecs_deploy/task_definition'
require 'ecs_deploy/service'
require 'ecs_deploy/scheduled_task'
require 'ecs_deploy/execute'
require 'ecs_deploy/log_tail'