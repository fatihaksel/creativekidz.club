# frozen_string_literal: true

# Ensure that scheduled jobs are loaded before mini_scheduler is configured.
if Rails.env == "development"
  require "jobs/base"
  Dir.glob("#{Rails.root}/app/jobs/scheduled/*.rb") do |f|
    load(f)
  end
end

require "sidekiq/pausable"

Sidekiq.configure_client do |config|
  config.redis = Discourse.sidekiq_redis_config
end

Sidekiq.configure_server do |config|
  config.redis = Discourse.sidekiq_redis_config

  config.server_middleware do |chain|
    chain.add Sidekiq::Pausable
  end
end

MiniScheduler.configure do |config|

  config.redis = Discourse.redis

  config.job_exception_handler do |ex, context|
    Discourse.handle_job_exception(ex, context)
  end

  config.job_ran do |stat|
    DiscourseEvent.trigger(:scheduled_job_ran, stat)
  end

  config.skip_schedule { Sidekiq.paused? }

  config.before_sidekiq_web_request do
    RailsMultisite::ConnectionManagement.establish_connection(
      db: RailsMultisite::ConnectionManagement::DEFAULT
    )
  end

end

if Sidekiq.server?

  module Sidekiq
    class CLI
      private

      def print_banner
        # banner takes up too much space
      end
    end
  end

  # defer queue should simply run in sidekiq
  Scheduler::Defer.async = false

  # warm up AR
  RailsMultisite::ConnectionManagement.safe_each_connection do
    (ActiveRecord::Base.connection.tables - %w[schema_migrations versions]).each do |table|
      table.classify.constantize.first rescue nil
    end
  end

  Rails.application.config.after_initialize do
    scheduler_hostname = ENV["UNICORN_SCHEDULER_HOSTNAME"]

    if !scheduler_hostname || scheduler_hostname.split(',').include?(Discourse.os_hostname)
      MiniScheduler.start(workers: GlobalSetting.mini_scheduler_workers)
    end
  end
end

Sidekiq.logger.level = Logger::WARN

class SidekiqLogsterReporter < Sidekiq::ExceptionHandler::Logger
  def call(ex, context = {})

    return if Jobs::HandledExceptionWrapper === ex
    Discourse.reset_active_record_cache_if_needed(ex)

    # Pass context to Logster
    fake_env = {}
    context.each do |key, value|
      Logster.add_to_env(fake_env, key, value)
    end

    text = "Job exception: #{ex}\n"
    if ex.backtrace
      Logster.add_to_env(fake_env, :backtrace, ex.backtrace)
    end

    Logster.add_to_env(fake_env, :current_hostname, Discourse.current_hostname)

    Thread.current[Logster::Logger::LOGSTER_ENV] = fake_env
    Logster.logger.error(text)
  rescue => e
    Logster.logger.fatal("Failed to log exception #{ex} #{hash}\nReason: #{e.class} #{e}\n#{e.backtrace.join("\n")}")
  ensure
    Thread.current[Logster::Logger::LOGSTER_ENV] = nil
  end
end

Sidekiq.error_handlers.clear
Sidekiq.error_handlers << SidekiqLogsterReporter.new
