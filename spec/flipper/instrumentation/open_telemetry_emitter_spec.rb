begin
  require 'opentelemetry-logs-sdk'
rescue LoadError
  # opentelemetry-logs-sdk requires Ruby 3.3+
  return
end

require 'flipper/instrumentation/open_telemetry_emitter'

RSpec.describe Flipper::Instrumentation::OpenTelemetryEmitter do
  include_context "open telemetry logs"

  subject(:emitter) { described_class.new(logger_provider: logger_provider) }

  let(:instrumenter) { Flipper::Instrumenters::Memory.new }
  let(:flipper) { Flipper.new(Flipper::Adapters::Memory.new, instrumenter: instrumenter) }
  let(:user) { Flipper::Actor.new("User;1", "plan" => "basic") }

  # Runs a feature check and emits for the resulting instrumentation event.
  def check(*actors)
    instrumenter.reset
    flipper.enabled?(:search, *actors)
    event = instrumenter.event_by_name(Flipper::Feature::InstrumentationName)
    emitter.emit(event.name, event.payload)
  end

  def log_record
    expect(emitted_log_records.size).to eq(1)
    emitted_log_records.first
  end

  def attributes
    log_record.attributes
  end

  it "emits a feature_flag.evaluation event" do
    check

    expect(log_record.event_name).to eq("feature_flag.evaluation")
    expect(log_record.body).to be_nil
    expect(log_record.severity_number).to eq(OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_INFO)
    expect(log_record.severity_text).to eq("INFO")
    expect(log_record.instrumentation_scope.name).to eq("flipper")
    expect(log_record.instrumentation_scope.version).to eq(Flipper::VERSION)
    expect(attributes).to eq(
      "feature_flag.key" => "search",
      "feature_flag.provider.name" => "Flipper",
      "feature_flag.result.value" => false,
      "feature_flag.result.reason" => "default",
    )
  end

  it "uses static reason for boolean gate" do
    flipper.enable(:search)
    check

    expect(attributes["feature_flag.result.value"]).to be(true)
    expect(attributes["feature_flag.result.reason"]).to eq("static")
  end

  it "uses INFO severity when the feature is enabled" do
    flipper.enable(:search)
    check

    expect(log_record.severity_number).to eq(9)
    expect(log_record.severity_text).to eq("INFO")
  end

  it "uses INFO severity when the feature is disabled" do
    check

    expect(attributes["feature_flag.result.value"]).to be(false)
    expect(log_record.severity_number).to eq(9)
    expect(log_record.severity_text).to eq("INFO")
  end

  it "uses targeting_match reason for actor gate" do
    flipper.enable_actor(:search, user)
    check(user)

    expect(attributes["feature_flag.result.value"]).to be(true)
    expect(attributes["feature_flag.result.reason"]).to eq("targeting_match")
  end

  it "uses targeting_match reason for group gate" do
    Flipper.register(:all_users) { |actor| true }
    flipper.enable_group(:search, :all_users)
    check(user)

    expect(attributes["feature_flag.result.reason"]).to eq("targeting_match")
  end

  it "uses targeting_match reason for expression gate" do
    flipper.enable_expression(:search, Flipper.property(:plan).eq("basic"))
    check(user)

    expect(attributes["feature_flag.result.reason"]).to eq("targeting_match")
  end

  it "uses split reason for percentage of actors gate" do
    flipper.enable_percentage_of_actors(:search, 100)
    check(user)

    expect(attributes["feature_flag.result.reason"]).to eq("split")
  end

  it "uses split reason for percentage of time gate" do
    flipper.enable_percentage_of_time(:search, 100)
    check

    expect(attributes["feature_flag.result.reason"]).to eq("split")
  end

  it "uses default reason when no gate is open" do
    flipper.enable_actor(:search, Flipper::Actor.new("User;2"))
    check(user)

    expect(attributes["feature_flag.result.value"]).to be(false)
    expect(attributes["feature_flag.result.reason"]).to eq("default")
  end

  it "uses unknown reason for unrecognized gates" do
    emitter.emit(Flipper::Feature::InstrumentationName, {
      feature_name: :search, operation: :enabled?, result: true, gate_name: :custom
    })

    expect(attributes["feature_flag.result.reason"]).to eq("unknown")
  end

  it "reports errors" do
    emitter.emit(Flipper::Feature::InstrumentationName, {
      feature_name: :search, operation: :enabled?, exception: ["RuntimeError", "boom"]
    })

    expect(attributes).to eq(
      "feature_flag.key" => "search",
      "feature_flag.provider.name" => "Flipper",
      "error.type" => "general",
      "feature_flag.error.message" => "boom",
      "feature_flag.result.reason" => "error",
    )
    expect(log_record.severity_number).to eq(17)
    expect(log_record.severity_text).to eq("ERROR")
  end

  it "reports flag_not_found for strict adapter errors" do
    error = Flipper::Adapters::Strict::NotFound.new(:search)
    emitter.emit(Flipper::Feature::InstrumentationName, {
      feature_name: :search, operation: :enabled?, exception: [error.class.name, error.message]
    })

    expect(attributes).to include(
      "error.type" => "flag_not_found",
      "feature_flag.error.message" => error.message,
      "feature_flag.result.reason" => "error",
    )
    expect(log_record.severity_number).to eq(17)
    expect(log_record.severity_text).to eq("ERROR")
  end

  it "does not include context id by default" do
    flipper.enable_actor(:search, user)
    check(user)

    expect(attributes).not_to have_key("feature_flag.context.id")
  end

  context "with include_context_id" do
    subject(:emitter) do
      described_class.new(logger_provider: logger_provider, include_context_id: true)
    end

    it "includes flipper_id of the actor" do
      check(user)

      expect(attributes["feature_flag.context.id"]).to eq("User;1")
    end

    it "includes flipper_id of the first actor when checking multiple actors" do
      check(user, Flipper::Actor.new("Org;1"))

      expect(attributes["feature_flag.context.id"]).to eq("User;1")
    end

    it "omits context id without actors" do
      check

      expect(attributes).not_to have_key("feature_flag.context.id")
    end
  end

  it "associates the event with the current span" do
    span_context = OpenTelemetry::Trace::SpanContext.new
    span = OpenTelemetry::Trace.non_recording_span(span_context)

    OpenTelemetry::Trace.with_span(span) { check }

    expect(log_record.trace_id).to eq(span_context.trace_id)
    expect(log_record.span_id).to eq(span_context.span_id)
  end

  it "ignores feature operations other than enabled?" do
    instrumenter.reset
    flipper.enable(:search)
    instrumenter.events.each { |event| emitter.emit(event.name, event.payload) }

    expect(emitted_log_records).to be_empty
  end

  it "ignores other instrumentation events" do
    emitter.emit("adapter_operation.flipper", operation: :enabled?, feature_name: :search)

    expect(emitted_log_records).to be_empty
  end

  it "does not raise when emitting fails" do
    logger = double("logger")
    allow(logger).to receive(:on_emit).and_raise("emit failed")
    allow(logger_provider).to receive(:logger).and_return(logger)
    expect(OpenTelemetry).to receive(:handle_error).with(hash_including(message: /Flipper failed to emit/))

    expect { check }.not_to raise_error
  end
end
