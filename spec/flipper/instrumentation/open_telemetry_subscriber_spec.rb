begin
  require 'opentelemetry-logs-sdk'
rescue LoadError
  # opentelemetry-logs-sdk requires Ruby 3.3+
  return
end

require 'flipper/instrumentation/open_telemetry_subscriber'

begin
  require 'active_support/isolated_execution_state'
rescue LoadError
  # ActiveSupport::IsolatedExecutionState is only available in Rails 5.2+
end

RSpec.describe Flipper::Instrumentation::OpenTelemetrySubscriber do
  include_context "open telemetry logs"

  let(:adapter) { Flipper::Adapters::Memory.new }
  let(:flipper) { Flipper.new(adapter, instrumenter: ActiveSupport::Notifications) }

  before { described_class.subscribe(logger_provider: logger_provider) }
  after { described_class.unsubscribe }

  it "emits events for feature checks" do
    flipper.enable(:search)
    flipper.enabled?(:search)

    expect(emitted_log_records.size).to eq(1)
    expect(emitted_log_records.first.event_name).to eq("feature_flag.evaluation")
    expect(emitted_log_records.first.attributes).to include(
      "feature_flag.key" => "search",
      "feature_flag.result.value" => true,
      "feature_flag.result.reason" => "static",
    )
  end

  it "passes options to the emitter" do
    described_class.subscribe(logger_provider: logger_provider, include_context_id: true)

    flipper.enabled?(:search, Flipper::Actor.new("User;1"))

    expect(emitted_log_records.first.attributes["feature_flag.context.id"]).to eq("User;1")
  end

  it "replaces the previous subscription when subscribing again" do
    described_class.subscribe(logger_provider: logger_provider)

    flipper.enabled?(:search)

    expect(emitted_log_records.size).to eq(1)
  end

  it "emits an error event when the check fails" do
    allow(adapter).to receive(:get).and_raise(RuntimeError, "boom")

    expect { flipper.enabled?(:search) }.to raise_error(RuntimeError, "boom")
    expect(emitted_log_records.first.attributes).to include(
      "error.type" => "general",
      "feature_flag.error.message" => "boom",
    )
  end

  it "stops emitting after unsubscribing" do
    described_class.unsubscribe

    flipper.enabled?(:search)

    expect(described_class).not_to be_subscribed
    expect(emitted_log_records).to be_empty
  end
end
