# frozen_string_literal: true
require 'execjs'
require 'mini_racer'

class DiscourseJsProcessor

  def self.plugin_transpile_paths
    @@plugin_transpile_paths ||= Set.new
  end

  def self.call(input)
    root_path = input[:load_path] || ''
    logical_path = (input[:filename] || '').sub(root_path, '').gsub(/\.(js|es6).*$/, '').sub(/^\//, '')
    data = input[:data]

    if should_transpile?(input[:filename])
      data = transpile(data, root_path, logical_path)
    end

    # add sourceURL until we can do proper source maps
    unless Rails.env.production?
      data = "eval(#{data.inspect} + \"\\n//# sourceURL=#{logical_path}\");\n"
    end

    { data: data }
  end

  def self.transpile(data, root_path, logical_path)
    transpiler = Transpiler.new(skip_module: skip_module?(data))
    transpiler.perform(data, root_path, logical_path)
  end

  def self.should_transpile?(filename)
    filename ||= ''

    # es6 is always transpiled
    return true if filename.end_with?(".es6") || filename.end_with?(".es6.erb")

    # For .js check the path...
    return false unless filename.end_with?(".js") || filename.end_with?(".js.erb")

    relative_path = filename.sub(Rails.root.to_s, '').sub(/^\/*/, '')

    js_root = "app/assets/javascripts"
    test_root = "test/javascripts"

    return false if relative_path.start_with?("#{js_root}/locales/")
    return false if relative_path.start_with?("#{js_root}/plugins/")

    return true if %w(
      preload-store
      preload-application-data
      wizard-start
      onpopstate-handler
      discourse
      google-tag-manager
      google-universal-analytics
      activate-account
      auto-redirect
      embed-application
    ).any? { |f| relative_path == "#{js_root}/#{f}.js" }

    return true if plugin_transpile_paths.any? { |prefix| relative_path.start_with?(prefix) }

    !!(relative_path =~ /^#{js_root}\/[^\/]+\// ||
      relative_path =~ /^#{test_root}\/[^\/]+\//)
  end

  def self.skip_module?(data)
    !!(data.present? && data =~ /^\/\/ discourse-skip-module$/)
  end

  class Transpiler
    @mutex = Mutex.new
    @ctx_init = Mutex.new

    def self.mutex
      @mutex
    end

    def self.create_new_context
      # timeout any eval that takes longer than 15 seconds
      ctx = MiniRacer::Context.new(timeout: 15000)
      ctx.eval("var self = this; #{File.read("#{Rails.root}/vendor/assets/javascripts/babel.js")}")
      ctx.eval(File.read(Ember::Source.bundled_path_for('ember-template-compiler.js')))
      ctx.eval("module = {}; exports = {};")
      ctx.attach("rails.logger.info", proc { |err| Rails.logger.info(err.to_s) })
      ctx.attach("rails.logger.error", proc { |err| Rails.logger.error(err.to_s) })
      ctx.eval <<JS
      console = {
        prefix: "",
        log: function(msg){ rails.logger.info(console.prefix + msg); },
        error: function(msg){ rails.logger.error(console.prefix + msg); }
      }

JS
      source = File.read("#{Rails.root}/lib/javascripts/widget-hbs-compiler.js")
      js_source = ::JSON.generate(source, quirks_mode: true)
      js = ctx.eval("Babel.transform(#{js_source}, { ast: false, plugins: ['check-es2015-constants', 'transform-es2015-arrow-functions', 'transform-es2015-block-scoped-functions', 'transform-es2015-block-scoping', 'transform-es2015-classes', 'transform-es2015-computed-properties', 'transform-es2015-destructuring', 'transform-es2015-duplicate-keys', 'transform-es2015-for-of', 'transform-es2015-function-name', 'transform-es2015-literals', 'transform-es2015-object-super', 'transform-es2015-parameters', 'transform-es2015-shorthand-properties', 'transform-es2015-spread', 'transform-es2015-sticky-regex', 'transform-es2015-template-literals', 'transform-es2015-typeof-symbol', 'transform-es2015-unicode-regex'] }).code")
      ctx.eval(js)

      ctx
    end

    def self.reset_context
      @ctx&.dispose
      @ctx = nil
    end

    def self.v8
      return @ctx if @ctx

      # ensure we only init one of these
      @ctx_init.synchronize do
        return @ctx if @ctx
        @ctx = create_new_context
      end

      @ctx
    end

    def initialize(skip_module: false)
      @skip_module = skip_module
    end

    def perform(source, root_path = nil, logical_path = nil)
      klass = self.class
      klass.mutex.synchronize do
        klass.v8.eval("console.prefix = 'BABEL: babel-eval: ';")
        transpiled = babel_source(
          source,
          module_name: module_name(root_path, logical_path),
          filename: logical_path
        )
        @output = klass.v8.eval(transpiled)
      end
    end

    def babel_source(source, opts = nil)
      opts ||= {}

      js_source = ::JSON.generate(source, quirks_mode: true)

      if opts[:module_name] && !@skip_module
        filename = opts[:filename] || 'unknown'
        "Babel.transform(#{js_source}, { moduleId: '#{opts[:module_name]}', filename: '#{filename}', ast: false, presets: ['es2015'], plugins: [['transform-es2015-modules-amd', {noInterop: true}], 'transform-decorators-legacy', exports.WidgetHbsCompiler] }).code"
      else
        "Babel.transform(#{js_source}, { ast: false, plugins: ['check-es2015-constants', 'transform-es2015-arrow-functions', 'transform-es2015-block-scoped-functions', 'transform-es2015-block-scoping', 'transform-es2015-classes', 'transform-es2015-computed-properties', 'transform-es2015-destructuring', 'transform-es2015-duplicate-keys', 'transform-es2015-for-of', 'transform-es2015-function-name', 'transform-es2015-literals', 'transform-es2015-object-super', 'transform-es2015-parameters', 'transform-es2015-shorthand-properties', 'transform-es2015-spread', 'transform-es2015-sticky-regex', 'transform-es2015-template-literals', 'transform-es2015-typeof-symbol', 'transform-es2015-unicode-regex', 'transform-regenerator', 'transform-decorators-legacy', exports.WidgetHbsCompiler] }).code"
      end
    end

    def module_name(root_path, logical_path)
      path = nil

      root_base = File.basename(Rails.root)
      # If the resource is a plugin, use the plugin name as a prefix
      if root_path =~ /(.*\/#{root_base}\/plugins\/[^\/]+)\//
        plugin_path = "#{Regexp.last_match[1]}/plugin.rb"

        plugin = Discourse.plugins.find { |p| p.path == plugin_path }
        path = "discourse/plugins/#{plugin.name}/#{logical_path.sub(/javascripts\//, '')}" if plugin
      end

      path || logical_path
    end

  end
end
