# frozen_string_literal: true

# rake docker:test is designed to be used inside the discourse/docker_test image
# running it anywhere else will likely fail
#
# Environment Variables (specific to this rake task)
# => SKIP_LINT                 set to 1 to skip linting (eslint and rubocop)
# => SKIP_TESTS                set to 1 to skip all tests
# => SKIP_CORE                 set to 1 to skip core tests (rspec and qunit)
# => SKIP_PLUGINS              set to 1 to skip plugin tests (rspec and qunit)
# => INSTALL_OFFICIAL_PLUGINS  set to 1 to install all core plugins before running tests
# => RUBY_ONLY                 set to 1 to skip all qunit tests
# => JS_ONLY                   set to 1 to skip all rspec tests
# => SINGLE_PLUGIN             set to plugin name to only run plugin-specific rspec tests (you'll probably want to SKIP_CORE as well)
# => BISECT                    set to 1 to run rspec --bisect (applies to core rspec tests only)
# => RSPEC_SEED                set to seed to use for rspec tests (applies to core rspec tests only)
# => PAUSE_ON_TERMINATE        set to 1 to pause prior to terminating redis and pg
# => JS_TIMEOUT                set timeout for qunit tests in ms
# => WARMUP_TMP_FOLDER runs a single spec to warmup the tmp folder and obtain accurate results when profiling specs.
#
# Other useful environment variables (not specific to this rake task)
# => COMMIT_HASH    used by the discourse_test docker image to load a specific commit of discourse
#                   this can also be set to a branch, e.g. "origin/tests-passed"
#
# Example usage:
#   Run all core and plugin tests:
#       docker run discourse/discourse_test:release
#   Run only rspec tests:
#       docker run -e RUBY_ONLY=1 discourse/discourse_test:release
#   Run all plugin tests (with a plugin mounted from host filesystem):
#       docker run -e SKIP_CORE=1 -v $(pwd)/my-awesome-plugin:/var/www/discourse/plugins/my-awesome-plugin discourse/discourse_test:release
#   Run tests for a specific plugin (with a plugin mounted from host filesystem):
#       docker run -e SKIP_CORE=1 SINGLE_PLUGIN='my-awesome-plugin' -v $(pwd)/my-awesome-plugin:/var/www/discourse/plugins/my-awesome-plugin discourse/discourse_test:release

def run_or_fail(command)
  log(command)
  pid = Process.spawn(command)
  Process.wait(pid)
  $?.exitstatus == 0
end

def run_or_fail_prettier(*patterns)
  if patterns.any? { |p| Dir[p].any? }
    patterns = patterns.map { |p| "'#{p}'" }.join(' ')
    run_or_fail("yarn prettier --list-different #{patterns}")
  else
    puts "Skipping prettier. Pattern not found."
    true
  end
end

def log(message)
  puts "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] #{message}"
end

desc 'Run all tests (JS and code in a standalone environment)'
task 'docker:test' do
  begin
    @good = true
    unless ENV['SKIP_LINT']
      @good &&= run_or_fail("yarn install")
      puts "travis_fold:start:lint" if ENV["TRAVIS"]
      puts "Running linters/prettyfiers"
      puts "eslint #{`yarn eslint -v`}"
      puts "prettier #{`yarn prettier -v`}"

      if ENV["SINGLE_PLUGIN"]
        @good &&= run_or_fail("bundle exec rubocop --parallel plugins/#{ENV["SINGLE_PLUGIN"]}")
        @good &&= run_or_fail("yarn eslint --ext .es6 plugins/#{ENV['SINGLE_PLUGIN']}")

        puts "Listing prettier offenses in #{ENV['SINGLE_PLUGIN']}:"
        @good &&= run_or_fail_prettier("plugins/#{ENV['SINGLE_PLUGIN']}/**/*.scss", "plugins/#{ENV['SINGLE_PLUGIN']}/**/*.es6")
      else
        @good &&= run_or_fail("bundle exec rake plugin:update_all") unless ENV["SKIP_PLUGINS"]
        @good &&= run_or_fail("bundle exec rubocop --parallel") unless ENV["SKIP_CORE"]
        @good &&= run_or_fail("yarn eslint app/assets/javascripts test/javascripts") unless ENV["SKIP_CORE"]
        @good &&= run_or_fail("yarn eslint --ext .es6 app/assets/javascripts test/javascripts plugins") unless ENV["SKIP_PLUGINS"]

        unless ENV["SKIP_CORE"]
          puts "Listing prettier offenses in core:"
          @good &&= run_or_fail('yarn prettier --list-different "app/assets/stylesheets/**/*.scss" "app/assets/javascripts/**/*.es6" "test/javascripts/**/*.es6"')
        end

        unless ENV["SKIP_PLUGINS"]
          puts "Listing prettier offenses in plugins:"
          @good &&= run_or_fail('yarn prettier --list-different "plugins/**/*.scss" "plugins/**/*.es6"')
        end
      end
      puts "travis_fold:end:lint" if ENV["TRAVIS"]
    end

    unless ENV['SKIP_TESTS']
      puts "travis_fold:start:prepare_tests" if ENV["TRAVIS"]
      puts "Cleaning up old test tmp data in tmp/test_data"
      `rm -fr tmp/test_data && mkdir -p tmp/test_data/redis && mkdir tmp/test_data/pg`

      puts "Starting background redis"
      @redis_pid = Process.spawn('redis-server --dir tmp/test_data/redis')

      @postgres_bin = "/usr/lib/postgresql/10/bin/"
      `#{@postgres_bin}initdb -D tmp/test_data/pg`

      # speed up db, never do this in production mmmmk
      `echo fsync = off >> tmp/test_data/pg/postgresql.conf`
      `echo full_page_writes = off >> tmp/test_data/pg/postgresql.conf`
      `echo shared_buffers = 500MB >> tmp/test_data/pg/postgresql.conf`

      puts "Starting postgres"
      @pg_pid = Process.spawn("#{@postgres_bin}postmaster -D tmp/test_data/pg")

      ENV["RAILS_ENV"] = "test"
      # this shaves all the creation of the multisite db off
      # for js tests
      ENV["SKIP_MULTISITE"] = "1" if ENV["JS_ONLY"]

      @good &&= run_or_fail("bundle exec rake db:create")

      if ENV['USE_TURBO']
        @good &&= run_or_fail("bundle exec rake parallel:create")
      end

      if ENV["INSTALL_OFFICIAL_PLUGINS"]
        @good &&= run_or_fail("bundle exec rake plugin:install_all_official")
      end

      if ENV["UPDATE_ALL_PLUGINS"]
        @good &&= run_or_fail("bundle exec rake plugin:update_all")
      end

      command_prefix =
        if ENV["SKIP_PLUGINS"]
          # Make sure not to load plugins. bin/rake will add LOAD_PLUGINS=1 automatically unless we set it to 0 explicitly
          "LOAD_PLUGINS=0 "
        else
          "LOAD_PLUGINS=1 "
        end

      @good &&= run_or_fail("#{command_prefix}bundle exec rake db:migrate")

      if ENV['USE_TURBO']
        @good &&= run_or_fail("#{command_prefix}bundle exec rake parallel:migrate")
      end

      puts "travis_fold:end:prepare_tests" if ENV["TRAVIS"]

      unless ENV["JS_ONLY"]
        puts "travis_fold:start:ruby_tests" if ENV["TRAVIS"]

        if ENV['WARMUP_TMP_FOLDER']
          run_or_fail('bundle exec rspec ./spec/requests/groups_controller_spec.rb')
        end

        unless ENV["SKIP_CORE"]
          params = []

          unless ENV['USE_TURBO']
            params << "--profile"
            params << "--fail-fast"
            if ENV["BISECT"]
              params << "--bisect"
            end
            if ENV["RSPEC_SEED"]
              params << "--seed #{ENV["RSPEC_SEED"]}"
            end
          end

          if ENV['PARALLEL']
            parts = ENV['PARALLEL'].split("/")
            total = parts[1].to_i
            subset = parts[0].to_i - 1

            spec_partials = Dir["spec/**/*_spec.rb"].sort.in_groups(total, false)
            # quick and dirty load balancing
            if (spec_partials.count > 3)
              spec_partials[0].concat(spec_partials[total - 1].shift(30))
              spec_partials[1].concat(spec_partials[total - 2].shift(30))
            end

            params << spec_partials[subset].join(' ')

            puts "Running spec subset #{subset + 1} of #{total}"
          end

          if ENV['USE_TURBO']
            @good &&= run_or_fail("bundle exec ./bin/turbo_rspec #{params.join(' ')}".strip)
          else
            @good &&= run_or_fail("bundle exec rspec #{params.join(' ')}".strip)
          end
        end

        unless ENV["SKIP_PLUGINS"]
          if ENV["SINGLE_PLUGIN"]
            @good &&= run_or_fail("bundle exec rake plugin:spec['#{ENV["SINGLE_PLUGIN"]}']")
          else
            fail_fast = "RSPEC_FAILFAST=1" unless ENV["SKIP_FAILFAST"]
            @good &&= run_or_fail("#{fail_fast} bundle exec rake plugin:spec")
          end
        end
        puts "travis_fold:end:ruby_tests" if ENV["TRAVIS"]
      end

      unless ENV["RUBY_ONLY"]
        js_timeout = ENV["JS_TIMEOUT"].presence || 900_000 # 15 minutes

        puts "travis_fold:start:js_tests" if ENV["TRAVIS"]
        unless ENV["SKIP_CORE"]
          @good &&= run_or_fail("bundle exec rake qunit:test['#{js_timeout}']")
          @good &&= run_or_fail("bundle exec rake qunit:test['#{js_timeout}','/wizard/qunit']")
        end

        unless ENV["SKIP_PLUGINS"]
          if ENV["SINGLE_PLUGIN"]
            @good &&= run_or_fail("bundle exec rake plugin:qunit['#{ENV['SINGLE_PLUGIN']}','#{js_timeout}']")
          else
            @good &&= run_or_fail("bundle exec rake plugin:qunit['*','#{js_timeout}']")
          end
        end
        puts "travis_fold:end:js_tests" if ENV["TRAVIS"]
      end
    end

  ensure
    puts "travis_fold:start:terminating" if ENV["TRAVIS"]
    puts "Terminating"

    if ENV['PAUSE_ON_TERMINATE']
      puts "Pausing prior to termination"
      sleep
    end

    Process.kill("TERM", @redis_pid) if @redis_pid
    Process.kill("TERM", @pg_pid) if @pg_pid
    Process.wait @redis_pid if @redis_pid
    Process.wait @pg_pid if @pg_pid
    puts "travis_fold:end:terminating" if ENV["TRAVIS"]
  end

  if !@good
    exit 1
  end

end
