# EcsDeploy

Helper script for deployment to Amazon ECS.

This gem is experimental.

Main purpose is combination with capistrano API.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ecs_deploy', github: "reproio/ecs_deploy"
```

And then execute:

    $ bundle

## Usage

Use by Capistrano.

```ruby
# Capfile
require 'ecs_deploy/capistrano'

# deploy.rb
set :ecs_default_cluster, "ecs-cluster-name"
set :ecs_region, %w(ap-northeast-1) # optional, if nil, use environment variable
set :ecs_service_role, "customEcsServiceRole" # default: ecsServiceRole
set :ecs_deploy_wait_timeout, 600 # default: 300
set :ecs_wait_until_services_stable_max_attempts, 40 # optional
set :ecs_wait_until_services_stable_delay, 15 # optional

set :ecs_tasks, [
  {
    name: "myapp-#{fetch(:rails_env)}",
    container_definitions: [
      {
        name: "myapp",
        image: "#{fetch(:docker_registry_host_with_port)}/myapp:#{fetch(:sha1)}",
        cpu: 1024,
        memory: 512,
        port_mappings: [],
        essential: true,
        environment: [
          {name: "RAILS_ENV", value: fetch(:rails_env)},
        ],
        mount_points: [
          {
            source_volume: "sockets_path",
            container_path: "/app/tmp/sockets",
            read_only: false,
          },
        ],
        volumes_from: [],
        log_configuration: {
          log_driver: "fluentd",
          options: {
            "tag" => "docker.#{fetch(:rails_env)}.#{name}.{{.ID}}",
          },
        },
      },
      {
        name: "nginx",
        image: "#{fetch(:docker_registry_host_with_port)}/my-nginx",
        cpu: 256,
        memory: 256,
        links: [],
        port_mappings: [
          {container_port: 443, host_port: 443, protocol: "tcp"},
        ],
        essential: true,
        environment: {},
        mount_points: [],
        volumes_from: [
          {source_container: "myapp-#{fetch(:rails_env)}", read_only: false},
        ],
        log_configuration: {
          log_driver: "fluentd",
          options: {
            "tag" => "docker.#{fetch(:rails_env)}.#{name}.{{.ID}}",
          },
        },
      }
    ],
    volumes: [{name: "sockets_path", host: {}}],
  },
]

set :ecs_scheduled_tasks, [
  {
    cluster: "default", # Unless this key, use fetch(:ecs_default_cluster)
    rule_name: "schedule_name",
    schedule_expression: "cron(0 12 * * ? *)",
    description: "schedule_description", # Optional
    target_id: "task_name", # Unless this key, use task_definition_name
    task_definition_name: "myapp-#{fetch(:rails_env)}",
    task_count: 2, # Default 1
    revision: 12, # Optional
    role_arn: "TaskRoleArn", # Optional
    container_overrides: [ # Optional
      name: "myapp-main",
      command: ["ls"],
    ]
  }
]

set :ecs_services, [
  {
    name: "myapp-#{fetch(:rails_env)}",
    load_balancers: [
      {
        load_balancer_name: "service-elb-name",
        container_port: 443,
        container_name: "nginx",
      },
      {
        target_group_arn: "alb_target_group_arn",
        container_port: 443,
        container_name: "nginx",
      }
    ],
    desired_count: 1,
    deployment_configuration: {maximum_percent: 200, minimum_healthy_percent: 50},
  },
]
```

```sh
cap <stage> ecs:register_task_definition # register ecs_tasks as TaskDefinition
cap <stage> ecs:deploy_scheduled_task # register ecs_scheduled_tasks to CloudWatchEvent
cap <stage> ecs:deploy # create or update Service by ecs_services info

cap <stage> ecs:rollback # deregister current task definition and update Service by previous revision of current task definition
```

### Rollback example

| sequence | taskdef  | service       | desc    |
| -------- | -------- | ------------- | ------  |
| 1        | myapp:12 | myapp-service |         |
| 2        | myapp:13 | myapp-service |         |
| 3        | myapp:14 | myapp-service | current |

After rollback

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | current    |

And rollback again

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service | previous   |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service | current    |

And deploy new version

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service |            |
| 6        | myapp:15 | myapp-service | current    |

And rollback

| sequence | taskdef  | service       | desc       |
| -------- | -------- | ------------- | ------     |
| 1        | myapp:12 | myapp-service |            |
| 2        | myapp:13 | myapp-service |            |
| 3        | myapp:14 | myapp-service | deregister |
| 4        | myapp:13 | myapp-service | deregister |
| 5        | myapp:12 | myapp-service |            |
| 6        | myapp:15 | myapp-service | deregister |
| 7        | myapp:12 | myapp-service | current    |

## Autoscaler

The autoscaler of `ecs_deploy` supports auto scaling of ECS services and clusters.

### Prerequisits

* You use a ECS cluster whose instances belong to either an auto scaling group or a spot fleet request
* You have CloudWatch alarms and you want to scale services when their state changes

### How to use autoscaler

First, write a configuration file (YAML format) like below:

```yaml
# ポーリング時にupscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを増やす (max_task_countまで)
# ポーリング時にdownscale_triggersに指定した状態のalarmがあればstep分serviceとinstanceを減らす (min_task_countまで)
# max_task_countは段階的にリミットを設けられるようにする
# 一回リミットに到達するとcooldown_for_reach_maxを越えても状態が継続したら再開するようにする

polling_interval: 60

auto_scaling_groups:
  - name: ecs-cluster-nodes
    region: ap-northeast-1
    # autoscaler will set the capacity to (buffer + desired_tasks * required_capacity).
    # Adjust this value if it takes much time to prepare ECS instances and launch new tasks.
    buffer: 1

spot_fleet_requests:
  - id: sfr-354de735-2c17-4565-88c9-10ada5b957e5
    region: ap-northeast-1
    buffer: 1

# If you specify `spot_instance_intrp_warns_queue_urls` as SQS queue for spot instance interruption warnings,
# autoscaler will polls them and set the state of instances to be intrrupted to "DRAINING".
# autoscaler will also waits for the capacity of active instances in the cluster being decreased
# when the capacity of spot fleet request is decreased,
# so you should specify URLs or set the state of the instances to "DRAINING" manually.
spot_instance_intrp_warns_queue_urls:
  - https://sqs.ap-northeast-1.amazonaws.com/<account-id>/spot-instance-intrp-warns

services:
  - name: repro-api-production
    cluster: ecs-cluster
    region: ap-northeast-1
    # auto_scaling_group_name or spot fleet request ID the instances in the cluster belongs to
    auto_scaling_group_name: ecs-cluster-nodes
    step: 1
    idle_time: 240
    max_task_count: [10, 25]
    scheduled_min_task_count:
      - {from: "1:45", to: "4:30", count: 8}
    cooldown_time_for_reach_max: 600
    min_task_count: 0
    # Required capacity per task (default: 1)
    # You should specify "binpack" as task placement strategy if the value is less than 1 and you use an auto scaling group.
    required_capacity: 0.5
    upscale_triggers:
      - alarm_name: "ECS [repro-api-production] CPUUtilization"
        state: ALARM
      - alarm_name: "ELB repro-api-a HTTPCode_Backend_5XX"
        state: ALARM
        step: 2
    downscale_triggers:
      - alarm_name: "ECS [repro-api-production] CPUUtilization (low)"
        state: OK

  - name: repro-worker-production
    cluster: ecs-cluster-for-worker
    region: ap-northeast-1
    spot_fleet_request_id: sfr-354de735-2c17-4565-88c9-10ada5b957e5
    step: 1
    idle_time: 240
    cooldown_time_for_reach_max: 600
    min_task_count: 0
    required_capacity: 2
    upscale_triggers:
      - alarm_name: "ECS [repro-worker-production] CPUUtilization"
        state: ALARM
    downscale_triggers:
      - alarm_name: "ECS [repro-worker-production] CPUUtilization (low)"
        state: OK

```

Then, execute the following command:

```sh
ecs_auto_scaler <config yaml>
```

I recommends deploy `ecs_auto_scaler` on ECS too.

### Signals

 Signal    | Description
-----------|------------------------------------------------------------
 TERM, INT | Shutdown gracefully
 CONT      | Resume auto scaling
 TSTP      | Pause auto scaling (Run only container instance draining)

### IAM policy for autoscaler

The following policy is required for the preceding configuration of "repro-api-production" service:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "cloudwatch:DescribeAlarms",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ecs:DescribeContainerInstances",
        "ecs:DescribeServices",
        "ecs:ListContainerInstances",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DetachInstances",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource": [
        "arn:aws:autoscaling:ap-northeast-1:<account-id>:autoScalingGroup:<group-id>:autoScalingGroupName/ecs-cluster-nodes"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:DeregisterContainerInstance"
      ],
      "Resource": [
        "arn:aws:ecs:ap-northeast-1:<account-id>:cluster/ecs-cluster"
      ]
    }
  ]
}
```

The following policy is required for the preceding configuration of "repro-worker-production" service:

```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecs:UpdateContainerInstancesState",
      "Resource": "*",
      "Condition": {
        "ArnEquals": {
          "ecs:cluster": "arn:aws:ecs:ap-northeast-1:<account-id>:cluster/ecs-cluster-for-worker"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:DeleteMessageBatch",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:ap-northeast-1:<account-id>:spot-instance-intrp-warns"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarms",
        "ec2:ModifySpotFleetRequest",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ecs:ListContainerInstances",
        "ecs:DescribeContainerInstances",
        "ecs:DescribeServices",
        "ec2:DescribeSpotFleetInstances",
        "ec2:DescribeSpotFleetRequests",
        "ecs:UpdateService"
      ],
      "Resource": "*"
    }
  ]
}
```


## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/reproio/ecs_deploy.
