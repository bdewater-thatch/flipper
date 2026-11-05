require 'opentelemetry-logs-api'
# opentelemetry-logs-api >= 0.6.0 only defines OpenTelemetry.logger_provider
# when the SDK or this file is required.
require 'opentelemetry/logs/global'

module Flipper
  module Instrumentation
    # Emits OpenTelemetry feature_flag.evaluation events for feature checks.
    #
    # https://opentelemetry.io/docs/specs/semconv/feature-flags/feature-flags-events/
    #
    # Requires opentelemetry-logs-api >= 0.6.0 and, to export events,
    # opentelemetry-logs-sdk >= 0.8.0 configured with a log record processor.
    #
    # You should not need to use this directly. Subscribe with
    # Flipper::Instrumentation::OpenTelemetrySubscriber when instrumenting with
    # ActiveSupport::Notifications or wrap any other instrumenter with
    # Flipper::Instrumenters::OpenTelemetry.
    class OpenTelemetryEmitter
      EVENT_NAME = "feature_flag.evaluation".freeze
      PROVIDER_NAME = "Flipper".freeze

      # Maps the name of the gate that enabled the feature to a result reason.
      REASONS = {
        boolean: "static".freeze,
        actor: "targeting_match".freeze,
        group: "targeting_match".freeze,
        expression: "targeting_match".freeze,
        percentage_of_actors: "split".freeze,
        percentage_of_time: "split".freeze,
      }.freeze

      # No gate was open so the feature fell back to being disabled.
      DEFAULT_REASON = "default".freeze
      UNKNOWN_REASON = "unknown".freeze
      ERROR_REASON = "error".freeze
      GENERAL_ERROR = "general".freeze

      # Maps exception class names to error types. Other errors are general.
      ERROR_TYPES = {
        Adapters::Strict::NotFound.name => "flag_not_found".freeze,
      }.freeze

      # Public: Initializes a new emitter.
      #
      # logger_provider - The OpenTelemetry logger provider to emit events to
      #                   (default: OpenTelemetry.logger_provider).
      # include_context_id - Whether to include the flipper_id of the first actor
      #                      as feature_flag.context.id (default: false). Off by
      #                      default because flipper_ids may identify people.
      def initialize(logger_provider: ::OpenTelemetry.logger_provider, include_context_id: false)
        @logger = logger_provider.logger(name: "flipper", version: Flipper::VERSION)
        @include_context_id = include_context_id
      end

      # Public: Emits a feature_flag.evaluation event if the instrumentation
      # event is a feature check. Never raises so that telemetry can't break
      # feature checks.
      def emit(name, payload)
        return unless name == Feature::InstrumentationName
        return unless payload[:operation] == :enabled?

        @logger.on_emit(event_name: EVENT_NAME, attributes: attributes(payload))
      rescue StandardError => e
        ::OpenTelemetry.handle_error(exception: e, message: "Flipper failed to emit #{EVENT_NAME} event")
      end

      private

      def attributes(payload)
        attributes = {
          "feature_flag.key" => payload[:feature_name].to_s,
          "feature_flag.provider.name" => PROVIDER_NAME,
        }

        if (exception = payload[:exception])
          attributes["error.type"] = ERROR_TYPES.fetch(exception[0], GENERAL_ERROR)
          attributes["feature_flag.error.message"] = exception[1].to_s
          attributes["feature_flag.result.reason"] = ERROR_REASON
        else
          attributes["feature_flag.result.value"] = payload[:result]
          attributes["feature_flag.result.reason"] = reason(payload[:gate_name])
        end

        if @include_context_id && (actor = payload[:actors]&.first)
          attributes["feature_flag.context.id"] = actor.value
        end

        attributes
      end

      def reason(gate_name)
        return DEFAULT_REASON if gate_name.nil?
        REASONS.fetch(gate_name, UNKNOWN_REASON)
      end
    end
  end
end
