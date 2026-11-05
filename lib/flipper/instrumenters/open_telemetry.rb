require 'flipper/instrumenters/noop'
require 'flipper/instrumentation/open_telemetry_emitter'

module Flipper
  module Instrumenters
    # Instrumenter that emits OpenTelemetry feature_flag.evaluation events for
    # feature checks and delegates everything to another instrumenter. Use this
    # when not instrumenting with ActiveSupport::Notifications.
    #
    #   require "flipper/instrumenters/open_telemetry"
    #
    #   Flipper.configure do |config|
    #     config.default do
    #       Flipper.new(adapter, instrumenter: Flipper::Instrumenters::OpenTelemetry.new)
    #     end
    #   end
    #
    # See Flipper::Instrumentation::OpenTelemetryEmitter for options.
    class OpenTelemetry
      attr_reader :instrumenter

      def initialize(instrumenter = Noop, **options)
        @instrumenter = instrumenter
        @emitter = Instrumentation::OpenTelemetryEmitter.new(**options)
      end

      def instrument(name, payload = {})
        # Some instrumenters (like Memory) yield a copy of the payload, so emit
        # with whichever payload the block actually received.
        block_payload = payload

        result = @instrumenter.instrument(name, payload) do |yielded_payload|
          block_payload = yielded_payload
          yield yielded_payload if block_given?
        end

        @emitter.emit(name, block_payload)
        result
      rescue Exception => e
        block_payload[:exception] ||= [e.class.name, e.message]
        @emitter.emit(name, block_payload)
        raise e
      end
    end
  end
end
