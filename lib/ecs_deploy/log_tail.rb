# frozen_string_literal: true

require 'aws-sdk-cloudwatchlogs'

module EcsDeploy
  class LogTail
    attr_reader :running, :task_id

    def initialize(region: nil, log_group:, log_prefix:, poll_interval: 2,
                   io: STDOUT, limit: 1_000, drain_pause: 5 )
      @log_group = log_group
      @log_prefix = log_prefix
      @poll_interval = poll_interval
      @io = io
      @limit = limit
      @drain_pause = drain_pause
      @running = false
      @stop = false
      @start_time = 0
      @client = region ? Aws::CloudWatchLogs::Client.new(region: region) : Aws::CloudWatchLogs::Client.new
      @task_id = task_id
      @limit = limit
    end

    def run
      begin
        @running = true
        EcsDeploy.logger.info "Tailing #{@log_group}/#{@log_prefix}"
          while !@stop
            dump
            sleep @poll_interval
          end
          sleep @drain_pause
          dump
      rescue
        EcsDeploy.logger.error "Log tail failed #{$!}"
      end
    ensure
      EcsDeploy.logger.info "Finished tailing #{@log_group}/#{@log_prefix}"
      @running = false
      @stop = false
    end

    def stop
      @stop = true
      while @running
        sleep 1
      end
    end

    private
    def dump
      _dump(start_time: @start_time)
      nil
    end

    def _dump(options) 
      options = {
        log_group_name: @log_group,
        log_stream_name_prefix: @log_prefix,
        limit: @limit,
        interleaved: false
      }.merge(options)
      resp = @client.filter_log_events(options)
      _write(resp[:events])
      _dump(next_token: token) if resp[:next_token]
      nil
    end

    def _write(events)
      events.each do |msg|
        ts = Time.at(msg[:timestamp] / 1000)
        @io.puts "[#{Paint[ts,:green]}] #{msg[:message]}"
      end

      @start_time = events.last[:timestamp] + 1 if events.last
      nil
    end

  end
end
