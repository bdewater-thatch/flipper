require 'securerandom'
require 'active_support/notifications'
require 'flipper/instrumentation/open_telemetry_emitter'

module Flipper
  module Instrumentation
    # Emits OpenTelemetry feature_flag.evaluation events for feature checks
    # instrumented with ActiveSupport::Notifications.
    #
    #   require "flipper/instrumentation/open_telemetry_subscriber"
    #   Flipper::Instrumentation::OpenTelemetrySubscriber.subscribe
    #
    # See OpenTelemetryEmitter for options.
    class OpenTelemetrySubscriber
      # Public: Subscribes to feature operations, replacing any previous
      # subscription so it is safe to call more than once.
      def self.subscribe(**options)
        unsubscribe
        emitter = OpenTelemetryEmitter.new(**options)
        @subscription = ActiveSupport::Notifications.subscribe(Feature::InstrumentationName) do |name, _start, _finish, _id, payload|
          emitter.emit(name, payload)
        end
      end

      # Public: Removes the subscription, if any.
      def self.unsubscribe
        ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
        @subscription = nil
      end

      def self.subscribed?
        !@subscription.nil?
      end
    end
  end
end
