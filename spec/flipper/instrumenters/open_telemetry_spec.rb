begin
  require 'opentelemetry-logs-sdk'
rescue LoadError
  # opentelemetry-logs-sdk requires Ruby 3.3+
  return
end

require 'flipper/instrumenters/open_telemetry'

RSpec.describe Flipper::Instrumenters::OpenTelemetry do
  include_context "open telemetry logs"

  subject(:instrumenter) { described_class.new(logger_provider: logger_provider) }

  let(:adapter) { Flipper::Adapters::Memory.new }
  let(:flipper) { Flipper.new(adapter, instrumenter: instrumenter) }

  it "defaults to wrapping the noop instrumenter" do
    expect(instrumenter.instrumenter).to be(Flipper::Instrumenters::Noop)
  end

  it "emits events for feature checks" do
    flipper.enable(:search)

    expect(flipper.enabled?(:search)).to be(true)
    expect(emitted_log_records.size).to eq(1)
    expect(emitted_log_records.first.attributes).to include(
      "feature_flag.key" => "search",
      "feature_flag.result.value" => true,
      "feature_flag.result.reason" => "static",
    )
  end

  it "returns the block result" do
    expect(instrumenter.instrument("foo.flipper") { :result }).to be(:result)
  end

  it "passes the context id option to the emitter" do
    instrumenter = described_class.new(logger_provider: logger_provider, include_context_id: true)
    flipper = Flipper.new(adapter, instrumenter: instrumenter)

    flipper.enabled?(:search, Flipper::Actor.new("User;1"))

    expect(emitted_log_records.first.attributes["feature_flag.context.id"]).to eq("User;1")
  end

  it "uses the global logger provider by default" do
    # Runs in a separate process so only opentelemetry-logs-api is loaded when
    # the instrumenter is created and the SDK is configured afterwards.
    script = <<~RUBY
      require "flipper"
      require "flipper/instrumenters/open_telemetry"

      flipper = Flipper.new(Flipper::Adapters::Memory.new, instrumenter: Flipper::Instrumenters::OpenTelemetry.new)

      require "opentelemetry-logs-sdk"
      exporter = OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new
      provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
      provider.add_log_record_processor(OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(exporter))
      OpenTelemetry.logger_provider = provider

      flipper.enabled?(:search)
      print exporter.emitted_log_records.map(&:event_name).inspect
    RUBY

    command = [RbConfig.ruby, "-rbundler/setup", "-I", FlipperRoot.join("lib").to_s, "-e", script]
    output = IO.popen(command, err: [:child, :out], &:read)

    expect(output).to eq('["feature_flag.evaluation"]')
  end

  it "emits events when wrapped by Flipper Cloud" do
    require "flipper/cloud"
    stub_request(:get, /flippercloud\.io/).to_return(status: 200, body: "{}")
    cloud = Flipper::Cloud.new(token: "asdf", instrumenter: instrumenter)

    cloud.enabled?(:search)

    expect(cloud.instrumenter.instrumenter).to be(instrumenter)
    expect(emitted_log_records.size).to eq(1)
    expect(emitted_log_records.first.attributes["feature_flag.key"]).to eq("search")
  end

  context "wrapping another instrumenter" do
    subject(:instrumenter) { described_class.new(memory, logger_provider: logger_provider) }

    let(:memory) { Flipper::Instrumenters::Memory.new }

    it "delegates to the wrapped instrumenter" do
      flipper.enabled?(:search)

      event = memory.event_by_name(Flipper::Feature::InstrumentationName)
      expect(event.payload[:operation]).to eq(:enabled?)
    end

    it "emits using the payload yielded by the wrapped instrumenter" do
      flipper.enable(:search)
      flipper.enabled?(:search)

      expect(emitted_log_records.first.attributes).to include(
        "feature_flag.result.value" => true,
        "feature_flag.result.reason" => "static",
      )
    end
  end

  it "emits flag_not_found when the strict adapter raises" do
    flipper = Flipper.new(Flipper::Adapters::Strict.new(adapter, :raise), instrumenter: instrumenter)

    expect { flipper.enabled?(:search) }.to raise_error(Flipper::Adapters::Strict::NotFound)
    expect(emitted_log_records.size).to eq(1)
    expect(emitted_log_records.first.attributes).to include(
      "error.type" => "flag_not_found",
      "feature_flag.result.reason" => "error",
    )
  end

  it "emits an error event and re-raises when the check fails" do
    allow(adapter).to receive(:get).and_raise(RuntimeError, "boom")

    expect { flipper.enabled?(:search) }.to raise_error(RuntimeError, "boom")
    expect(emitted_log_records.size).to eq(1)
    expect(emitted_log_records.first.attributes).to include(
      "error.type" => "general",
      "feature_flag.error.message" => "boom",
      "feature_flag.result.reason" => "error",
    )
    expect(emitted_log_records.first.attributes).not_to have_key("feature_flag.result.value")
  end
end
