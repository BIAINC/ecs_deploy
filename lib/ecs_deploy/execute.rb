# frozen_string_literal: true

module EcsDeploy
  class Execute
    def initialize(task:, region: nil )
      @task = task
      @region = region
      @client = region ? Aws::ECS::Client.new(region: region) : Aws::ECS::Client.new
    end

    def run
      resp = @client.run_task(@task)
      task_id = resp[:tasks].first[:task_arn].split('/')[-1]
      cluster_id = resp[:tasks].first[:cluster_arn].split('/')[-1]
      
      tail = LogTail.new( log_options(task_id) )
      Thread.new do 
        abort_on_exception = true
        tail.run
      end


      @client.wait_until(:tasks_stopped,  cluster: cluster_id, tasks: [task_id]) do |w|
        w.max_attempts = nil

        EcsDeploy.logger.info "Waiting for task to stop[#{task_id}]"

        # poll for 1 hour, instead of a number of attempts
        w.before_wait do |attempts, response|
          EcsDeploy.logger.debug "Waiting for task to stop[#{task_id}]"
        end
      
      end

      tail.stop
    end

    def wait_for(cluster_id, task_id, states)
      while
        resp = @client.describe_tasks(tasks: [task_id], cluster: cluster_id)
        last_state = resp[:tasks].first[:last_status]
        exit_code = resp[:tasks].first[:containers].first[:exit_code]

        if states.include? last_state
          yield last_state, exit_code
          break
        end

        sleep 5
      end
    end

    def log_options(task_id)
      client = Aws::ECS::Client.new
      options = client.describe_task_definition({
        task_definition: @task[:task_definition], 
      }).task_definition.container_definitions.first.log_configuration.options

      return {
        log_group: options["awslogs-group"],
        log_prefix: "#{options["awslogs-stream-prefix"]}/#{@task[:overrides][:container_overrides].first[:name]}/#{task_id}"
      }
    end
  end
end
