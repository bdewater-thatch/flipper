# Emits OpenTelemetry feature_flag.evaluation events for feature checks.
#
# https://opentelemetry.io/docs/specs/semconv/feature-flags/feature-flags-events/
#
# Requires Ruby 3.3+ and the opentelemetry-logs-sdk (>= 0.8.0) gem, which is not
# a dependency of flipper. Add it (and an exporter) to your Gemfile.
#
# In Rails, set `config.flipper.open_telemetry = true` (or FLIPPER_OPEN_TELEMETRY=true)
# instead. Pass a hash of options, like `{ include_context_id: true }`, to customize.
require 'bundler/setup'
require 'opentelemetry/sdk'
require 'opentelemetry-logs-sdk'
require 'flipper'
require 'flipper/instrumenters/open_telemetry'

# Print events to the console instead of exporting them with OTLP.
ENV['OTEL_TRACES_EXPORTER'] ||= 'none'
ENV['OTEL_LOGS_EXPORTER'] ||= 'console'
OpenTelemetry::SDK.configure

Flipper.configure do |config|
  config.default do
    # Wraps the Noop instrumenter by default. Pass another instrumenter as the
    # first argument to wrap it instead. If you instrument with
    # ActiveSupport::Notifications, you can instead use:
    #
    #   require 'flipper/instrumentation/open_telemetry_subscriber'
    #   Flipper::Instrumentation::OpenTelemetrySubscriber.subscribe
    #
    # include_context_id: true adds the flipper_id of the first actor as
    # feature_flag.context.id. It is off by default because flipper_ids may
    # identify people.
    instrumenter = Flipper::Instrumenters::OpenTelemetry.new(include_context_id: true)
    Flipper.new(Flipper::Adapters::Memory.new, instrumenter: instrumenter)
  end
end

user = Flipper::Actor.new("User;1")

Flipper.enabled?(:search, user) # reason: default

Flipper.enable_actor(:search, user)
Flipper.enabled?(:search, user) # reason: targeting_match

Flipper.enable_percentage_of_time(:logging, 100)
Flipper.enabled?(:logging) # reason: split

Flipper.enable(:stats)
Flipper.enabled?(:stats) # reason: static

# Flush any buffered events before exiting.
OpenTelemetry.logger_provider.shutdown
OpenTelemetry.tracer_provider.shutdown
