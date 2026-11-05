RSpec.shared_context "open telemetry logs" do
  let(:log_exporter) { OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new }
  let(:logger_provider) do
    OpenTelemetry::SDK::Logs::LoggerProvider.new.tap do |provider|
      provider.add_log_record_processor(
        OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(log_exporter)
      )
    end
  end

  def emitted_log_records
    log_exporter.emitted_log_records
  end
end
