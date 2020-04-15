# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start
end

require 'rubygems'
require 'rbtrace'

# Loading more in this block will cause your tests to run faster. However,
# if you change any configuration or code from libraries loaded here, you'll
# need to restart spork for it take effect.
require 'fabrication'
require 'mocha/api'
require 'certified'
require 'webmock/rspec'

class RspecErrorTracker

  def self.last_exception=(ex)
    @ex = ex
  end

  def self.last_exception
    @ex
  end

  def initialize(app, config = {})
    @app = app
  end

  def call(env)
    begin
      @app.call(env)
    rescue => e
      RspecErrorTracker.last_exception = e
      raise e
    end
  ensure
  end
end

ENV["RAILS_ENV"] ||= 'test'
require File.expand_path("../../config/environment", __FILE__)
require 'rspec/rails'
require 'shoulda-matchers'
require 'sidekiq/testing'
require 'test_prof/recipes/rspec/let_it_be'
require 'test_prof/before_all/adapters/active_record'

# The shoulda-matchers gem no longer detects the test framework
# you're using or mixes itself into that framework automatically.
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :active_record
    with.library :active_model
  end
end

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.
Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }
Dir[Rails.root.join("spec/fabricators/*.rb")].each { |f| require f }

# Require plugin helpers at plugin/[plugin]/spec/plugin_helper.rb (includes symlinked plugins).
if ENV['LOAD_PLUGINS'] == "1"
  Dir[Rails.root.join("plugins/*/spec/plugin_helper.rb")].each do |f|
    require f
  end
end

# let's not run seed_fu every test
SeedFu.quiet = true if SeedFu.respond_to? :quiet

SiteSetting.automatically_download_gravatars = false

SeedFu.seed

# we need this env var to ensure that we can impersonate in test
# this enable integration_helpers sign_in helper
ENV['DISCOURSE_DEV_ALLOW_ANON_TO_IMPERSONATE'] = '1'

module TestSetup
  # This is run before each test and before each before_all block
  def self.test_setup(x = nil)
    # TODO not sure about this, we could use a mock redis implementation here:
    #   this gives us really clean "flush" semantics, howere the side-effect is that
    #   we are no longer using a clean redis implementation, a preferable solution may
    #   be simply flushing before tests, trouble is that redis may be reused with dev
    #   so that would mean the dev would act weird
    #
    #   perf benefit seems low (shaves 20 secs off a 4 minute test suite)
    #
    # Discourse.redis = DiscourseMockRedis.new

    RateLimiter.disable
    PostActionNotifier.disable
    SearchIndexer.disable
    UserActionManager.disable
    NotificationEmailer.disable
    SiteIconManager.disable

    SiteSetting.provider.all.each do |setting|
      SiteSetting.remove_override!(setting.name)
    end

    # very expensive IO operations
    SiteSetting.automatically_download_gravatars = false

    Discourse.clear_readonly!
    Sidekiq::Worker.clear_all

    I18n.locale = SiteSettings::DefaultsProvider::DEFAULT_LOCALE

    RspecErrorTracker.last_exception = nil

    if $test_cleanup_callbacks
      $test_cleanup_callbacks.reverse_each(&:call)
      $test_cleanup_callbacks = nil
    end

    # in test this is very expensive, we explicitly enable when needed
    Topic.update_featured_topics = false

    # Running jobs are expensive and most of our tests are not concern with
    # code that runs inside jobs. run_later! means they are put on the redis
    # queue and never processed.
    Jobs.run_later!
  end
end

TestProf::BeforeAll.configure do |config|
  config.before(:begin) do
    TestSetup.test_setup
  end
end

if ENV['PREFABRICATION'] == '0'
  module Prefabrication
    def fab!(name, &blk)
      let!(name, &blk)
    end
  end

  RSpec.configure do |config|
    config.extend Prefabrication
  end
else
  TestProf::LetItBe.configure do |config|
    config.alias_to :fab!, refind: true
  end
end

RSpec.configure do |config|
  config.fail_fast = ENV['RSPEC_FAIL_FAST'] == "1"
  config.silence_filter_announcements = ENV['RSPEC_SILENCE_FILTER_ANNOUNCEMENTS'] == "1"
  config.include Helpers
  config.include MessageBus
  config.include RSpecHtmlMatchers
  config.include IntegrationHelpers, type: :request
  config.include WebauthnIntegrationHelpers
  config.include SiteSettingsHelpers
  config.mock_framework = :mocha
  config.order = 'random'
  config.infer_spec_type_from_file_location!

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # If true, the base class of anonymous controllers will be inferred
  # automatically. This will be the default behavior in future versions of
  # rspec-rails.
  config.infer_base_class_for_anonymous_controllers = true

  config.before(:suite) do
    begin
      ActiveRecord::Migration.check_pending!
    rescue ActiveRecord::PendingMigrationError
      raise "There are pending migrations, run RAILS_ENV=test bin/rake db:migrate"
    end

    Sidekiq.error_handlers.clear

    # Ugly, but needed until we have a user creator
    User.skip_callback(:create, :after, :ensure_in_trust_level_group)

    DiscoursePluginRegistry.clear if ENV['LOAD_PLUGINS'] != "1"
    Discourse.current_user_provider = TestCurrentUserProvider

    SiteSetting.refresh!

    # Rebase defaults
    #
    # We nuke the DB storage provider from site settings, so need to yank out the existing settings
    #  and pretend they are default.
    # There are a bunch of settings that are seeded, they must be loaded as defaults
    SiteSetting.current.each do |k, v|
      # skip setting defaults for settings that are in unloaded plugins
      SiteSetting.defaults.set_regardless_of_locale(k, v) if SiteSetting.respond_to? k
    end

    SiteSetting.provider = SiteSettings::LocalProcessProvider.new

    WebMock.disable_net_connect!
  end

  class DiscourseMockRedis < MockRedis
    def without_namespace
      self
    end

    def delete_prefixed(prefix)
      keys("#{prefix}*").each { |k| del(k) }
    end
  end

  config.after :each do |x|
    if x.exception && ex = RspecErrorTracker.last_exception
      # magic in a cause if we have none
      unless x.exception.cause
        class << x.exception
          attr_accessor :cause
        end
        x.exception.cause = ex
      end
    end

    unfreeze_time
    ActionMailer::Base.deliveries.clear

    if ActiveRecord::Base.connection_pool.stat[:busy] > 1
      raise ActiveRecord::Base.connection_pool.stat.inspect
    end
  end

  config.before :each, &TestSetup.method(:test_setup)

  config.before(:each, type: :multisite) do
    Rails.configuration.multisite = true # rubocop:disable Discourse/NoDirectMultisiteManipulation

    RailsMultisite::ConnectionManagement.config_filename =
      "spec/fixtures/multisite/two_dbs.yml"
  end

  config.after(:each, type: :multisite) do
    ActiveRecord::Base.clear_all_connections!
    Rails.configuration.multisite = false # rubocop:disable Discourse/NoDirectMultisiteManipulation
    RailsMultisite::ConnectionManagement.clear_settings!
    ActiveRecord::Base.establish_connection
  end

  class TestCurrentUserProvider < Auth::DefaultCurrentUserProvider
    def log_on_user(user, session, cookies, opts = {})
      session[:current_user_id] = user.id
      super
    end

    def log_off_user(session, cookies)
      session[:current_user_id] = nil
      super
    end
  end

  # Normally we `use_transactional_fixtures` to clear out a database after a test
  # runs. However, this does not apply to tests done for multisite. The second time
  # a test runs you can end up with stale data that breaks things. This method will
  # force a rollback after using a multisite connection.
  def test_multisite_connection(name)
    RailsMultisite::ConnectionManagement.with_connection(name) do
      ActiveRecord::Base.transaction(joinable: false) do
        yield
        raise ActiveRecord::Rollback
      end
    end
  end

end

class TrackTimeStub
  def self.stubbed
    false
  end
end

def before_next_spec(&callback)
  ($test_cleanup_callbacks ||= []) << callback
end

def global_setting(name, value)
  GlobalSetting.reset_s3_cache!

  GlobalSetting.stubs(name).returns(value)

  before_next_spec do
    GlobalSetting.reset_s3_cache!
  end
end

def set_env(var, value)
  old = ENV.fetch var, :missing

  ENV[var] = value

  before_next_spec do
    if old == :missing
      ENV.delete var
    else
      ENV[var] = old
    end
  end
end

def set_cdn_url(cdn_url)
  global_setting :cdn_url, cdn_url
  Rails.configuration.action_controller.asset_host = cdn_url
  ActionController::Base.asset_host = cdn_url

  before_next_spec do
    Rails.configuration.action_controller.asset_host = nil
    ActionController::Base.asset_host = nil
  end
end

def freeze_time(now = Time.now)
  time = now
  datetime = now

  if Time === now
    datetime = now.to_datetime
  elsif DateTime === now
    time = now.to_time
  else
    datetime = DateTime.parse(now.to_s)
    time = Time.parse(now.to_s)
  end

  if block_given?
    raise "nested freeze time not supported" if TrackTimeStub.stubbed
  end

  DateTime.stubs(:now).returns(datetime)
  Time.stubs(:now).returns(time)
  Date.stubs(:today).returns(datetime.to_date)
  TrackTimeStub.stubs(:stubbed).returns(true)

  if block_given?
    begin
      yield
    ensure
      unfreeze_time
    end
  else
    time
  end
end

def unfreeze_time
  DateTime.unstub(:now)
  Time.unstub(:now)
  Date.unstub(:today)
  TrackTimeStub.unstub(:stubbed)
end

def file_from_fixtures(filename, directory = "images")
  FileUtils.mkdir_p("#{Rails.root}/tmp/spec") unless Dir.exists?("#{Rails.root}/tmp/spec")
  FileUtils.cp("#{Rails.root}/spec/fixtures/#{directory}/#{filename}", "#{Rails.root}/tmp/spec/#{filename}")
  File.new("#{Rails.root}/tmp/spec/#{filename}")
end

def has_trigger?(trigger_name)
  DB.exec(<<~SQL) != 0
    SELECT 1
    FROM INFORMATION_SCHEMA.TRIGGERS
    WHERE trigger_name = '#{trigger_name}'
  SQL
end

def silence_stdout
  STDOUT.stubs(:write)
  yield
ensure
  STDOUT.unstub(:write)
end

class TrackingLogger < ::Logger
  attr_reader :messages
  def initialize(level: nil)
    super(nil)
    @messages = []
    @level = level
  end
  def add(*args, &block)
    if !level || args[0].to_i >= level
      @messages << args
    end
  end
end

def track_log_messages(level: nil)
  old_logger = Rails.logger
  logger = Rails.logger = TrackingLogger.new(level: level)
  yield logger.messages
  logger.messages
ensure
  Rails.logger = old_logger
end
