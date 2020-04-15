# frozen_string_literal: true

require "rails_helper"

describe Middleware::RequestTracker do

  def env(opts = {})
    {
      "HTTP_HOST" => "http://test.com",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36",
      "REQUEST_URI" => "/path?bla=1",
      "REQUEST_METHOD" => "GET",
      "HTTP_ACCEPT" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8",
      "rack.input" => ""
    }.merge(opts)
  end

  context "full request" do
    before do
      @orig = WebCrawlerRequest.autoflush
      WebCrawlerRequest.autoflush = 1
    end
    after do
      WebCrawlerRequest.autoflush = @orig
    end

    it "can handle rogue user agents" do
      agent = (+"Evil Googlebot String \xc3\x28").force_encoding("Windows-1252")

      middleware = Middleware::RequestTracker.new(->(env) { ["200", { "Content-Type" => "text/html" }, [""]] })
      middleware.call(env("HTTP_USER_AGENT" => agent))

      expect(WebCrawlerRequest.where(user_agent: agent.encode('utf-8')).count).to eq(1)
    end

  end

  context "log_request" do
    before do
      freeze_time Time.now
      ApplicationRequest.clear_cache!
    end

    def log_tracked_view(val)
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_DISCOURSE_TRACK_VIEW" => val
      ), ["200", { "Content-Type" => 'text/html' }], 0.2)

      Middleware::RequestTracker.log_request(data)
    end

    it "can exclude/include based on custom header" do
      log_tracked_view("true")
      log_tracked_view("1")
      log_tracked_view("false")
      log_tracked_view("0")
      ApplicationRequest.write_cache!

      expect(ApplicationRequest.page_view_anon.first.count).to eq(2)
    end

    it "can log requests correctly" do

      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "AdsBot-Google (+http://www.google.com/adsbot.html)"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      data = Middleware::RequestTracker.get_data(env(
        "HTTP_DISCOURSE_TRACK_VIEW" => "1"
      ), ["200", {}], 0.1)

      Middleware::RequestTracker.log_request(data)

      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 8_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Version/8.0 Mobile/12B410 Safari/600.1.4"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      # /srv/status is never a tracked view because content-type is text/plain
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "kube-probe/1.18",
        "REQUEST_URI" => "/srv/status?shutdown_ok=1",
      ), ["200", { "Content-Type" => 'text/plain' }], 0.1)

      Middleware::RequestTracker.log_request(data)

      ApplicationRequest.write_cache!

      expect(ApplicationRequest.http_total.first.count).to eq(4)
      expect(ApplicationRequest.http_2xx.first.count).to eq(4)

      expect(ApplicationRequest.page_view_anon.first.count).to eq(2)
      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
      expect(ApplicationRequest.page_view_anon_mobile.first.count).to eq(1)

      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
    end

    it "can log Discourse user agent requests correctly" do
      # log discourse api agents as crawlers for page view stats...
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "DiscourseAPI Ruby Gem 0.19.0"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)
      ApplicationRequest.write_cache!
      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)

      # ...but count our mobile app user agents as regular visits
      data = Middleware::RequestTracker.get_data(env(
        "HTTP_USER_AGENT" => "Mozilla/5.0 AppleWebKit/605.1.15 Mobile/15E148 DiscourseHub)"
      ), ["200", { "Content-Type" => 'text/html' }], 0.1)

      Middleware::RequestTracker.log_request(data)
      ApplicationRequest.write_cache!

      expect(ApplicationRequest.page_view_crawler.first.count).to eq(1)
      expect(ApplicationRequest.page_view_anon.first.count).to eq(1)
    end
  end

  context "rate limiting" do

    class TestLogger
      attr_accessor :warnings

      def initialize
        @warnings = 0
      end

      def warn(*args)
        @warnings += 1
      end
    end

    before do
      RateLimiter.enable
      RateLimiter.clear_all_global!

      @old_logger = Rails.logger
      Rails.logger = TestLogger.new
    end

    after do
      RateLimiter.disable
      Rails.logger = @old_logger
    end

    let :middleware do
      app = lambda do |env|
        [200, {}, ["OK"]]
      end

      Middleware::RequestTracker.new(app)
    end

    it "does nothing if configured to do nothing" do
      global_setting :max_reqs_per_ip_mode, "none"
      global_setting :max_reqs_per_ip_per_10_seconds, 1

      status, _ = middleware.call(env)
      status, _ = middleware.call(env)

      expect(status).to eq(200)
    end

    it "blocks private IPs if not skipped" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'
      global_setting :max_reqs_rate_limit_on_private, true

      env1 = env("REMOTE_ADDR" => "127.0.0.2")

      status, _ = middleware.call(env1)
      status, _ = middleware.call(env1)

      expect(Rails.logger.warnings).to eq(1)
      expect(status).to eq(429)
    end

    describe "register_ip_skipper" do
      before do
        Middleware::RequestTracker.register_ip_skipper do |ip|
          ip == "1.1.1.2"
        end
        global_setting :max_reqs_per_ip_per_10_seconds, 1
        global_setting :max_reqs_per_ip_mode, 'block'
      end

      after do
        Middleware::RequestTracker.unregister_ip_skipper
      end

      it "won't block if the ip is skipped" do
        env1 = env("REMOTE_ADDR" => "1.1.1.2")
        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)
        expect(status).to eq(200)
      end

      it "blocks if the ip isn't skipped" do
        env1 = env("REMOTE_ADDR" => "1.1.1.1")
        status, _ = middleware.call(env1)
        status, _ = middleware.call(env1)
        expect(status).to eq(429)
      end
    end

    it "does nothing for private IPs if skipped" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'
      global_setting :max_reqs_rate_limit_on_private, false

      env1 = env("REMOTE_ADDR" => "127.0.3.1")

      status, _ = middleware.call(env1)
      status, _ = middleware.call(env1)

      expect(Rails.logger.warnings).to eq(0)
      expect(status).to eq(200)
    end

    it "does warn if rate limiter is enabled via warn+block" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn+block'

      status, _ = middleware.call(env)
      status, _ = middleware.call(env)

      expect(Rails.logger.warnings).to eq(1)
      expect(status).to eq(429)
    end

    it "does warn if rate limiter is enabled" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'warn'

      status, _ = middleware.call(env)
      status, _ = middleware.call(env)

      expect(Rails.logger.warnings).to eq(1)
      expect(status).to eq(200)
    end

    it "allows assets for more requests" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'block'
      global_setting :max_asset_reqs_per_ip_per_10_seconds, 3

      env1 = env("REMOTE_ADDR" => "1.1.1.1", "DISCOURSE_IS_ASSET_PATH" => 1)

      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, _ = middleware.call(env1)
      expect(status).to eq(200)
      status, _ = middleware.call(env1)
      expect(status).to eq(429)

      env2 = env("REMOTE_ADDR" => "1.1.1.1")

      status, _ = middleware.call(env2)
      expect(status).to eq(429)
    end

    it "does block if rate limiter is enabled" do
      global_setting :max_reqs_per_ip_per_10_seconds, 1
      global_setting :max_reqs_per_ip_mode, 'block'

      env1 = env("REMOTE_ADDR" => "1.1.1.1")
      env2 = env("REMOTE_ADDR" => "1.1.1.2")

      status, _ = middleware.call(env1)
      expect(status).to eq(200)

      status, _ = middleware.call(env1)
      expect(status).to eq(429)

      status, _ = middleware.call(env2)
      expect(status).to eq(200)
    end
  end

  context "callbacks" do
    def app(result, sql_calls: 0, redis_calls: 0)
      lambda do |env|
        sql_calls.times do
          User.where(id: -100).pluck(:id)
        end
        redis_calls.times do
          Discourse.redis.get("x")
        end
        result
      end
    end

    let :logger do
      ->(env, data) do
        @env = env
        @data = data
      end
    end

    before do
      Middleware::RequestTracker.register_detailed_request_logger(logger)
    end

    after do
      Middleware::RequestTracker.unregister_detailed_request_logger(logger)
    end

    it "can report data from anon cache" do
      cache = Middleware::AnonymousCache.new(app([200, {}, ["i am a thing"]]))
      tracker = Middleware::RequestTracker.new(cache)

      uri = "/path?#{SecureRandom.hex}"

      request_params = {
        "a" => "b",
        "action" => "bob",
        "controller" => "jane"
      }

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60, "action_dispatch.request.parameters" => request_params))
      expect(@data[:cache]).to eq("skip")

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60, "action_dispatch.request.parameters" => request_params))
      expect(@data[:cache]).to eq("store")

      tracker.call(env("REQUEST_URI" => uri, "ANON_CACHE_DURATION" => 60))
      expect(@data[:cache]).to eq("true")

      # not whitelisted
      request_params.delete("a")

      expect(@env["action_dispatch.request.parameters"]).to eq(request_params)
    end

    it "can correctly log detailed data" do

      global_setting :enable_performance_http_headers, true

      # ensure pg is warmed up with the select 1 query
      User.where(id: -100).pluck(:id)

      freeze_time
      start = Time.now.to_f

      freeze_time 1.minute.from_now

      tracker = Middleware::RequestTracker.new(app([200, {}, []], sql_calls: 2, redis_calls: 2))
      _, headers, _ = tracker.call(env("HTTP_X_REQUEST_START" => "t=#{start}"))

      expect(@data[:queue_seconds]).to eq(60)

      timing = @data[:timing]
      expect(timing[:total_duration]).to be > 0

      expect(timing[:sql][:duration]).to be > 0
      expect(timing[:sql][:calls]).to eq 2

      expect(timing[:redis][:duration]).to be > 0
      expect(timing[:redis][:calls]).to eq 2

      expect(headers["X-Queue-Time"]).to eq("60.000000")

      expect(headers["X-Redis-Calls"]).to eq("2")
      expect(headers["X-Redis-Time"].to_f).to be > 0

      expect(headers["X-Sql-Calls"]).to eq("2")
      expect(headers["X-Sql-Time"].to_f).to be > 0

      expect(headers["X-Runtime"].to_f).to be > 0
    end
  end

end
